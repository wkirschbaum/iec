defmodule Iec.Cache do
  @moduledoc """
  Shares computed data between viewers in memory (ETS), so a crowd costs the database once
  per change, not once per open page.

  Two tiers, each with its own version:

    * **data** (`fetch/2`): page data built from the results, which change every minute or
      so while counting runs. `invalidate/0` bumps it whenever results change
      (`Iec.Results.broadcast/1`). Party files change several times a second, so they use
      `invalidate_soon/0`, which bumps at most once per half second.
    * **lasting** (`fetch_lasting/2`): data that only changes when it is imported again —
      map outlines, area names, earlier elections, the ward directory's places. Kept across
      results changes; `invalidate_lasting/0` bumps it after such an import (and the data
      tier with it, since page data is built from it).

  After a bump the first caller recomputes a key while the others wait briefly for its
  value instead of all hitting the database at once.

  Keys come partly from URLs (a ward page per ward id), and after the count nothing bumps
  the version, so one version of a tier holds at most 5 000 entries: past that they are
  dropped and it starts filling again.

  Disabled in tests (`config :iec, Iec.Cache, enabled: false`), where data changes under
  each test.
  """
  use GenServer

  @table __MODULE__
  @tiers [:data, :lasting]
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

    :ets.insert(@table, Enum.flat_map(@tiers, &[{{:version, &1}, 0}, {{:entries, &1}, 0}]))
    {:ok, %{pending: false}}
  end

  @doc "The value for `key` at the current data version, computing it at most once."
  def fetch(key, compute), do: fetch_in(:data, key, compute)

  @doc """
  The value for `key` until the next `invalidate_lasting/0`, computing it at most once:
  for data that only changes when it is imported again.
  """
  def fetch_lasting(key, compute), do: fetch_in(:lasting, key, compute)

  defp fetch_in(tier, key, compute) do
    if enabled?(), do: fetch(tier, key, compute, version(tier)), else: compute.()
  end

  defp fetch(tier, key, compute, version) do
    case :ets.lookup(@table, {:entry, tier, key, version}) do
      [{_entry, value}] ->
        value

      [] ->
        if :ets.insert_new(@table, {{:lock, tier, key, version}, self()}) do
          compute_and_store(tier, key, compute, version)
        else
          wait(tier, key, compute, version, @wait_attempts)
        end
    end
  end

  # The lock row is ours (taken by the caller, or forced after a wait): compute, store
  # unless the data moved on, and release it.
  defp compute_and_store(tier, key, compute, version) do
    value = compute.()
    store(tier, key, value, version)
    value
  after
    :ets.match_delete(@table, {{:lock, tier, key, version}, self()})
  end

  defp store(tier, key, value, version) do
    if version(tier) == version do
      if :ets.update_counter(@table, {:entries, tier}, 1) > @max_entries,
        do: drop_entries(tier, version + 1)

      :ets.insert(@table, {{:entry, tier, key, version}, value})
    end
  end

  # Drops a tier's entries and locks from versions before `below`; too many entries for
  # one version, or a bump, starts that tier over.
  defp drop_entries(tier, below) do
    :ets.insert(@table, {{:entries, tier}, 0})

    for kind <- [:entry, :lock] do
      :ets.select_delete(@table, [
        {{{kind, tier, :_, :"$1"}, :_}, [{:<, :"$1", below}], [true]}
      ])
    end

    :ok
  end

  # Another caller is computing this key: take its value when it lands. If the data moved
  # on meanwhile, start again at the new version; if the computing caller died, take its
  # lock over; if it takes too long, compute anyway.
  defp wait(tier, key, compute, version, 0) do
    :ets.insert(@table, {{:lock, tier, key, version}, self()})
    compute_and_store(tier, key, compute, version)
  end

  defp wait(tier, key, compute, version, attempts) do
    Process.sleep(@wait_step)

    case :ets.lookup(@table, {:entry, tier, key, version}) do
      [{_entry, value}] ->
        value

      [] ->
        current = version(tier)

        cond do
          current != version -> fetch(tier, key, compute, current)
          lock_held?(tier, key, version) -> wait(tier, key, compute, version, attempts - 1)
          true -> fetch(tier, key, compute, version)
        end
    end
  end

  # A lock whose owner is gone (killed mid-compute, so its `after` never ran) is removed.
  defp lock_held?(tier, key, version) do
    case :ets.lookup(@table, {:lock, tier, key, version}) do
      [{_lock, owner}] ->
        if Process.alive?(owner) do
          true
        else
          :ets.match_delete(@table, {{:lock, tier, key, version}, owner})
          false
        end

      [] ->
        false
    end
  end

  @doc "Marks the data tier stale (results changed) and drops its old entries and locks."
  def invalidate, do: bump(:data)

  @doc """
  Marks the lasting tier stale after an import (outlines, earlier elections, places), and
  the data tier with it.
  """
  def invalidate_lasting do
    bump(:lasting)
    bump(:data)
  end

  defp bump(tier) do
    if enabled?() do
      version = :ets.update_counter(@table, {:version, tier}, 1)
      drop_entries(tier, version)
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

  defp version(tier), do: :ets.lookup_element(@table, {:version, tier}, 2)

  defp enabled?, do: Application.get_env(:iec, __MODULE__, [])[:enabled] != false
end
