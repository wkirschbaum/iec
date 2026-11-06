defmodule Iec.Results do
  @moduledoc """
  Election results pulled from the IEC's public results feed, kept as a history.

  Every area (national, province, municipality) gets a new snapshot only when its
  figures change, linked to the snapshot before it, so the history answers "what
  changed when". The previous election is imported once, to compare against.

  Query functions take an `:election` filter (a year) and default to the live election.
  """

  import Ecto.Query

  require Logger

  alias Iec.Repo
  alias Iec.Results.{Feed, Fetch, Parser, Party, PartyResult, Snapshot}

  @topic "results"
  @feed_topic "feeds"

  @doc "Subscribes the caller to `{:results_changed, snapshot_ids}` and `:parties_refreshed`."
  def subscribe, do: Phoenix.PubSub.subscribe(Iec.PubSub, @topic)

  def broadcast(message), do: Phoenix.PubSub.broadcast(Iec.PubSub, @topic, message)

  @doc "Subscribes the caller to `{:feed_status, status}` after every poll of every feed."
  def subscribe_feed_status, do: Phoenix.PubSub.subscribe(Iec.PubSub, @feed_topic)

  def broadcast_feed_status(status),
    do: Phoenix.PubSub.broadcast(Iec.PubSub, @feed_topic, {:feed_status, status})

  def live_year, do: Feed.live_election().year
  def previous_year, do: Feed.previous_election().year

  @doc """
  The party with the most valid votes in a snapshot (parties only, not "Other"), or nil
  before anyone has votes.
  """
  def leading_party(nil), do: nil

  def leading_party(%Snapshot{party_results: party_results}) do
    party_results
    |> Enum.filter(&(&1.party_id >= 0 and (&1.total_valid_votes || 0) > 0))
    |> Enum.max_by(& &1.total_valid_votes, fn -> nil end)
  end

  @doc "The change in vote share in percentage points, or nil when either side is missing."
  def swing(now, before) when is_number(now) and is_number(before),
    do: Float.round((now - before) / 1, 2)

  def swing(_now, _before), do: nil

  ## Ingesting

  @doc """
  Stores a downloaded feed file: the raw fetch, plus a snapshot for each area whose
  figures differ from its latest snapshot. Returns the new snapshots.
  """
  def ingest(feed, data, body, validators) do
    areas = Parser.parse(feed.kind, data)

    Repo.transact(fn ->
      fetch =
        Repo.insert!(
          %Fetch{
            election: feed.election,
            feed: feed.name,
            url: feed.url,
            etag: validators[:etag],
            last_modified: validators[:last_modified],
            report_date: Parser.report_date(data),
            body_bytes: byte_size(body),
            body: :zlib.gzip(body)
          },
          log: false
        )

      latest = latest_snapshots_by_area(feed.election, areas)

      snapshots =
        Enum.flat_map(areas, fn area ->
          case latest[{area.level, area.area_id}] do
            %Snapshot{content_hash: hash} when hash == area.content_hash -> []
            previous -> [insert_snapshot!(fetch, area, previous)]
          end
        end)

      {:ok, snapshots}
    end)
  end

  defp insert_snapshot!(fetch, area, previous) do
    snapshot =
      Snapshot
      |> struct(Map.delete(area, :party_results))
      |> Map.merge(%{
        election: fetch.election,
        fetch_id: fetch.id,
        previous_snapshot_id: previous && previous.id
      })
      |> Repo.insert!()

    rows = Enum.map(area.party_results, &Map.put(&1, :snapshot_id, snapshot.id))
    Repo.insert_all(PartyResult, rows)

    snapshot
  end

  defp latest_snapshots_by_area(election, areas) do
    areas
    |> Enum.group_by(& &1.level, & &1.area_id)
    |> Enum.flat_map(fn {level, area_ids} ->
      Snapshot
      |> latest_per_area()
      |> filter_snapshots(election: election, level: level)
      |> where([snapshot], snapshot.area_id in ^area_ids)
      |> Repo.all()
    end)
    |> Map.new(&{{&1.level, &1.area_id}, &1})
  end

  @doc """
  Imports the previous election's final results, file by file, skipping files already
  stored (so a failed file is retried on the next start). Its files no longer change.
  """
  def import_previous_election, do: import_election(Feed.previous_election())

  @doc """
  Imports the earlier elections (config `history_elections`) for the trends: national
  and province results, once each.
  """
  def import_history do
    for election <- Feed.all_elections(),
        election.year not in [live_year(), previous_year()],
        do: import_election(election)

    :ok
  end

  @doc "Imports an election's national and province files not stored yet."
  def import_election(election) do
    imported =
      Repo.all(from fetch in Fetch, where: fetch.election == ^election.year, select: fetch.feed)

    for feed <- Feed.feeds(election), feed.name not in imported do
      with {:error, reason} <- import_feed(feed) do
        Logger.warning("#{election.year} #{feed.name}: import failed (#{inspect(reason)})")
      end
    end

    :ok
  end

  @doc "Fetches one feed file once and stores it. Returns the new snapshots."
  def import_feed(feed) do
    case Feed.get(feed.url) do
      {:ok, data, body, cache} -> ingest(feed, data, body, cache.validators)
      other -> {:error, other}
    end
  end

  @doc """
  Stores party abbreviations, names and colours from every election's party list, oldest
  first, so the latest names win for parties in several.
  """
  def refresh_parties do
    now = DateTime.utc_now()

    for election <- Feed.all_elections(),
        {:ok, parties, _body, _cache} <- [Feed.get(Feed.party_list_url(election))] do
      rows =
        for party <- parties,
            is_integer(party["ID"]) and party["ID"] > 0,
            party["Name"] || party["PartyFullName"] do
          %{
            id: party["ID"],
            abbreviation: party["Name"] || party["PartyFullName"],
            name: party["PartyFullName"] || party["Name"],
            colour: party["sWebColour"],
            inserted_at: now,
            updated_at: now
          }
        end
        |> Enum.uniq_by(& &1.id)

      Repo.insert_all(Party, rows,
        on_conflict: {:replace, [:abbreviation, :name, :colour, :updated_at]},
        conflict_target: :id
      )
    end

    broadcast(:parties_refreshed)
    :ok
  end

  @doc "Every known party, keyed by id."
  def parties_by_id, do: Repo.all(Party) |> Map.new(&{&1.id, &1})

  ## Reading

  @doc """
  An area's latest snapshot in every election, oldest first: `[{year, snapshot}]`, for
  trends. Elections without results for the area are left out.
  """
  def list_snapshots_by_election(level, area_id) do
    Snapshot
    |> where([snapshot], snapshot.level == ^level and snapshot.area_id == ^area_id)
    |> distinct([snapshot], snapshot.election)
    |> order_by([snapshot], asc: snapshot.election, desc: snapshot.id)
    |> preload(party_results: ^party_results_query())
    |> Repo.all()
    |> Enum.map(&{&1.election, &1})
  end

  @doc """
  The latest snapshot of every area at a level in every election: `%{area_id =>
  [{year, snapshot}]}`, oldest first.
  """
  def list_snapshots_by_election(level) do
    Snapshot
    |> where([snapshot], snapshot.level == ^level)
    |> distinct([snapshot], [snapshot.area_id, snapshot.election])
    |> order_by([snapshot], asc: snapshot.area_id, asc: snapshot.election, desc: snapshot.id)
    |> preload(party_results: ^party_results_query())
    |> Repo.all()
    |> Enum.group_by(& &1.area_id, &{&1.election, &1})
  end

  @doc "The latest snapshot of an area, with its party results, or nil."
  def get_latest_snapshot(level, area_id, filters \\ []) do
    Snapshot
    |> filter_snapshots(with_election(filters) ++ [level: level, area_id: area_id])
    |> order_by(desc: :id)
    |> limit(1)
    |> preload(party_results: ^party_results_query())
    |> Repo.one()
  end

  @doc """
  The latest snapshot of every area matching the filters, with party results.

  Filters: `:election`, `:level`, `:province_id`.
  """
  def list_latest_snapshots(filters \\ []) do
    Snapshot
    |> latest_per_area()
    |> filter_snapshots(with_election(filters))
    |> subquery()
    |> order_by(asc: :area_name)
    |> preload(party_results: ^party_results_query())
    |> Repo.all()
  end

  @doc """
  Snapshots newest first, each with its previous snapshot, both with party results.
  A snapshot with no previous one is an area's first appearance.

  Filters: `:election`, `:level`, `:area_id`, `:province_id`, `:limit` (default 100),
  `:changed_only` (leave out first snapshots).
  """
  def list_changes(filters \\ []) do
    Snapshot
    |> filter_snapshots(with_election(filters))
    |> order_by(desc: :id)
    |> limit(^Keyword.get(filters, :limit, 100))
    |> preload(
      party_results: ^party_results_query(),
      previous_snapshot: [party_results: ^party_results_query()]
    )
    |> Repo.all()
  end

  @doc "Area id → name for every area at a level, from the latest live snapshots."
  def list_area_names(level) do
    Repo.all(
      from snapshot in Snapshot,
        where: snapshot.election == ^live_year() and snapshot.level == ^level,
        distinct: snapshot.area_id,
        order_by: [asc: snapshot.area_id, desc: snapshot.id],
        select: {snapshot.area_id, snapshot.area_name}
    )
    |> Map.new()
  end

  @doc """
  How far the live count is, from the latest national snapshot: the progress counters,
  votes cast and the IEC report time. Nil before the first national poll.
  """
  def get_count_progress do
    Repo.one(
      from snapshot in Snapshot,
        where: snapshot.election == ^live_year() and snapshot.level == :national,
        order_by: [desc: snapshot.id],
        limit: 1,
        select:
          map(snapshot, [
            :voting_districts_complete,
            :voting_districts_expected,
            :wards_complete,
            :wards_expected,
            :municipalities_complete,
            :municipalities_expected,
            :seats_complete,
            :seats_expected,
            :total_votes_cast,
            :report_date
          ])
    )
  end

  @doc "The name of an area in its latest live snapshot, or nil."
  def get_area_name(level, area_id) do
    Repo.one(
      from snapshot in Snapshot,
        where:
          snapshot.election == ^live_year() and snapshot.level == ^level and
            snapshot.area_id == ^area_id,
        order_by: [desc: snapshot.id],
        limit: 1,
        select: snapshot.area_name
    )
  end

  defp party_results_query, do: from(party_result in PartyResult, order_by: party_result.position)

  defp with_election(filters), do: Keyword.put_new(filters, :election, live_year())

  defp latest_per_area(query) do
    query
    |> distinct([snapshot], [snapshot.level, snapshot.area_id])
    |> order_by([snapshot], asc: snapshot.level, asc: snapshot.area_id, desc: snapshot.id)
  end

  defp filter_snapshots(query, filters) do
    Enum.reduce(filters, query, fn
      {:election, year}, query ->
        where(query, [snapshot], snapshot.election == ^year)

      {:level, level}, query ->
        where(query, [snapshot], snapshot.level == ^level)

      {:area_id, area_id}, query ->
        where(query, [snapshot], snapshot.area_id == ^area_id)

      {:province_id, id}, query ->
        where(query, [snapshot], snapshot.province_id == ^id)

      {:changed_only, true}, query ->
        where(query, [snapshot], not is_nil(snapshot.previous_snapshot_id))

      {_other, _value}, query ->
        query
    end)
  end
end
