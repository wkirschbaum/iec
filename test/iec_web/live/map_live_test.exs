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
              %{"ID" => party_id, "TotalValidVotes" => 900, "PercOfVotes" => 60.0, "IOrder" => 1},
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
end
