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
end
