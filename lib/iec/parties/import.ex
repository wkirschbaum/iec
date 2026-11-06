defmodule Iec.Parties.Import do
  @moduledoc """
  Reads the IEC's party and municipality files into the party tables (`Iec.Parties`
  reads them back).

    * party files: each party's share, seats and majority per municipality, and its share
      and win per ward (`ingest/4`)
    * live municipality files: which municipality each ward is in, and every party
      standing, which is then followed
    * previous-election municipality files: every party's share of every ward, and its
      winner

  Every party standing anywhere is followed: those on the national results list are
  polled as their files change, the rest every few minutes. Each followed party's
  previous-election file is imported once.
  """

  import Ecto.Query

  require Logger

  alias Iec.{Parties, Repo, Results}
  alias Iec.Results.{Feed, Parser, PartyMunicipalityResult, PartyWardResult}
  alias Iec.Results.{FollowedParty, Poller, Snapshot, Ward}

  # Parties beyond the national list change little; their files are checked this often.
  @minor_party_interval :timer.minutes(5)

  # Pause between one-off downloads (municipality and previous-election files).
  @pause 300

  # Rows per insert, well below Postgres' limit on query parameters.
  @chunk_size 2_000

  ## Party files

  @doc """
  Stores a party file: upserts the party's municipality and ward rows and records when
  each ward was first declared for it. Returns the number of rows that changed.
  """
  def ingest(feed, data, body, validators) do
    parsed = Parser.parse_party(data)
    now = DateTime.utc_now()

    # What every row of this file shares.
    common = %{
      election: feed.election,
      party_id: feed.party_id,
      inserted_at: now,
      updated_at: now
    }

    Repo.transact(fn ->
      Results.record_fetch!(feed, data, body, validators)

      ward_count =
        parsed.wards
        |> Enum.map(&Map.merge(&1, Map.put(common, :first_won_at, if(&1.won, do: now))))
        |> upsert_ward_results()

      {municipality_count, _rows} =
        Repo.insert_all(
          PartyMunicipalityResult,
          Enum.map(parsed.municipalities, &Map.merge(&1, common)),
          on_conflict: municipality_conflict_update(),
          conflict_target: [:election, :party_id, :municipality_id]
        )

      {:ok, ward_count + municipality_count}
    end)
  end

  # Inserts or updates ward rows in chunks; returns how many changed.
  defp upsert_ward_results(rows) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.map(fn chunk ->
      {count, _rows} =
        Repo.insert_all(PartyWardResult, chunk,
          on_conflict: ward_conflict_update(),
          conflict_target: [:election, :party_id, :ward_id]
        )

      count
    end)
    |> Enum.sum()
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

  @doc """
  Fetches and stores one party file of an election once. A party that did not stand in
  the previous election has no file (the IEC answers 4xx); a fetch row without a body
  records that, so it is not asked for again.
  """
  def import_party_file(election, party_id) do
    feed = Feed.party_feed(election, party_id)

    case Feed.get(feed.url) do
      {:ok, data, body, cache} ->
        {:ok, count} = ingest(feed, data, body, cache.validators)
        if count > 0, do: Parties.broadcast_changed(party_id)
        :ok

      {:error, {:http_status, status}} when status in 400..499 ->
        if election.year != Results.live_year(),
          do: Results.record_read!(election.year, feed.name, feed.url)

        :no_file

      other ->
        Logger.warning("#{feed.election} #{feed.name}: import failed (#{inspect(other)})")
        {:error, other}
    end
  end

  @doc """
  Imports the previous-election file of every followed party not stored yet, one at a
  time. Only one import runs at once.
  """
  def import_previous_party_files do
    with {:ok, _owner} <- Registry.register(Iec.Results.Registry, :previous_party_files, nil) do
      previous = Feed.previous_election()
      imported = Results.list_stored_feeds(previous.year, "party-")

      for party_id <- Enum.uniq(national_party_ids() ++ list_followed_party_ids()),
          Feed.party_feed(previous, party_id).name not in imported do
        import_party_file(previous, party_id)
        Process.sleep(@pause)
      end

      :ok
    end
  end

  ## Following parties

  @doc "Every followed party's id."
  def list_followed_party_ids, do: Repo.all(from party in FollowedParty, select: party.party_id)

  @doc "Adds every party on the latest national results list to the followed set."
  def follow_national_parties do
    national_ids = national_party_ids()
    follow_parties(national_ids, national_ids)
  end

  # Adds parties to the followed set (every party standing anywhere ends up here, see
  # `import_municipality_files/0`) and starts following the new ones.
  defp follow_parties(party_ids, national_ids) do
    now = DateTime.utc_now()
    rows = for id <- Enum.uniq(party_ids), id >= 0, do: %{party_id: id, inserted_at: now}
    {inserted, _rows} = Repo.insert_all(FollowedParty, rows, on_conflict: :nothing)
    track_followed_parties(national_ids, inserted > 0)
  end

  # Starts a poller for each followed party (and each party on the national list) that has
  # none yet. Parties on the national list are polled as their files change; the rest
  # every few minutes. When parties were newly followed, or pollers started (the first
  # call after a start, which also retries earlier failures), their previous-election
  # files not stored yet are imported. Does nothing when polling is off (tests,
  # `mix iec.seed`).
  defp track_followed_parties(national_ids, newly_followed) do
    if polling?() do
      live = Feed.live_election()
      national = MapSet.new(national_ids)

      started =
        (national_ids ++ list_followed_party_ids())
        |> Enum.uniq()
        |> Enum.map(&Feed.party_feed(live, &1))
        |> Enum.reject(&Poller.running?(&1.name))
        |> Enum.with_index()
        |> Enum.map(fn {feed, index} ->
          DynamicSupervisor.start_child(
            Iec.Parties.Pollers,
            {Poller,
             feed: feed,
             initial_delay: :timer.seconds(1) * index,
             minimum_interval: if(feed.party_id in national, do: 0, else: @minor_party_interval)}
          )
        end)

      if newly_followed or started != [] do
        Task.Supervisor.start_child(Iec.TaskSupervisor, &import_previous_party_files/0)
      end
    end

    :ok
  end

  defp national_party_ids do
    case Results.get_latest_snapshot(:national, 0) do
      nil -> []
      national -> for party <- national.party_results, party.party_id >= 0, do: party.party_id
    end
  end

  defp polling?, do: Application.fetch_env!(:iec, Iec.Results)[:poll]

  ## Municipality files

  @doc """
  Reads each live-election municipality file once: maps its wards to the municipality and
  follows every party standing in it. Files the IEC has not published yet (it answers
  406) are retried on the next pass; `complete_municipality_files/0` keeps passing until
  all are read. Waits for the province pollers on a fresh database.
  """
  def import_municipality_files(attempts_left \\ 20) do
    live = Feed.live_election()
    municipality_ids = live_municipality_ids()

    if municipality_ids == [] and attempts_left > 0 do
      Process.sleep(:timer.seconds(15))
      import_municipality_files(attempts_left - 1)
    else
      party_ids =
        for {municipality_id, data} <- read_municipality_files(live, municipality_ids),
            reduce: [] do
          party_ids ->
            store_municipality_file(live, municipality_id, fn ->
              insert_wards(municipality_id, data)
            end)

            party_ids ++ standing_party_ids(data)
        end

      if party_ids != [] do
        follow_parties(party_ids, national_party_ids())
        Parties.broadcast_wards_mapped()
      end

      :ok
    end
  end

  @doc "Repeats `import_municipality_files/0` every 10 minutes until every file is read."
  def complete_municipality_files(passes_left \\ 24) do
    import_municipality_files()

    if passes_left > 1 and
         unread_municipality_ids(Feed.live_election(), live_municipality_ids()) != [] do
      Process.sleep(:timer.minutes(10))
      complete_municipality_files(passes_left - 1)
    else
      :ok
    end
  end

  @doc """
  Reads each previous-election municipality file once and stores every party's share of
  every ward, marking the ward's winner (most votes; these files carry no seat flag). This
  gives the previous holder of every ward, whichever party it was.
  """
  def import_previous_ward_results do
    previous = Feed.previous_election()
    municipality_ids = Enum.uniq(live_municipality_ids() ++ previous_municipality_ids())

    for {municipality_id, data} <- read_municipality_files(previous, municipality_ids) do
      store_municipality_file(previous, municipality_id, fn ->
        insert_previous_ward_results(previous.year, data)
      end)
    end

    Parties.broadcast_wards_mapped()
    :ok
  end

  defp live_municipality_ids, do: Map.keys(Results.list_area_names(:municipality))

  defp previous_municipality_ids do
    Repo.all(
      from snapshot in Snapshot,
        where: snapshot.election == ^Results.previous_year() and snapshot.level == :municipality,
        distinct: true,
        select: snapshot.area_id
    )
  end

  defp unread_municipality_ids(election, municipality_ids) do
    read = Results.list_stored_feeds(election.year, "munic-")
    Enum.reject(municipality_ids, &(municipality_feed_name(&1) in read))
  end

  defp municipality_feed_name(municipality_id), do: "munic-#{municipality_id}"

  # The files of an election's municipalities not read yet, lazily, one by one as they
  # are fetched: `{municipality_id, data}`. A file that fails is skipped (left unread).
  defp read_municipality_files(election, municipality_ids) do
    election
    |> unread_municipality_ids(municipality_ids)
    |> Stream.flat_map(fn municipality_id ->
      case fetch_municipality_file(election, municipality_id) do
        nil -> []
        data -> [{municipality_id, data}]
      end
    end)
  end

  # One municipality file (up to ~3 MB), fetched politely.
  defp fetch_municipality_file(election, municipality_id) do
    url = Feed.municipality_url(election, municipality_id)
    Process.sleep(@pause)

    case Feed.get(url) do
      {:ok, data, _body, _cache} ->
        data

      other ->
        Logger.warning("Municipality file #{url} failed (#{inspect(other)})")
        nil
    end
  end

  # Stores a municipality file's rows and records it as read in one transaction, so a
  # failure leaves it unread and it is fetched again on the next pass.
  defp store_municipality_file(election, municipality_id, insert_rows) do
    Repo.transact(fn ->
      insert_rows.()

      Results.record_read!(
        election.year,
        municipality_feed_name(municipality_id),
        Feed.municipality_url(election, municipality_id)
      )

      {:ok, municipality_id}
    end)
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
    |> Enum.uniq_by(&{&1.party_id, &1.ward_id})
    |> upsert_ward_results()
  end
end
