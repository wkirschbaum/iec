defmodule Iec.Parties do
  @moduledoc """
  Party-level results: each party's share and seats per municipality and per ward, read
  from the IEC's per-party files, and how that compares with the previous election.

  Parties on the national results list are polled while counting runs; any other party
  starts being polled when someone opens its page. Each tracked party's previous-election
  file is imported once.
  """

  import Ecto.Query

  require Logger

  alias Iec.{Maps, Repo, Results}
  alias Iec.Results.{Feed, Fetch, Parser, PartyMunicipalityResult, PartyWardResult}
  alias Iec.Results.{FollowedParty, Poller, Snapshot, Ward}

  @topic "parties"

  # Parties beyond the national list change little; their files are checked this often.
  @minor_party_interval :timer.minutes(5)

  # Pause between one-off downloads (municipality and previous-election files).
  @pause 300

  @doc "Subscribes the caller to `{:party_results_changed, party_id}` and `:wards_mapped`."
  def subscribe, do: Phoenix.PubSub.subscribe(Iec.PubSub, @topic)

  defp broadcast(message) do
    Iec.Cache.invalidate()
    Phoenix.PubSub.broadcast(Iec.PubSub, @topic, message)
  end

  ## Ingesting

  @doc """
  Stores a party file: upserts the party's municipality and ward rows and records when
  each ward was first declared for it. Returns the number of rows that changed.
  """
  def ingest(feed, data, body, validators) do
    parsed = Parser.parse_party(data)
    now = DateTime.utc_now()

    Repo.transact(fn ->
      Repo.insert!(%Fetch{
        election: feed.election,
        feed: feed.name,
        url: feed.url,
        etag: validators[:etag],
        last_modified: validators[:last_modified],
        report_date: Parser.report_date(data),
        body_bytes: byte_size(body)
      })

      ward_rows =
        for ward <- parsed.wards do
          Map.merge(ward, %{
            election: feed.election,
            party_id: feed.party_id,
            first_won_at: if(ward.won, do: now),
            inserted_at: now,
            updated_at: now
          })
        end

      ward_count =
        ward_rows
        |> Enum.chunk_every(2000)
        |> Enum.map(fn chunk ->
          {count, _} =
            Repo.insert_all(PartyWardResult, chunk,
              on_conflict: ward_conflict_update(),
              conflict_target: [:election, :party_id, :ward_id]
            )

          count
        end)
        |> Enum.sum()

      municipality_rows =
        for municipality <- parsed.municipalities do
          Map.merge(municipality, %{
            election: feed.election,
            party_id: feed.party_id,
            inserted_at: now,
            updated_at: now
          })
        end

      {municipality_count, _} =
        Repo.insert_all(PartyMunicipalityResult, municipality_rows,
          on_conflict: municipality_conflict_update(),
          conflict_target: [:election, :party_id, :municipality_id]
        )

      {:ok, ward_count + municipality_count}
    end)
  end

  # Only rows whose figures moved are updated (and counted). first_won_at keeps the
  # first time we saw the ward won, and clears if the IEC ever withdraws it.
  defp ward_conflict_update do
    from result in PartyWardResult,
      update: [
        set: [
          vote_percentage: fragment("EXCLUDED.vote_percentage"),
          won: fragment("EXCLUDED.won"),
          first_won_at:
            fragment(
              "CASE WHEN EXCLUDED.won THEN COALESCE(?, EXCLUDED.first_won_at) END",
              result.first_won_at
            ),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where:
        fragment(
          "(?, ?) IS DISTINCT FROM (EXCLUDED.vote_percentage, EXCLUDED.won)",
          result.vote_percentage,
          result.won
        )
  end

  defp municipality_conflict_update do
    from result in PartyMunicipalityResult,
      update: [
        set: [
          vote_percentage: fragment("EXCLUDED.vote_percentage"),
          seats_won: fragment("EXCLUDED.seats_won"),
          majority: fragment("EXCLUDED.majority"),
          council_winner: fragment("EXCLUDED.council_winner"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ],
      where:
        fragment(
          "(?, ?, ?, ?) IS DISTINCT FROM (EXCLUDED.vote_percentage, EXCLUDED.seats_won, EXCLUDED.majority, EXCLUDED.council_winner)",
          result.vote_percentage,
          result.seats_won,
          result.majority,
          result.council_winner
        )
  end

  @doc "Announces that a party's rows changed."
  def broadcast_changed(party_id), do: broadcast({:party_results_changed, party_id})

  ## Following parties

  @doc """
  Adds parties to the followed set (every party standing anywhere ends up here, see
  `import_municipality_files/0`) and starts following the new ones.
  """
  def follow_parties(party_ids) do
    now = DateTime.utc_now()
    rows = for id <- Enum.uniq(party_ids), id >= 0, do: %{party_id: id, inserted_at: now}
    Repo.insert_all(FollowedParty, rows, on_conflict: :nothing)
    track_followed_parties()
  end

  @doc "Every followed party's id."
  def list_followed_party_ids, do: Repo.all(from party in FollowedParty, select: party.party_id)

  @doc """
  Starts a poller for each followed party (and each party on the national list) that has
  none yet, and imports their previous-election files that are not stored. Parties on the
  national list are polled as their files change; the rest every few minutes. Does
  nothing when polling is off (tests, `mix iec.seed`).
  """
  def track_followed_parties do
    if polling?() do
      national = national_party_ids()

      (national ++ list_followed_party_ids())
      |> Enum.uniq()
      |> Enum.reject(&Poller.running?(Feed.party_feed(Feed.live_election(), &1).name))
      |> Enum.with_index()
      |> Enum.each(fn {party_id, index} ->
        DynamicSupervisor.start_child(
          Iec.Parties.Pollers,
          {Poller,
           feed: Feed.party_feed(Feed.live_election(), party_id),
           initial_delay: :timer.seconds(1) * index,
           minimum_interval: if(party_id in national, do: 0, else: @minor_party_interval)}
        )
      end)

      Task.Supervisor.start_child(Iec.TaskSupervisor, &import_previous_party_files/0)
    end

    :ok
  end

  @doc "Adds every party on the latest national results list to the followed set."
  def follow_national_parties, do: follow_parties(national_party_ids())

  defp national_party_ids do
    case Results.get_latest_snapshot(:national, 0) do
      nil -> []
      national -> for party <- national.party_results, party.party_id >= 0, do: party.party_id
    end
  end

  defp polling?, do: Application.fetch_env!(:iec, Iec.Results)[:poll]

  @doc """
  Imports the previous-election file of every followed party not stored yet, one at a
  time. Only one import runs at once.
  """
  def import_previous_party_files do
    with {:ok, _owner} <- Registry.register(Iec.Results.Registry, :previous_party_files, nil) do
      previous = Feed.previous_election()

      for party_id <- Enum.uniq(national_party_ids() ++ list_followed_party_ids()),
          not party_file_imported?(previous, party_id) do
        import_party_file(previous, party_id)
        Process.sleep(@pause)
      end

      :ok
    end
  end

  @doc """
  Fetches and stores one party file of an election once. A party that did not stand in
  the previous election has no file (the IEC answers 4xx); a fetch row without a body
  records that, so it is not asked for again.
  """
  def import_party_file(election, party_id) do
    feed = Feed.party_feed(election, party_id)

    case Feed.get(feed.url) do
      {:ok, data, body, cache} ->
        {:ok, _count} = ingest(feed, data, body, cache.validators)
        broadcast_changed(party_id)

      {:error, {:http_status, status}} when status in 400..499 ->
        if election.year != Results.live_year(), do: record_fetch(election, feed.name, feed.url)
        :no_file

      other ->
        Logger.warning("#{feed.election} #{feed.name}: import failed (#{inspect(other)})")
        {:error, other}
    end
  end

  @doc "True when an election's file for this party has been stored (or found missing)."
  def party_file_imported?(election, party_id), do: fetched?(election.year, "party-#{party_id}")

  ## Municipality files

  @doc """
  Reads each live-election municipality file once: maps its wards to the municipality and
  follows every party standing in it. Files the IEC has not published yet (it answers
  406) are retried on the next pass; `complete_municipality_files/0` keeps passing until
  all are read. Waits for the province pollers on a fresh database.
  """
  def import_municipality_files(attempts_left \\ 20) do
    live = Feed.live_election()
    municipality_ids = Map.keys(Results.list_area_names(:municipality))

    if municipality_ids == [] and attempts_left > 0 do
      Process.sleep(:timer.seconds(15))
      import_municipality_files(attempts_left - 1)
    else
      party_ids =
        for municipality_id <- municipality_ids,
            not fetched?(live.year, "munic-#{municipality_id}"),
            data = fetch_municipality_file(live, municipality_id),
            data != nil,
            reduce: [] do
          party_ids ->
            insert_wards(municipality_id, data)
            party_ids ++ standing_party_ids(data)
        end

      if party_ids != [] do
        follow_parties(party_ids)
        broadcast(:wards_mapped)
      end

      :ok
    end
  end

  @doc "Repeats `import_municipality_files/0` every 10 minutes until every file is read."
  def complete_municipality_files(passes_left \\ 24) do
    import_municipality_files()

    if passes_left > 1 and unread_municipality_files() > 0 do
      Process.sleep(:timer.minutes(10))
      complete_municipality_files(passes_left - 1)
    else
      :ok
    end
  end

  defp unread_municipality_files do
    year = Results.live_year()

    Results.list_area_names(:municipality)
    |> Map.keys()
    |> Enum.count(&(not fetched?(year, "munic-#{&1}")))
  end

  @doc """
  Reads each previous-election municipality file once and stores every party's share of
  every ward, marking the ward's winner (most votes; these files carry no seat flag). This
  gives the previous holder of every ward, whichever party it was.
  """
  def import_previous_ward_results do
    previous = Feed.previous_election()

    municipality_ids =
      Enum.uniq(Map.keys(Results.list_area_names(:municipality)) ++ previous_municipality_ids())

    for municipality_id <- municipality_ids,
        not fetched?(previous.year, "munic-#{municipality_id}"),
        data = fetch_municipality_file(previous, municipality_id),
        data != nil do
      insert_previous_ward_results(previous.year, data)
    end

    broadcast(:wards_mapped)
    :ok
  end

  defp previous_municipality_ids do
    Repo.all(
      from snapshot in Snapshot,
        where: snapshot.election == ^Results.previous_year() and snapshot.level == :municipality,
        distinct: true,
        select: snapshot.area_id
    )
  end

  # One municipality file (up to ~3 MB), fetched politely; recorded as read on success.
  defp fetch_municipality_file(election, municipality_id) do
    url = Feed.municipality_url(election, municipality_id)
    Process.sleep(@pause)

    case Feed.get(url) do
      {:ok, data, _body, _cache} ->
        record_fetch(election, "munic-#{municipality_id}", url)
        data

      other ->
        Logger.warning("Municipality file #{url} failed (#{inspect(other)})")
        nil
    end
  end

  defp insert_wards(municipality_id, data) do
    now = DateTime.utc_now()

    rows =
      for ward <- data["WardResults"] || [] do
        %{
          id: ward["WardID"],
          municipality_id: municipality_id,
          ward_number: Ward.ward_number(ward["WardID"]),
          inserted_at: now
        }
      end

    Repo.insert_all(Ward, rows, on_conflict: :nothing)
  end

  defp standing_party_ids(data) do
    for ward <- data["WardResults"] || [],
        party <- ward["PartyBallotResults"] || [],
        is_integer(party["ID"]),
        uniq: true,
        do: party["ID"]
  end

  defp insert_previous_ward_results(year, data) do
    now = DateTime.utc_now()

    rows =
      for ward <- data["WardResults"] || [],
          parties = Enum.filter(ward["PartyBallotResults"] || [], &is_integer(&1["ID"])),
          winner = Enum.max_by(parties, &(&1["TotalValidVotes"] || 0), fn -> nil end),
          party <- parties do
        won = party == winner and (party["TotalValidVotes"] || 0) > 0

        %{
          election: year,
          party_id: party["ID"],
          ward_id: ward["WardID"],
          vote_percentage: party["PercOfVotes"] && party["PercOfVotes"] / 1,
          won: won,
          first_won_at: if(won, do: now),
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.uniq_by(&{&1.party_id, &1.ward_id})
    |> Enum.chunk_every(2_000)
    |> Enum.each(
      &Repo.insert_all(PartyWardResult, &1,
        on_conflict: ward_conflict_update(),
        conflict_target: [:election, :party_id, :ward_id]
      )
    )
  end

  defp fetched?(year, feed_name) do
    Repo.exists?(from fetch in Fetch, where: fetch.election == ^year and fetch.feed == ^feed_name)
  end

  defp record_fetch(election, feed_name, url) do
    Repo.insert!(%Fetch{election: election.year, feed: feed_name, url: url, body_bytes: 0})
  end

  ## Reading

  @doc """
  Everything the party page shows: national figures now and in the previous election,
  and each municipality and ward the party contested in either, classified as gained,
  lost, kept/held or still pending.
  """
  def get_party_overview(party_id) do
    live_year = Results.live_year()
    previous_year = Results.previous_year()

    national_row = fn year ->
      case Results.get_latest_snapshot(:national, 0, election: year) do
        nil -> nil
        snapshot -> Enum.find(snapshot.party_results, &(&1.party_id == party_id))
      end
    end

    municipality_rows = party_rows(PartyMunicipalityResult, party_id, :municipality_id)
    ward_rows = party_rows(PartyWardResult, party_id, :ward_id)
    areas = municipality_areas()

    %{
      party_id: party_id,
      national: national_row.(live_year),
      previous_national: national_row.(previous_year),
      municipalities:
        compare_municipalities(
          municipality_rows[live_year] || %{},
          municipality_rows[previous_year] || %{},
          areas,
          live_year,
          previous_year
        ),
      wards:
        compare_wards(
          ward_rows[live_year] || %{},
          ward_rows[previous_year] || %{},
          areas,
          live_year,
          previous_year
        )
    }
  end

  @doc """
  One council from the party files: every tracked party's share, seats and majority now
  and in the previous election (best first), and each ward's winner now and then.
  """
  def get_municipality_overview(municipality_id) do
    live_year = Results.live_year()
    previous_year = Results.previous_year()

    rows =
      PartyMunicipalityResult
      |> where([result], result.municipality_id == ^municipality_id)
      |> Repo.all()
      |> Enum.group_by(& &1.election)

    before_by_party = Map.new(rows[previous_year] || [], &{&1.party_id, &1})

    parties =
      for now <- rows[live_year] || [] do
        before = before_by_party[now.party_id]

        %{
          party_id: now.party_id,
          share: now.vote_percentage,
          previous_share: before && before.vote_percentage,
          swing: swing(now, before),
          seats: now.seats_won,
          previous_seats: before && before.seats_won,
          majority: now.majority,
          previous_majority: before != nil and before.majority
        }
      end
      |> Enum.sort_by(&(-(&1.share || 0)))

    %{parties: parties, wards: municipality_wards(municipality_id, live_year, previous_year)}
  end

  defp municipality_wards(municipality_id, live_year, previous_year) do
    ward_ids =
      Repo.all(
        from ward in Ward,
          where: ward.municipality_id == ^municipality_id,
          order_by: ward.id,
          select: ward.id
      )

    holders = ward_holders(ward_ids)
    first_fetched_at = first_party_fetches(live_year)
    redrawn = Maps.list_redrawn_ward_ids()

    existed =
      Repo.all(
        from result in PartyWardResult,
          where: result.election == ^previous_year and result.ward_id in ^ward_ids,
          distinct: true,
          select: result.ward_id
      )
      |> MapSet.new()

    for ward_id <- ward_ids do
      holder = holders[{live_year, ward_id}]
      previous_holder = holders[{previous_year, ward_id}]

      %{
        ward_id: ward_id,
        ward_number: Ward.ward_number(ward_id),
        holder: holder && holder.party_id,
        share: holder && holder.vote_percentage,
        declared_at: holder && holder.first_won_at,
        declared_before_tracking: declared_before_tracking?(holder, first_fetched_at),
        previous_holder: previous_holder && previous_holder.party_id,
        previous_share: previous_holder && previous_holder.vote_percentage,
        # A redrawn ward shows who held its old shape, but did not change hands as such.
        changed_hands:
          holder != nil and previous_holder != nil and ward_id not in redrawn and
            holder.party_id != previous_holder.party_id,
        new_ward: not MapSet.member?(existed, ward_id),
        redrawn: ward_id in redrawn
      }
    end
  end

  defp party_rows(schema, party_id, key) do
    schema
    |> where([row], row.party_id == ^party_id)
    |> Repo.all()
    |> Enum.group_by(& &1.election)
    |> Map.new(fn {election, rows} -> {election, Map.new(rows, &{Map.fetch!(&1, key), &1})} end)
  end

  # Latest live snapshot of every municipality (name, province, whether counting is
  # complete), keyed by id.
  @doc """
  Who is up and who is down since the previous election:

    * `parties` – every party on the national list with its share now and before, its
      swing (a new party swings from zero), and the wards and council majorities it
      gained and lost
    * `local_swings` – the largest rises and falls of a party within one council
      (`%{rises: [...], falls: [...]}`, ten each)

  Wards count once declared; councils once their count is complete. Holders are known for
  parties whose files are stored.
  """
  def get_movers do
    live_year = Results.live_year()
    previous_year = Results.previous_year()
    areas = municipality_areas()

    national = Results.get_latest_snapshot(:national, 0)
    previous = Results.get_latest_snapshot(:national, 0, election: previous_year)
    previous_by_party = Map.new((previous && previous.party_results) || [], &{&1.party_id, &1})
    wards = ward_turnover(live_year, previous_year)
    councils = council_turnover(Map.keys(areas), areas, live_year, previous_year)

    parties =
      for party <- (national && national.party_results) || [], party.party_id >= 0 do
        before = previous_by_party[party.party_id]
        tally = fn turnover, key -> get_in(turnover, [party.party_id, key]) || 0 end

        %{
          party_id: party.party_id,
          share: party.vote_percentage,
          previous_share: before && before.vote_percentage,
          swing: Results.swing(party.vote_percentage, (before && before.vote_percentage) || 0.0),
          new_party: is_nil(before),
          wards_gained: tally.(wards, :gained),
          wards_lost: tally.(wards, :lost),
          councils_gained: tally.(councils, :gained),
          councils_lost: tally.(councils, :lost)
        }
      end

    %{parties: parties, local_swings: local_swings(areas, live_year, previous_year)}
  end

  # Per party: wards it took from another party, and wards another party took from it.
  defp ward_turnover(live_year, previous_year) do
    holders =
      Repo.all(
        from result in PartyWardResult,
          where: result.won,
          select: {result.election, result.ward_id, result.party_id}
      )
      |> Map.new(fn {election, ward_id, party_id} -> {{election, ward_id}, party_id} end)

    redrawn = Maps.list_redrawn_ward_ids()

    # Like the party page: only wards that existed before with the same shape count; a new
    # or redrawn ward is neither gained nor lost.
    Enum.reduce(holders, %{}, fn
      {{^live_year, ward_id}, holder}, turnover ->
        previous_holder =
          if ward_id in redrawn, do: nil, else: holders[{previous_year, ward_id}]

        if previous_holder in [nil, holder],
          do: turnover,
          else:
            turnover |> count_turnover(holder, :gained) |> count_turnover(previous_holder, :lost)

      _previous_election, turnover ->
        turnover
    end)
  end

  # Per party: council majorities won and lost, counting complete councils only. A
  # majority lost to a hung council counts as lost with no one gaining it.
  defp council_turnover(municipality_ids, areas, live_year, previous_year) do
    control = get_council_control(municipality_ids)

    municipality_ids
    |> Enum.filter(&areas[&1].complete)
    |> Enum.reduce(%{}, fn municipality_id, turnover ->
      now = get_in(control, [{live_year, municipality_id}, :majority])
      before = get_in(control, [{previous_year, municipality_id}, :majority])

      if now == before,
        do: turnover,
        else: turnover |> count_turnover(now, :gained) |> count_turnover(before, :lost)
    end)
  end

  defp count_turnover(turnover, nil, _key), do: turnover

  defp count_turnover(turnover, party_id, key),
    do: update_in(turnover, [Access.key(party_id, %{}), Access.key(key, 0)], &(&1 + 1))

  defp local_swings(areas, live_year, previous_year) do
    swings =
      Repo.all(
        from now in PartyMunicipalityResult,
          join: before in PartyMunicipalityResult,
          on:
            before.party_id == now.party_id and before.municipality_id == now.municipality_id and
              before.election == ^previous_year,
          where: now.election == ^live_year and not is_nil(now.vote_percentage),
          select: %{
            party_id: now.party_id,
            municipality_id: now.municipality_id,
            share: now.vote_percentage,
            previous_share: before.vote_percentage,
            swing: now.vote_percentage - before.vote_percentage
          }
      )
      |> Enum.map(fn swing ->
        area = areas[swing.municipality_id] || %{name: "–", complete: false}

        %{swing | swing: Float.round(swing.swing, 2)}
        |> Map.merge(%{municipality_name: area.name, complete: area.complete})
      end)

    %{
      rises: swings |> Enum.sort_by(& &1.swing, :desc) |> Enum.take(10),
      falls: swings |> Enum.sort_by(& &1.swing) |> Enum.take(10)
    }
  end

  defp municipality_areas do
    Repo.all(
      from snapshot in Snapshot,
        where: snapshot.election == ^Results.live_year() and snapshot.level == :municipality,
        distinct: snapshot.area_id,
        order_by: [asc: snapshot.area_id, desc: snapshot.id],
        select: %{
          id: snapshot.area_id,
          name: snapshot.area_name,
          province_id: snapshot.province_id,
          complete: snapshot.municipalities_complete == 1
        }
    )
    |> Map.new(&{&1.id, &1})
  end

  defp compare_municipalities(now_by_id, before_by_id, areas, live_year, previous_year) do
    municipality_ids = Enum.uniq(Map.keys(now_by_id) ++ Map.keys(before_by_id))
    control = get_council_control(municipality_ids)

    municipality_ids
    |> Enum.map(fn municipality_id ->
      now = now_by_id[municipality_id]
      before = before_by_id[municipality_id]

      area =
        areas[municipality_id] ||
          %{name: "Municipality #{municipality_id}", province_id: nil, complete: false}

      majority_now = now != nil and now.majority
      majority_before = before != nil and before.majority
      control_now = control[{live_year, municipality_id}]

      status =
        cond do
          majority_now and majority_before -> :kept
          majority_now -> :gained
          majority_before and not area.complete -> :pending
          majority_before and control_now != nil and control_now.majority != nil -> :lost_to_party
          majority_before -> :lost_hung
          true -> :none
        end

      %{
        municipality_id: municipality_id,
        name: area.name,
        province_id: area.province_id,
        complete: area.complete,
        status: status,
        share: now && now.vote_percentage,
        previous_share: before && before.vote_percentage,
        swing: swing(now, before),
        seats: now && now.seats_won,
        previous_seats: before && before.seats_won,
        control: control[{live_year, municipality_id}],
        previous_control: control[{previous_year, municipality_id}]
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Who controls each council, per election, among the parties we have files for:
  `%{{election, municipality_id} => %{majority: party_id | nil, largest: party_id | nil}}`.
  With no majority the council is hung (or still counting) and `largest` has the most seats.

  `get_council_control/2` returns one election's, keyed by municipality id.
  """
  def get_council_control(municipality_ids, year) do
    for {{^year, municipality_id}, control} <- get_council_control(municipality_ids),
        into: %{},
        do: {municipality_id, control}
  end

  def get_council_control(municipality_ids) do
    Repo.all(
      from result in PartyMunicipalityResult,
        where: result.municipality_id in ^municipality_ids,
        select: %{
          election: result.election,
          municipality_id: result.municipality_id,
          party_id: result.party_id,
          majority: result.majority,
          seats_won: result.seats_won
        }
    )
    |> Enum.group_by(&{&1.election, &1.municipality_id})
    |> Map.new(fn {key, results} ->
      majority = Enum.find(results, & &1.majority)
      largest = Enum.max_by(results, &(&1.seats_won || 0))

      {key,
       %{
         majority: majority && majority.party_id,
         largest: if((largest.seats_won || 0) > 0, do: largest.party_id)
       }}
    end)
  end

  defp compare_wards(now_by_id, before_by_id, areas, live_year, previous_year) do
    ward_ids = Enum.uniq(Map.keys(now_by_id) ++ Map.keys(before_by_id))
    holders = ward_holders(ward_ids)
    first_fetched_at = first_party_fetches(live_year)
    municipality_for = ward_municipalities()
    redrawn = Maps.list_redrawn_ward_ids()

    ward_ids
    |> Enum.map(fn ward_id ->
      now = now_by_id[ward_id]
      holder_now = holders[{live_year, ward_id}]
      # A ward compares with the previous election only if it existed then and kept its
      # shape; a new or redrawn ward can be gained, but not lost.
      comparable = holders[{previous_year, ward_id}] != nil and ward_id not in redrawn
      before = if comparable, do: before_by_id[ward_id]
      holder_before = if comparable, do: holders[{previous_year, ward_id}]
      won_now = now != nil and now.won
      held_before = before != nil and before.won

      status =
        cond do
          won_now and held_before -> :held
          won_now and not comparable -> :won_new
          won_now -> :gained
          held_before and holder_now != nil -> :lost
          held_before -> :pending
          true -> :none
        end

      municipality = areas[municipality_for.(ward_id)]

      %{
        ward_id: ward_id,
        ward_number: Ward.ward_number(ward_id),
        municipality_name: (municipality && municipality.name) || "–",
        municipality_id: municipality && municipality.id,
        province_id: municipality && municipality.province_id,
        status: status,
        share: now && now.vote_percentage,
        previous_share: before && before.vote_percentage,
        swing: swing(now, before),
        previous_holder: holder_before && holder_before.party_id,
        holder: holder_now && holder_now.party_id,
        declared_at: holder_now && holder_now.first_won_at,
        declared_before_tracking: declared_before_tracking?(holder_now, first_fetched_at),
        new_ward: not comparable,
        redrawn: ward_id in redrawn
      }
    end)
    |> Enum.sort_by(&{&1.municipality_name, &1.ward_number})
  end

  # Which party won each ward, per election, among the parties we have files for.
  # A ward already declared when we first fetched the winner's file has no real
  # declaration time, only "before then".
  defp declared_before_tracking?(nil, _first_fetched_at), do: false

  defp declared_before_tracking?(holder, first_fetched_at) do
    case first_fetched_at[holder.party_id] do
      nil -> false
      fetched_at -> DateTime.diff(holder.first_won_at, fetched_at, :second) <= 5
    end
  end

  # When each party's live file was first stored, keyed by party id.
  defp first_party_fetches(year) do
    Repo.all(
      from fetch in Fetch,
        where: fetch.election == ^year and like(fetch.feed, "party-%"),
        group_by: fetch.feed,
        select: {fetch.feed, min(fetch.inserted_at)}
    )
    |> Map.new(fn {"party-" <> party_id, fetched_at} ->
      {String.to_integer(party_id), fetched_at}
    end)
  end

  defp ward_holders(ward_ids) do
    Repo.all(
      from result in PartyWardResult,
        where: result.won and result.ward_id in ^ward_ids,
        select: %{
          election: result.election,
          ward_id: result.ward_id,
          party_id: result.party_id,
          first_won_at: result.first_won_at,
          vote_percentage: result.vote_percentage
        }
    )
    |> Map.new(&{{&1.election, &1.ward_id}, &1})
  end

  # Ward id → municipality id, from the directory, falling back to the ward's
  # municipality code for wards that only existed in the previous election.
  defp ward_municipalities do
    wards = Repo.all(from ward in Ward, select: {ward.id, ward.municipality_id}) |> Map.new()

    by_code =
      Map.new(wards, fn {ward_id, municipality_id} ->
        {Ward.municipality_code(ward_id), municipality_id}
      end)

    fn ward_id -> wards[ward_id] || by_code[Ward.municipality_code(ward_id)] end
  end

  defp swing(now, before),
    do: Results.swing(now && now.vote_percentage, before && before.vote_percentage)
end
