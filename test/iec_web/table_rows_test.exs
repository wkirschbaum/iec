defmodule IecWeb.TableRowsTest do
  use ExUnit.Case, async: true

  alias IecWeb.TableRows

  describe "ward_tally/2" do
    test "sets the declared wards against who won those same wards before" do
      rows = [
        # Declared: party 52 took it from party 7.
        %{ward_id: 1, holder: 52, previous_holder: 7},
        # Still counting: party 7 held it, but it is not compared yet.
        %{ward_id: 2, holder: nil, previous_holder: 7},
        %{ward_id: 3, holder: nil, previous_holder: 7}
      ]

      tally = TableRows.ward_tally(rows, %{}) |> Map.new(&{&1.party_id, &1})

      assert %{wards: 1, previous_wards: 0, change: 1} = tally[52]
      assert %{wards: 0, previous_wards: 1, change: -1} = tally[7]
    end
  end
end
