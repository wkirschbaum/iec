defmodule IecWeb.SortingTest do
  use ExUnit.Case, async: true

  alias IecWeb.Sorting

  @rows [
    %{name: "eThekwini", share: 30.5, declared_at: ~U[2026-11-06 07:00:00Z]},
    %{name: "Buffalo City", share: nil, declared_at: nil},
    %{name: "Cape Town", share: 55.0, declared_at: ~U[2026-11-05 22:00:00Z]}
  ]

  defp names(rows), do: Enum.map(rows, & &1.name)

  describe "sort_rows/2" do
    test "leaves rows alone without a sort" do
      assert Sorting.sort_rows(@rows, nil) == @rows
    end

    test "sorts numbers either way, missing values last" do
      assert names(Sorting.sort_rows(@rows, {"share", :desc})) ==
               ["Cape Town", "eThekwini", "Buffalo City"]

      assert names(Sorting.sort_rows(@rows, {"share", :asc})) ==
               ["eThekwini", "Cape Town", "Buffalo City"]
    end

    test "sorts text case-insensitively and times chronologically" do
      assert names(Sorting.sort_rows(@rows, {"name", :asc})) ==
               ["Buffalo City", "Cape Town", "eThekwini"]

      assert names(Sorting.sort_rows(@rows, {"declared_at", :asc})) ==
               ["Cape Town", "eThekwini", "Buffalo City"]
    end

    test "ignores columns that are no field" do
      assert Sorting.sort_rows(@rows, {"no such column ever", :asc}) == @rows
    end
  end

  describe "sorted_page/3" do
    test "sorts, then takes the first rows, counting them all" do
      assert %{rows: [%{name: "Cape Town"}], shown: 1, total: 3} =
               Sorting.sorted_page(@rows, {"share", :desc}, 1)
    end

    test "shows every row when the limit is past the end" do
      assert %{shown: 3, total: 3} = Sorting.sorted_page(@rows, nil, 25)
    end
  end
end
