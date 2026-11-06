defmodule IecWeb.RacesLiveTest do
  use IecWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Iec.{Parties, Repo, Results}
  alias Iec.Results.Ward

  # A province file: `{municipality_id, [{party_id, votes}], districts_complete}`, of ten.
  defp ingest_province(election, municipalities) do
    feed = %{election: election, name: "province-3", kind: :province, url: "x"}

    data = %{
      "ProvinceID" => 3,
      "Province" => "Gauteng",
      "MunicipalityResults" =>
        for {municipality_id, votes, complete} <- municipalities do
          total = votes |> Enum.map(&elem(&1, 1)) |> Enum.sum()

          %{
            "MunicipalityID" => municipality_id,
            "Municipality" => "Council #{municipality_id}",
            "VDsComplete" => complete,
            "VDExpected" => 10,
            "MuncipalitiesComplete" => if(complete == 10, do: 1, else: 0),
            "PartyBallotResults" =>
              for {{party_id, party_votes}, position} <- Enum.with_index(votes, 1) do
                %{
                  "ID" => party_id,
                  "TotalValidVotes" => party_votes,
                  "PercOfVotes" => party_votes / total * 100,
                  "IOrder" => position
                }
              end
          }
        end
    }

    {:ok, snapshots} = Results.ingest(feed, data, "{}", %{})
    Results.broadcast({:results_changed, Enum.map(snapshots, & &1.id)})
  end

  # One party's share of each ward: `{ward_id, share, won}`.
  defp ingest_party_wards(party_id, wards) do
    feed = %{
      election: 2026,
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

  # Refreshes are scheduled from the page process, so give it a moment.
  defp eventually_render(view, expected, attempts \\ 50) do
    html = render(view)

    cond do
      html =~ expected -> html
      attempts == 0 -> flunk("#{inspect(expected)} never appeared in:\n#{html}")
      true -> Process.sleep(20) && eventually_render(view, expected, attempts - 1)
    end
  end

  defp council_order(html) do
    Regex.scan(~r/id="council-races-(\d+)"/, html, capture: :all_but_first) |> List.flatten()
  end

  test "lists the closest councils first and follows the count", %{conn: conn} do
    ingest_province(2021, [{3003, [{7, 800}, {52, 200}], 10}])
    ingest_province(2026, [{3003, [{7, 600}, {52, 400}], 10}, {3004, [{52, 510}, {7, 490}], 5}])

    {:ok, view, html} = live(conn, ~p"/races")
    assert council_order(html) == ["3004", "3003"]
    assert html =~ "The tightest council race is in Council 3004, where Party 52 leads Party 7"
    assert html =~ "by 2.00 points, 20 votes."
    # Only councils with a tenth of their count in make the knife-edge cards.
    assert has_element?(view, "#knife-edge-3004")
    # The lead in 2021 and how much it narrowed.
    assert has_element?(view, "#council-races-3003", "60.00 pts")
    assert has_element?(view, "#council-races-3003", "−40.00")

    # 3003 tightens to a 2-vote race.
    ingest_province(2026, [{3003, [{7, 501}, {52, 499}], 10}, {3004, [{52, 510}, {7, 490}], 5}])
    html = eventually_render(view, "Council 3003, where Party 7 beat Party 52 by 0.20 points")
    assert council_order(html) == ["3003", "3004"]
  end

  test "council and ward tables sort by any column", %{conn: conn} do
    ingest_province(2026, [{3003, [{7, 600}, {52, 400}], 10}, {3004, [{52, 510}, {7, 490}], 5}])
    {:ok, view, _html} = live(conn, ~p"/races")

    header = element(view, ~s(#council-races button[phx-value-column="counted"]))
    assert council_order(render_click(header)) == ["3003", "3004"]
    assert council_order(render_click(header)) == ["3004", "3003"]
  end

  test "lists close wards, a page at a time", %{conn: conn} do
    ward_ids = Enum.to_list(79_800_001..79_800_030)

    Repo.insert_all(
      Ward,
      for ward_id <- ward_ids do
        %{
          id: ward_id,
          municipality_id: 3003,
          ward_number: Ward.ward_number(ward_id),
          inserted_at: DateTime.utc_now()
        }
      end
    )

    ingest_province(2026, [{3003, [{7, 600}, {52, 400}], 10}])
    # Ward n: party 7 on 50 + n, party 52 on 50 − n, so ward 1 is the closest.
    ingest_party_wards(7, for(ward_id <- ward_ids, do: {ward_id, 50.0 + rem(ward_id, 100), true}))

    ingest_party_wards(
      52,
      for(ward_id <- ward_ids, do: {ward_id, 50.0 - rem(ward_id, 100), false})
    )

    {:ok, view, html} = live(conn, ~p"/races")
    rows = Regex.scan(~r/id="ward-races-(\d+)"/, html, capture: :all_but_first)
    assert length(rows) == 25
    assert List.first(rows) == ["79800001"]
    assert has_element?(view, "#ward-races-79800001", "Council 3003 · ward 1")
    assert has_element?(view, "#ward-races-79800001", "2.00 pts")

    html =
      view
      |> element(~s(button[phx-click="show_more"][phx-value-table="ward-races"]))
      |> render_click()

    assert length(Regex.scan(~r/id="ward-races-\d+"/, html)) == 30
  end

  test "says so before there are results", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/races")
    assert html =~ "No council results yet."
    assert html =~ "No ward results yet."
  end
end
