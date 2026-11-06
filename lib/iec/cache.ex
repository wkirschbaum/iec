defmodule Iec.Cache do
  @moduledoc """
  Shares computed page data between viewers, so a crowd costs the database once per data
  change, not once per open page.

  Entries are keyed by the data version, which `invalidate/0` bumps whenever results or
  party files change (`Iec.Results.broadcast/1`, `Iec.Parties`). After a bump the first
  caller recomputes a key while the others wait briefly for its value instead of all
  hitting the database at once.

  Disabled in tests (`config :iec, Iec.Cache, enabled: false`), where data changes under
  each test.
  """
  use GenServer

  @table __MODULE__
  @wait_step 25
  @wait_attempts 200

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

    :ets.insert(@table, {:version, 0})
    {:ok, nil}
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
        if :ets.insert_new(@table, {{:lock, key, version}}) do
          compute_and_store(key, compute, version)
        else
          wait(key, compute, version, @wait_attempts)
        end
    end
  end

  defp compute_and_store(key, compute, version) do
    value = compute.()
    :ets.insert(@table, {{:entry, key, version}, value})
    value
  after
    :ets.delete(@table, {:lock, key, version})
  end

  # Another caller is computing this key: take its value when it lands. If the data moved
  # on meanwhile, start again at the new version; if it takes too long, compute anyway.
  defp wait(_key, compute, _version, 0), do: compute.()

  defp wait(key, compute, version, attempts) do
    Process.sleep(@wait_step)

    case :ets.lookup(@table, {:entry, key, version}) do
      [{_entry, value}] ->
        value

      [] ->
        current = version()

        cond do
          current != version -> fetch(key, compute, current)
          :ets.member(@table, {:lock, key, version}) -> wait(key, compute, version, attempts - 1)
          true -> fetch(key, compute, version)
        end
    end
  end

  @doc "Marks all cached data stale (the data changed) and drops the old entries."
  def invalidate do
    if enabled?() do
      version = :ets.update_counter(@table, :version, 1)
      :ets.select_delete(@table, [{{{:entry, :_, :"$1"}, :_}, [{:<, :"$1", version}], [true]}])
    end

    :ok
  end

  defp version, do: :ets.lookup_element(@table, :version, 2)

  defp enabled?, do: Application.get_env(:iec, __MODULE__, [])[:enabled] != false
end
