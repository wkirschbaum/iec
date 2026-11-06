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

  alias Iec.Repo
  alias Iec.Results
  alias Iec.Results.{Feed, Fetch, Parser, PartyMunicipalityResult, PartyWardResult}
  alias Iec.Results.{Poller, Snapshot, Ward}

  @topic "parties"

  @doc "Subscribes the caller to `{:party_results_changed, party_id}` and `:wards_mapped`."
  def subscribe, do: Phoenix.PubSub.subscribe(Iec.PubSub, @topic)

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Iec.PubSub, @topic, message)

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

  ## Tracking

  @doc """
  Starts polling a party's live file, and imports its previous-election file if that
  is not stored yet. Does nothing when polling is off (tests).
  """
  def track_party(party_id) when is_integer(party_id) and party_id >= 0 do
    if polling?() do
      feed = Feed.party_feed(Feed.live_election(), party_id)

      unless Poller.running?(feed.name) do
        DynamicSupervisor.start_child(
          Iec.Parties.Pollers,
          {Poller, feed: feed, initial_delay: :rand.uniform(:timer.seconds(3))}
        )
      end

      unless party_file_imported?(Feed.previous_election(), party_id) do
        Task.Supervisor.start_child(Iec.TaskSupervisor, fn ->
          import_previous_election(party_id)
        end)
      end
    end

    :ok
  end

  def track_party(_party_id), do: :ok

  @doc "Tracks every party on the latest national results list."
  def track_national_parties do
    case Results.get_latest_snapshot(:national, 0) do
      nil -> :ok
      national -> Enum.each(national.party_results, &track_party(&1.party_id))
    end
  end

  defp polling?, do: Application.fetch_env!(:iec, Iec.Results)[:poll]

  # Runs at most once at a time per party.
  defp import_previous_election(party_id) do
    feed = Feed.party_feed(Feed.previous_election(), party_id)

    with {:ok, _owner} <- Registry.register(Iec.Results.Registry, {:import, feed.name}, nil) do
      import_party_file(Feed.previous_election(), party_id)
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
        if election.year != Results.live_year() do
          Repo.insert!(%Fetch{
            election: feed.election,
            feed: feed.name,
            url: feed.url,
            body_bytes: 0
          })
        end

        :no_file

      other ->
        Logger.warning("#{feed.election} #{feed.name}: import failed (#{inspect(other)})")
        {:error, other}
    end
  end

  @doc "True when an election's file for this party has been stored (or found missing)."
  def party_file_imported?(election, party_id) do
    name = "party-#{party_id}"

    Repo.exists?(
      from fetch in Fetch, where: fetch.election == ^election.year and fetch.feed == ^name
    )
  end

  @doc """
  Fills the ward directory from the live election's municipality files, skipping
  municipalities already mapped. Each file is up to ~3 MB, so they are fetched one at a
  time with a pause between them.
  """
  def import_ward_directory(attempts_left \\ 20) do
    if attempts_left > 0 and not Repo.exists?(municipality_snapshots()) do
      # Fresh database: wait for the province pollers to store the municipalities.
      Process.sleep(:timer.seconds(15))
      import_ward_directory(attempts_left - 1)
    else
      map_unmapped_municipalities()
    end
  end

  @doc """
  Keeps filling the ward directory until every municipality is mapped: the IEC answers
  406 for municipality files it has not published yet. Gives up after a few hours.
  """
  def complete_ward_directory(passes_left \\ 24) do
    import_ward_directory()

    if passes_left > 1 and unmapped_municipality_count() > 0 do
      Process.sleep(:timer.minutes(10))
      complete_ward_directory(passes_left - 1)
    else
      :ok
    end
  end

  defp unmapped_municipality_count do
    mapped = from ward in Ward, distinct: true, select: ward.municipality_id

    municipality_snapshots()
    |> where([snapshot], snapshot.area_id not in subquery(mapped))
    |> select([snapshot], count(snapshot.area_id, :distinct))
    |> Repo.one()
  end

  defp municipality_snapshots do
    from snapshot in Snapshot,
      where: snapshot.election == ^Results.live_year() and snapshot.level == :municipality
  end

  defp map_unmapped_municipalities do
    mapped = Repo.all(from ward in Ward, distinct: true, select: ward.municipality_id)

    municipality_ids =
      Repo.all(
        from snapshot in Snapshot,
          where:
            snapshot.election == ^Results.live_year() and snapshot.level == :municipality and
              snapshot.area_id not in ^mapped,
          distinct: true,
          select: snapshot.area_id
      )

    for municipality_id <- municipality_ids do
      url = Feed.municipality_url(Feed.live_election(), municipality_id)

      case Feed.get(url) do
        {:ok, data, _body, _cache} ->
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

        other ->
          Logger.warning("Ward directory: #{url} failed (#{inspect(other)})")
      end

      Process.sleep(500)
    end

    if municipality_ids != [], do: broadcast(:wards_mapped)
    :ok
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
        ),
      updated_at: last_updated_at(party_id)
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
        changed_hands:
          holder != nil and previous_holder != nil and holder.party_id != previous_holder.party_id,
        new_ward: not MapSet.member?(existed, ward_id)
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

  defp last_updated_at(party_id) do
    name = "party-#{party_id}"
    year = Results.live_year()

    Repo.one(
      from fetch in Fetch,
        where: fetch.election == ^year and fetch.feed == ^name,
        select: max(fetch.inserted_at)
    )
  end

  # Latest live snapshot of every municipality (name, province, whether counting is
  # complete), keyed by id.
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
  """
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

    ward_ids
    |> Enum.map(fn ward_id ->
      now = now_by_id[ward_id]
      before = before_by_id[ward_id]
      holder_now = holders[{live_year, ward_id}]
      holder_before = holders[{previous_year, ward_id}]
      won_now = now != nil and now.won
      held_before = before != nil and before.won

      status =
        cond do
          won_now and held_before -> :held
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
        new_ward: before == nil and holder_before == nil
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

  defp swing(nil, _before), do: nil
  defp swing(_now, nil), do: nil

  defp swing(%{vote_percentage: now}, %{vote_percentage: before}),
    do: Float.round(now - before, 2)
end
