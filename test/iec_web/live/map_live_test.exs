defmodule IecWeb.MapLiveTest do
  use IecWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Iec.{Repo, Results}
  alias Iec.Maps.Boundary

  defp boundary(area_id, name) do
    %{
      level: :municipality,
      area_id: area_id,
      province_id: 3,
      municipality_id: area_id,
      name: name,
      path: "M0 0l10 0 0 10z",
      min_x: 0,
      min_y: 0,
      max_x: 10,
      max_y: 10,
      inserted_at: DateTime.utc_now()
    }
  end

  defp province_file(election, leaders) do
    feed = %{election: election, name: "province-3", kind: :province, url: "x"}

    data = %{
      "ProvinceID" => 3,
      "Province" => "Gauteng",
      "MunicipalityResults" =>
        for {municipality_id, party_id} <- leaders do
          %{
            "MunicipalityID" => municipality_id,
            "Municipality" => "M#{municipality_id}",
            "VDsComplete" => 10,
            "VDExpected" => 10,
            "PartyBallotResults" => [
              %{
                "ID" => party_id,
                "TotalValidVotes" => 900,
                "PercOfVotes" => 60.0,
                "IOrder" => 1,
                "RegisteredVoters" => 2000,
                "TotalVotesCast" => 1020,
                "SpoiltVotes" => 20
              },
              %{"ID" => 99, "TotalValidVotes" => 100, "PercOfVotes" => 10.0, "IOrder" => 2}
            ]
          }
        end
    }

    {:ok, _snapshots} = Results.ingest(feed, data, "{}", %{})
  end

  setup do
    Repo.insert_all(Boundary, [boundary(3003, "Johannesburg"), boundary(3004, "Tshwane")])
    # Johannesburg changes hands (7 → 52); Tshwane does not.
    province_file(2021, [{3003, 7}, {3004, 7}])
    province_file(2026, [{3003, 52}, {3004, 7}])
    :ok
  end

  test "switching to changed-since mode greys out areas that did not change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/map")
    refute render(view) =~ ~r/id="areas-municipality-3004"[^>]*fill="var\(--color-base-200\)"/

    html = view |> element("a", "Changed since 2021") |> render_click()

    assert html =~ ~r/id="areas-municipality-3004"[^>]*fill="var\(--color-base-200\)"/
    refute html =~ ~r/id="areas-municipality-3003"[^>]*fill="var\(--color-base-200\)"/
    assert html =~ "Johannesburg: Party 52 60.0% · Party 7 before"
  end

  test "close contests mode shades each area by its lead over the runner-up", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/map")
    html = view |> element(~s(a[href*="mode=margin"])) |> render_click()

    # A 50-point lead falls in the faintest band.
    assert html =~
             ~r/id="areas-municipality-3003"[^>]*fill="var\(--color-primary\)"[^>]*fill-opacity="0.15"/

    assert html =~ "Johannesburg: Party 52 ahead of Party 99 by 50.0 pts · 800 votes"
    assert has_element?(view, "#map-bands", "20+ pts")
    assert html =~ "Lead over the runner-up"
  end

  test "spoilt ballots mode shows each area's share of spoilt ballots", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/map?mode=spoilt")
    html = render(view)

    assert html =~ ~r"Johannesburg: 2\.0% spoilt · 20 of 1.020 ballots"u
    assert html =~ ~r/id="areas-municipality-3003"[^>]*fill-opacity="0.5"/
  end

  test "wards offer no spoilt ballots mode, and fall back to the leader", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/map?level=wards&mode=spoilt")

    refute has_element?(view, "a", "Spoilt ballots")
    assert has_element?(view, "a", "Close contests")
    refute html =~ "Spoilt ballots, share of ballots cast"
  end
end
