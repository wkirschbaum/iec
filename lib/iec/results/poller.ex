defmodule Iec.Results.Poller do
  @moduledoc """
  Polls one IEC feed file. Each request is conditional on the previous response's
  validators, and the next one is scheduled for when the edge copy expires
  (`Cache-Control: max-age` minus `Age`), or after `:minimum_interval` if that is longer. New content is ingested and announced; failures
  back off from 30 seconds to 5 minutes.

  Each poller keeps its latest status as its Registry value, so `statuses/0` reads them
  without waiting on a poller that is mid-download.
  """
  use GenServer

  require Logger

  alias Iec.{Parties, Results}
  alias Iec.Results.Feed

  @registry Iec.Results.Registry
  @maximum_backoff :timer.minutes(5)
  @unpublished_retry :timer.minutes(5)

  def start_link(options) do
    feed = Keyword.fetch!(options, :feed)

    GenServer.start_link(__MODULE__, options,
      name: {:via, Registry, {@registry, feed.name, initial_status(feed)}}
    )
  end

  def child_spec(options) do
    feed = Keyword.fetch!(options, :feed)
    %{id: {__MODULE__, feed.name}, start: {__MODULE__, :start_link, [options]}}
  end

  @doc "The latest status of every running poller, keyed by feed name."
  def statuses do
    @registry
    |> Registry.select([{{:"$1", :_, :"$2"}, [{:is_map, :"$2"}], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end

  @doc "True when a poller for this feed is running."
  def running?(feed_name), do: Registry.lookup(@registry, feed_name) != []

  defp initial_status(feed),
    do: %{feed: feed.name, checked_at: nil, result: :pending, next_poll_at: nil}

  @impl true
  def init(options) do
    feed = Keyword.fetch!(options, :feed)
    Process.send_after(self(), :poll, Keyword.get(options, :initial_delay, 0))

    {:ok,
     %{
       feed: feed,
       validators: %{etag: nil, last_modified: nil},
       failures: 0,
       minimum_interval: Keyword.get(options, :minimum_interval, 0)
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    {result, state, delay} = poll(state)

    status = %{
      feed: state.feed.name,
      checked_at: DateTime.utc_now(),
      result: result,
      next_poll_at: DateTime.add(DateTime.utc_now(), delay, :millisecond)
    }

    Registry.update_value(@registry, state.feed.name, fn _previous -> status end)
    Results.broadcast_feed_status(status)
    Process.send_after(self(), :poll, delay)
    {:noreply, state}
  end

  defp poll(%{feed: feed} = state) do
    with {:ok, data, body, cache} <- Feed.get(feed.url, state.validators),
         {:ok, changed} <- ingest(feed, data, body, cache.validators) do
      {{:updated, changed}, %{state | validators: cache.validators, failures: 0},
       next_delay(state, cache)}
    else
      {:not_modified, cache} ->
        {:not_modified, %{state | validators: cache.validators, failures: 0},
         next_delay(state, cache)}

      # A party file the IEC has not published yet: check again later, not a failure.
      {:error, {:http_status, status}} when feed.kind == :party and status in [404, 406] ->
        {:no_file, %{state | failures: 0}, @unpublished_retry}

      {:error, reason} ->
        failures = state.failures + 1
        Logger.warning("#{feed.name}: #{inspect(reason)}, attempt #{failures}")
        delay = min(:timer.seconds(30) * 2 ** (failures - 1), @maximum_backoff)
        {{:error, reason}, %{state | failures: failures}, delay}
    end
  end

  # When the cached copy expires, but never sooner than this poller's minimum interval
  # (parties beyond the national list are checked every few minutes).
  defp next_delay(state, cache), do: max(cache.next_poll_in, state.minimum_interval)

  # Stores a new file and announces what changed. A failure here (say, a file the
  # parser chokes on) backs off like a failed download instead of crash-looping.
  defp ingest(feed, data, body, validators) do
    case store(feed, data, body, validators) do
      {:ok, changed} -> {:ok, changed}
      {:error, reason} -> {:error, {:ingest_failed, reason}}
    end
  rescue
    exception -> {:error, {:ingest_failed, Exception.message(exception)}}
  end

  defp store(%{kind: :party} = feed, data, body, validators) do
    with {:ok, changed} <- Parties.ingest(feed, data, body, validators) do
      if changed > 0, do: Parties.broadcast_changed(feed.party_id)
      {:ok, changed}
    end
  end

  defp store(feed, data, body, validators) do
    with {:ok, snapshots} <- Results.ingest(feed, data, body, validators) do
      if snapshots != [] do
        Logger.info("#{feed.name}: #{length(snapshots)} areas changed")
        Results.broadcast({:results_changed, Enum.map(snapshots, & &1.id)})
        if feed.kind == :national, do: Parties.follow_national_parties()
      end

      {:ok, length(snapshots)}
    end
  end
end
