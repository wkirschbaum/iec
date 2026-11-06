defmodule Iec.Cache do
  @moduledoc """
  Shares computed page data between viewers, so a crowd costs the database once per data
  change, not once per open page.

  Entries are keyed by the data version, which `invalidate/0` bumps whenever results
  change (`Iec.Results.broadcast/1`). Party files change several times a second while
  counting runs, so they use `invalidate_soon/0`, which bumps at most once per half
  second. After a bump the first caller recomputes a key while the others
  wait briefly for its value instead of all hitting the database at once.

  Keys come partly from URLs (a ward page per ward id), and after the count nothing bumps
  the version, so one version holds at most 5 000 entries: past that they are dropped and
  it starts filling again.

  Disabled in tests (`config :iec, Iec.Cache, enabled: false`), where data changes under
  each test.
  """
  use GenServer

  @table __MODULE__
  @wait_step 25
  @wait_attempts 200
  @coalesce_interval 500
  @max_entries 5_000

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.insert(@table, [{:version, 0}, {:entries, 0}])
    {:ok, %{pending: false}}
  end

  @doc "The value for `key` at the current data version, computing it at most once."
  def fetch(key, compute) do
    if enabled?(), do: fetch(key, compute, version()), else: compute.()
  end

  defp fetch(key, compute, version) do
    case :ets.lookup(@table, {:entry, key, version}) do
      [{_entry, value}] ->
        value

      [] ->
        if :ets.insert_new(@table, {{:lock, key, version}, self()}) do
          compute_and_store(key, compute, version)
        else
          wait(key, compute, version, @wait_attempts)
        end
    end
  end

  # The lock row is ours (taken by the caller, or forced after a wait): compute, store
  # unless the data moved on, and release it.
  defp compute_and_store(key, compute, version) do
    value = compute.()
    store(key, value, version)
    value
  after
    :ets.match_delete(@table, {{:lock, key, version}, self()})
  end

  defp store(key, value, version) do
    if version() == version do
      if :ets.update_counter(@table, :entries, 1) > @max_entries, do: drop_entries(version)
      :ets.insert(@table, {{:entry, key, version}, value})
    end
  end

  # Too many entries for one version: start over with this one.
  defp drop_entries(version) do
    :ets.select_delete(@table, [{{{:entry, :_, :"$1"}, :_}, [{:"=<", :"$1", version}], [true]}])
    :ets.insert(@table, {:entries, 1})
  end

  # Another caller is computing this key: take its value when it lands. If the data moved
  # on meanwhile, start again at the new version; if the computing caller died, take its
  # lock over; if it takes too long, compute anyway.
  defp wait(key, compute, version, 0) do
    :ets.insert(@table, {{:lock, key, version}, self()})
    compute_and_store(key, compute, version)
  end

  defp wait(key, compute, version, attempts) do
    Process.sleep(@wait_step)

    case :ets.lookup(@table, {:entry, key, version}) do
      [{_entry, value}] ->
        value

      [] ->
        current = version()

        cond do
          current != version ->
            fetch(key, compute, current)

          lock_held?(key, version) ->
            wait(key, compute, version, attempts - 1)

          true ->
            fetch(key, compute, version)
        end
    end
  end

  # A lock whose owner is gone (killed mid-compute, so its `after` never ran) is removed.
  defp lock_held?(key, version) do
    case :ets.lookup(@table, {:lock, key, version}) do
      [{_lock, owner}] ->
        if Process.alive?(owner) do
          true
        else
          :ets.match_delete(@table, {{:lock, key, version}, owner})
          false
        end

      [] ->
        false
    end
  end

  @doc "Marks all cached data stale (the data changed) and drops the old entries and locks."
  def invalidate do
    if enabled?() do
      version = :ets.update_counter(@table, :version, 1)
      :ets.insert(@table, {:entries, 0})
      :ets.select_delete(@table, [{{{:entry, :_, :"$1"}, :_}, [{:<, :"$1", version}], [true]}])
      :ets.select_delete(@table, [{{{:lock, :_, :"$1"}, :_}, [{:<, :"$1", version}], [true]}])
    end

    :ok
  end

  @doc """
  Like `invalidate/0`, but coalesced: many calls within half a second bump the version
  once, at the end of it. For party files, which change several times a second
  during the count; pages refresh well after the broadcast, so they still see the bump.
  """
  def invalidate_soon do
    if enabled?(), do: GenServer.cast(__MODULE__, :invalidate_soon)
    :ok
  end

  @impl true
  def handle_cast(:invalidate_soon, %{pending: true} = state), do: {:noreply, state}

  def handle_cast(:invalidate_soon, state) do
    Process.send_after(self(), :invalidate, @coalesce_interval)
    {:noreply, %{state | pending: true}}
  end

  @impl true
  def handle_info(:invalidate, state) do
    invalidate()
    {:noreply, %{state | pending: false}}
  end

  defp version, do: :ets.lookup_element(@table, :version, 2)

  defp enabled?, do: Application.get_env(:iec, __MODULE__, [])[:enabled] != false
end
