defmodule IecWeb.LiveUpdatesTest do
  use IecWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Iec.{Parties, Results}

  defp party(id, votes, seats) do
    %{
      "ID" => id,
      "Name" => "PARTY #{id}",
      "TotalValidVotes" => votes,
      "PercOfVotes" => votes / 10,
      "TotalSeatsWon" => seats,
      "IOrder" => id,
      "RegisteredVoters" => 2000,
      "TotalVotesCast" => 1010
    }
  end

  defp ingest_national(anc_votes, voting_districts_complete \\ 5) do
    feed = %{election: 2026, name: "national", kind: :national, url: "https://results.example"}

    data = %{
      "ReportDate" => "2026-11-06T07:00:00+02:00",
      "VDsComplete" => voting_districts_complete,
      "VDExpected" => 10,
      "PartyBallotResults" => [party(7, anc_votes, 3), party(52, 400, 2)]
    }

    {:ok, snapshots} = Results.ingest(feed, data, "{}", %{})
    Results.broadcast({:results_changed, Enum.map(snapshots, & &1.id)})
  end

  defp ingest_party_file(election, party_id, wards) do
    feed = %{
      election: election,
      name: "party-#{party_id}",
      kind: :party,
      party_id: party_id,
      url: "https://results.example"
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
                for {ward_id, won} <- wards do
                  %{
                    "WardID" => ward_id,
                    "PartyBallotResults" => [
                      %{"PercOfVotes" => 50.0, "TotalSeatsWon" => if(won, do: 1, else: 0)}
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

  test "the national page shows new results as they arrive", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "No results yet"

    ingest_national(500)
    assert eventually_render(view, "50.0%") =~ ~s(id="national-parties")

    ingest_national(650)
    assert eventually_render(view, "650")
  end

  test "every page's footer follows the count", %{conn: conn} do
    paths = [~p"/changes", ~p"/parties/7", ~p"/provinces/3", ~p"/municipalities/3003"]

    for {path, districts} <- Enum.zip(paths, 1..4) do
      {:ok, view, _html} = live(conn, path)
      ingest_national(500 + districts, districts)
      assert eventually_render(view, ~r/#{districts * 10}\.0%\s*<\/span>/)
    end
  end

  test "party page lists show 25 rows until asked, and sections collapse", %{conn: conn} do
    wards = for ward_id <- 79_800_001..79_800_030, do: ward_id
    ingest_party_file(2021, 7, Enum.map(wards, &{&1, true}))
    ingest_party_file(2026, 7, Enum.map(wards, &{&1, false}))
    ingest_party_file(2026, 52, Enum.map(wards, &{&1, true}))

    {:ok, view, html} = live(conn, ~p"/parties/7")
    assert length(Regex.scan(~r/id="wards-lost-\d+"/, html)) == 25
    assert html =~ "Show all 30"

    html = view |> element("#wards-lost button[phx-click=show_all]") |> render_click()
    assert length(Regex.scan(~r/id="wards-lost-\d+"/, html)) == 30

    html = view |> element("#wards-lost button[phx-click=toggle_section]") |> render_click()
    assert Regex.scan(~r/id="wards-lost-\d+"/, html) == []
  end

  test "winners and losers follow the count", %{conn: conn} do
    ingest_party_file(2021, 7, [{79_800_001, true}])
    {:ok, view, _html} = live(conn, ~p"/movers")

    ingest_national(500)
    ingest_party_file(2026, 7, [{79_800_001, false}])
    ingest_party_file(2026, 52, [{79_800_001, true}])

    html = eventually_render(view, ~s(id="ward-net-52"))
    assert html =~ ~s(id="ward-net-7")
    assert html =~ ~s(id="winners-7")
  end

  test "the map recolours a ward when its result comes in", %{conn: conn} do
    Iec.Repo.insert_all(Iec.Maps.Boundary, [
      %{
        level: :ward,
        area_id: 79_800_001,
        municipality_id: 3003,
        province_id: 3,
        name: "JHB · ward 1",
        path: "M0 0l10 0 0 10z",
        min_x: 0,
        min_y: 0,
        max_x: 10,
        max_y: 10,
        inserted_at: DateTime.utc_now()
      }
    ])

    {:ok, view, html} = live(conn, ~p"/map?level=wards")
    assert html =~ "JHB · ward 1: no results yet"

    ingest_party_file(2026, 52, [{79_800_001, true}])
    assert eventually_render(view, "JHB · ward 1: Party 52 50.0%")
  end

  test "clicking a column heading sorts the table, again reverses it", %{conn: conn} do
    ingest_national(500)
    {:ok, view, _html} = live(conn, ~p"/")

    order = fn html ->
      Regex.scan(~r/id="national-parties-party-(\d+)"/, html, capture: :all_but_first)
      |> List.flatten()
    end

    header = element(view, ~s(#national-parties button[phx-value-column="votes"]))
    assert order.(render_click(header)) == ["7", "52"]
    assert order.(render_click(header)) == ["52", "7"]
  end

  test "the footer shows each poll as it happens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/changes")

    Results.broadcast_feed_status(%{
      feed: "national",
      checked_at: ~U[2026-11-06 06:30:00Z],
      result: :not_modified,
      next_poll_at: nil
    })

    assert eventually_render(view, "checked 08:30:00")
  end

  test "the party page follows party files, including other parties'", %{conn: conn} do
    ingest_party_file(2021, 7, [{79_800_001, true}])
    {:ok, view, _html} = live(conn, ~p"/parties/7")

    ingest_party_file(2026, 7, [{79_800_001, false}])
    ingest_party_file(2026, 52, [{79_800_001, true}])

    html = eventually_render(view, ~s(id="wards-lost-79800001"))
    assert html =~ ~s(href="/parties/52")
  end
end
