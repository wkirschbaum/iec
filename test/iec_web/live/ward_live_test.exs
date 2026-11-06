defmodule IecWeb.WardLiveTest do
  use IecWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Iec.{Parties, Repo, Results}
  alias Iec.Maps.Boundary
  alias Iec.Results.Ward

  @ward_id 79_800_001
  @neighbour_id 79_800_002

  # A province file naming council 3003, with its count complete.
  defp ingest_province(election) do
    feed = %{election: election, name: "province-3", kind: :province, url: "x"}

    data = %{
      "ProvinceID" => 3,
      "Province" => "Gauteng",
      "MunicipalityResults" => [
        %{
          "MunicipalityID" => 3003,
          "Municipality" => "Council 3003",
          "VDsComplete" => 10,
          "VDExpected" => 10,
          "MuncipalitiesComplete" => 1,
          "PartyBallotResults" => [
            %{"ID" => 7, "TotalValidVotes" => 600, "PercOfVotes" => 60.0, "IOrder" => 1},
            %{"ID" => 52, "TotalValidVotes" => 400, "PercOfVotes" => 40.0, "IOrder" => 2}
          ]
        }
      ]
    }

    {:ok, snapshots} = Results.ingest(feed, data, "{}", %{})
    Results.broadcast({:results_changed, Enum.map(snapshots, & &1.id)})
  end

  # One party's share of each ward: `{ward_id, share, won}`.
  defp ingest_party_wards(election, party_id, wards) do
    feed = %{
      election: election,
      name: "party-#{party_id}",
      kind: :party,
      party_id: party_id,
      url: "x"
    }

    data = %{
      "ProvinceResults" => [
        %{
          "ProvinceID" => 3,
          "MunicipalityResults" => [
            %{
              "MunicipalityID" => 3003,
              "PartyBallotResults" => [%{"PercOfVotes" => 40.0, "TotalSeatsWon" => 5}],
              "WardResults" =>
                for {ward_id, share, won} <- wards do
                  %{
                    "WardID" => ward_id,
                    "PartyBallotResults" => [
                      %{"PercOfVotes" => share, "TotalSeatsWon" => if(won, do: 1, else: 0)}
                    ]
                  }
                end
            }
          ]
        }
      ]
    }

    {:ok, _count} = Parties.ingest(feed, data, "{}", %{})
    Parties.broadcast_changed(party_id)
  end

  defp insert_wards do
    now = DateTime.utc_now()

    Repo.insert_all(
      Ward,
      for ward_id <- [@ward_id, @neighbour_id] do
        %{
          id: ward_id,
          municipality_id: 3003,
          ward_number: Ward.ward_number(ward_id),
          inserted_at: now
        }
      end
    )

    # Two squares side by side.
    Repo.insert_all(
      Boundary,
      for {ward_id, min_x} <- [{@ward_id, 0}, {@neighbour_id, 10}] do
        %{
          election: 2026,
          level: :ward,
          area_id: ward_id,
          municipality_id: 3003,
          province_id: 3,
          name: "Council 3003 · ward #{Ward.ward_number(ward_id)}",
          path: "M#{min_x} 0l10 0 0 10z",
          min_x: min_x,
          min_y: 0,
          max_x: min_x + 10,
          max_y: 10,
          inserted_at: now
        }
      end
    )
  end

  # Refreshes are scheduled from the page process, so give it a moment.
  defp eventually_render(view, expected, attempts \\ 50) do
    html = render(view)

    cond do
      html =~ expected -> html
      attempts == 0 -> flunk("#{inspect(expected)} never appeared in:\n#{html}")
      true -> Process.sleep(20) && eventually_render(view, expected, attempts - 1)
    end
  end

  setup do
    insert_wards()
    ingest_province(2021)
    ingest_province(2026)
    ingest_party_wards(2021, 7, [{@ward_id, 60.0, true}, {@neighbour_id, 70.0, true}])
    ingest_party_wards(2021, 52, [{@ward_id, 30.0, false}, {@neighbour_id, 20.0, false}])
    :ok
  end

  describe "the ward page" do
    test "says who won, by how much, and against the previous election", %{conn: conn} do
      ingest_party_wards(2026, 7, [{@ward_id, 40.0, false}, {@neighbour_id, 55.0, true}])
      ingest_party_wards(2026, 52, [{@ward_id, 45.0, true}, {@neighbour_id, 35.0, false}])

      {:ok, view, html} = live(conn, ~p"/wards/#{@ward_id}")

      assert html =~ "Party 52 wins ward 1 with 45.0%."
      assert html =~ "Party 7 is second with 40.0%, 5.0 points behind."
      assert html =~ "It takes the ward from Party 7, which won it in 2021."
      assert has_element?(view, "a[href='/municipalities/3003']", "Council 3003")

      assert has_element?(view, "#ward-parties-52", "won")
      assert has_element?(view, "#ward-parties-52", "+15.00")
      assert has_element?(view, "#ward-parties-7", "−20.00")

      # The lead now and in 2021.
      assert html =~ "5.00 pts"
      assert html =~ "30.00 pts in 2021"

      # The ward against the previous election, and each party's council share.
      assert has_element?(view, "#ward-trend")
      assert has_element?(view, "#ward-parties-52", "40.00%")

      # The ward next door, and the map around both.
      assert has_element?(view, "#nearby-wards-#{@neighbour_id}", "Ward 2")
      assert has_element?(view, "#ward-map")
    end

    test "follows the count", %{conn: conn} do
      ingest_party_wards(2026, 7, [{@ward_id, 20.0, false}])
      ingest_party_wards(2026, 52, [{@ward_id, 30.0, false}])

      {:ok, view, html} = live(conn, ~p"/wards/#{@ward_id}")
      assert html =~ "Party 52 leads ward 1 with 30.0%."
      assert html =~ "Party 7 won it in 2021."

      ingest_party_wards(2026, 7, [{@ward_id, 62.0, true}])
      html = eventually_render(view, "Party 7 wins ward 1 with 62.0%.")
      assert html =~ "Party 7 also won it in 2021, with 60.0%."
    end

    test "shows the biggest parties first, more on request", %{conn: conn} do
      for party_id <- 101..112,
          do: ingest_party_wards(2026, party_id, [{@ward_id, party_id / 10, false}])

      {:ok, view, html} = live(conn, ~p"/wards/#{@ward_id}")
      assert length(Regex.scan(~r/id="ward-parties-\d+"/, html)) == 10
      assert has_element?(view, "#ward-parties-112")
      refute has_element?(view, "#ward-parties-101")

      html =
        view
        |> element(~s(button[phx-click="show_more"][phx-value-table="ward-parties"]))
        |> render_click()

      assert length(Regex.scan(~r/id="ward-parties-\d+"/, html)) == 12
    end

    test "names the ward after the places in it, on the page and its map", %{conn: conn} do
      Repo.insert_all(Iec.Places.Place, [
        %{
          osm_type: "node",
          osm_id: 1,
          name: "Meadowridge",
          kind: "suburb",
          latitude: -34.03,
          longitude: 18.45,
          ward_id: @ward_id,
          municipality_id: 3003,
          inserted_at: DateTime.utc_now()
        }
      ])

      {:ok, view, html} = live(conn, ~p"/wards/#{@ward_id}")
      assert html =~ "Ward 1 · Meadowridge"
      assert html =~ "Takes in Meadowridge."
      # The neighbour on the map is named in its tooltip, and numbered on the map.
      assert render(view) =~ "Ward 1 · Meadowridge — Council 3003"
      assert has_element?(view, "#ward-map-labels text", "2")
    end

    test "says so before the ward has results", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/wards/#{@ward_id}")
      assert html =~ "No party has votes in this ward yet."
    end

    test "says so for a ward that does not exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/wards/123")
      assert html =~ "There is no such ward"

      {:ok, _view, html} = live(conn, ~p"/wards/not-a-ward")
      assert html =~ "There is no such ward"
    end
  end

  describe "the municipality dashboard" do
    test "links every ward, and shows who won and lost wards", %{conn: conn} do
      ingest_party_wards(2026, 7, [{@ward_id, 40.0, false}, {@neighbour_id, 55.0, true}])
      ingest_party_wards(2026, 52, [{@ward_id, 45.0, true}, {@neighbour_id, 35.0, false}])

      {:ok, view, _html} = live(conn, ~p"/municipalities/3003")

      assert has_element?(view, "#ward-chip-#{@ward_id}[href='/wards/#{@ward_id}']")
      assert has_element?(view, "#ward-chip-#{@neighbour_id}")
      # Ward 1 went from party 7 to party 52.
      assert has_element?(view, "#flipped-ward-#{@ward_id} a[href='/wards/#{@ward_id}']")
      refute has_element?(view, "#flipped-ward-#{@neighbour_id}")
      assert has_element?(view, "#ward-tally-52", "+1")
      assert has_element?(view, "#ward-tally-7", "−1")
      assert has_element?(view, "#closest-ward-#{@ward_id}", "5.00 pts")
      assert has_element?(view, "#municipality-ballots")
    end

    test "says so for a municipality that does not exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/municipalities/not-one")
      assert html =~ "No results for this municipality yet, or no municipality has this id."
    end
  end

  describe "finding a ward" do
    test "by municipality and number", %{conn: conn} do
      ingest_party_wards(2026, 52, [{@ward_id, 45.0, true}])
      {:ok, view, _html} = live(conn, ~p"/wards")

      view |> form("#ward-search", q: "council ward 1") |> render_change()
      assert_patch(view, ~p"/wards?#{[q: "council ward 1"]}")

      assert has_element?(view, "#ward-results-#{@ward_id}", "Party 52")
      refute has_element?(view, "#ward-results-#{@neighbour_id}")
      assert has_element?(view, "#ward-results a[href='/wards/#{@ward_id}']")
    end

    test "by municipality, listing its wards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/wards?q=Council")

      assert has_element?(view, "#ward-search-municipality-3003")
      assert has_element?(view, "#ward-chip-#{@ward_id}[href='/wards/#{@ward_id}']")
      assert has_element?(view, "#ward-chip-#{@neighbour_id}")
    end

    test "says what to try when nothing matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/wards?q=Soweto")
      assert has_element?(view, "#ward-search-empty", "Try your suburb or town")
    end
  end
end
