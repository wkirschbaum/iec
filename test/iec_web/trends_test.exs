defmodule IecWeb.TrendsTest do
  use ExUnit.Case, async: true

  alias Iec.Results.{PartyResult, Snapshot}
  alias IecWeb.Trends

  defp snapshot(shares) do
    %Snapshot{
      registered_voters: 100,
      total_votes_cast: 150,
      party_results:
        for {party_id, share} <- shares do
          %PartyResult{party_id: party_id, party_name: "P#{party_id}", vote_percentage: share}
        end
    }
  end

  defp history do
    [
      {2000, snapshot([{7, 59.4}, {52, 22.1}, {3, 9.1}, {99, 0.5}])},
      {2016, snapshot([{7, 53.9}, {52, 26.9}, {3, 4.3}])},
      {2026, snapshot([{7, 31.9}, {52, 24.4}, {1748, 9.2}])}
    ]
  end

  test "a series per party that mattered, biggest peak first, on a round scale" do
    trend = Trends.series(history(), :vote_percentage, %{}, threshold: 2.5)

    assert trend.years == [2000, 2016, 2026]
    assert Enum.map(trend.series, & &1.party_id) == [7, 52, 1748, 3]
    assert hd(trend.series).points == [{2000, 59.4}, {2016, 53.9}, {2026, 31.9}]
    assert {trend.max, trend.step} == {60.0, 20.0}
  end

  test "the summary tells the long-run story of today's biggest parties" do
    trend = Trends.series(history(), :vote_percentage, %{}, threshold: 2.5)

    assert Trends.summary(trend, 2026, false) ==
             "Since 2000: Party 7 from 59.4% to 31.9%; Party 52 from 22.1% to 24.4%; " <>
               "and Party 1748, new this time, has 9.2% so far."

    assert Trends.summary(trend, 2026, true) =~ "new this time, won 9.2%."
  end

  test "totals per election" do
    assert [%{year: 2000, registered: 100, votes_cast: 150} | _] = Trends.totals(history())
  end
end
