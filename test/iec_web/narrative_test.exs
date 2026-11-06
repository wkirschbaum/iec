defmodule IecWeb.NarrativeTest do
  use ExUnit.Case, async: true

  alias IecWeb.Narrative

  @rows [
    %{party_id: 7, party_name: "ANC", share: 31.9, previous_share: 45.6, swing: -13.7},
    %{party_id: 52, party_name: "DA", share: 24.4, previous_share: 21.7, swing: 2.7},
    %{party_id: 1748, party_name: "MKP", share: 9.2, previous_share: nil, swing: nil}
  ]

  defp snapshot(complete) do
    %{
      voting_districts_complete: complete,
      voting_districts_expected: 100,
      municipalities_complete: 50,
      municipalities_expected: 213,
      hung_councils: 30
    }
  end

  test "while counting it says who leads, how far the count is, and that it is live" do
    summary = Narrative.summary(snapshot(75), @rows, %{}, 2021)

    assert summary.headline == "ANC leads with 31.9%, down 13.7 points on 2021"
    refute summary.lede =~ "ANC is second"
    assert summary.lede =~ "DA is second with 24.4%, 7.5 points behind."
    assert summary.lede =~ "MKP, not on the 2021 list, has 9.2%."
    assert summary.lede =~ "30 of 50 decided councils are hung."
    assert summary.lede =~ "75.0% of voting districts counted."
    assert summary.eyebrow == "Live · 75.0% counted"
    assert summary.live
  end

  test "once every district is counted it says who won" do
    summary = Narrative.summary(snapshot(100), @rows, %{}, 2021)

    assert summary.headline =~ "ANC wins with 31.9%"
    assert summary.lede =~ "DA finishes second"
    assert summary.lede =~ "Every voting district is counted."
    assert summary.eyebrow == "Final results"
    refute summary.live
  end

  test "nothing to say before there are results" do
    assert Narrative.summary(nil, @rows, %{}, 2021) == nil
    assert Narrative.summary(snapshot(0), [], %{}, 2021) == nil
  end
end
