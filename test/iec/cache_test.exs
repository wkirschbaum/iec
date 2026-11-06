defmodule Iec.CacheTest do
  use ExUnit.Case, async: false

  alias Iec.Cache

  setup do
    Application.put_env(:iec, Cache, enabled: true)
    Cache.invalidate()
    on_exit(fn -> Application.put_env(:iec, Cache, enabled: false) end)
  end

  test "computes once per data change, however many ask at the same moment" do
    counter = :counters.new(1, [])

    compute = fn ->
      :counters.add(counter, 1, 1)
      Process.sleep(50)
      :counters.get(counter, 1)
    end

    values =
      1..50
      |> Enum.map(fn _viewer -> Task.async(fn -> Cache.fetch(:page, compute) end) end)
      |> Task.await_many()

    assert Enum.uniq(values) == [1]
    assert :counters.get(counter, 1) == 1

    Cache.invalidate()
    assert Cache.fetch(:page, compute) == 2
    assert Cache.fetch(:page, compute) == 2
  end

  test "a caller killed while computing does not hold the others up" do
    owner = spawn(fn -> Cache.fetch(:page, fn -> Process.sleep(:infinity) end) end)
    wait_until(fn -> :ets.match(Cache, {{:lock, :page, :_}, owner}) != [] end)
    Process.exit(owner, :kill)

    {microseconds, value} = :timer.tc(fn -> Cache.fetch(:page, fn -> :fresh end) end)

    assert value == :fresh
    assert microseconds < 1_000_000
    assert Cache.fetch(:page, fn -> :recomputed end) == :fresh
  end

  test "drops a version's entries once it holds too many" do
    for key <- 1..5_000, do: Cache.fetch({:ward, key}, fn -> :first end)
    assert Cache.fetch({:ward, 1}, fn -> :again end) == :first

    Cache.fetch({:ward, 5_001}, fn -> :first end)

    assert Cache.fetch({:ward, 1}, fn -> :again end) == :again
    assert :ets.info(Cache, :size) < 100
  end

  test "invalidate_soon/0 bumps the version once for many calls, a moment later" do
    assert Cache.fetch(:page, fn -> 1 end) == 1

    for _change <- 1..20, do: Cache.invalidate_soon()
    assert Cache.fetch(:page, fn -> 2 end) == 1

    wait_until(fn -> Cache.fetch(:page, fn -> 2 end) == 2 end)
    Process.sleep(700)
    assert Cache.fetch(:page, fn -> 3 end) == 2
  end

  defp wait_until(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(20)
        wait_until(condition, attempts - 1)
    end
  end
end
