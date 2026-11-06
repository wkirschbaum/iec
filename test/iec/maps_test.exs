defmodule Iec.MapsTest do
  use Iec.DataCase, async: true

  alias Iec.{Maps, Parties, Repo}
  alias Iec.Maps.{Boundary, Geometry}

  describe "Geometry.to_svg/2" do
    test "projects a polygon into a relative path with its bounding box" do
      square = %{
        "type" => "Polygon",
        "coordinates" => [
          [[28.0, -26.0], [28.1, -26.0], [28.1, -26.1], [28.0, -26.1], [28.0, -26.0]]
        ]
      }

      assert {"M" <> _ = path, {min_x, min_y, max_x, max_y}} = Geometry.to_svg(square, 1)
      assert path =~ "l" and String.ends_with?(path, "z")
      assert {max_x - min_x, max_y - min_y} == {88, 100}
    end

    test "drops rings that simplify to nothing" do
      speck = %{
        "type" => "Polygon",
        "coordinates" => [[[28.0, -26.0], [28.0001, -26.0], [28.0, -26.0001], [28.0, -26.0]]]
      }

      assert Geometry.to_svg(speck, 5) == nil
    end
  end

  describe "list_area_results/2 for wards" do
    defp party_file(election, party_id, wards) do
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
    end

    test "leads with the declared winner, else the biggest share, and knows who led before" do
      party_file(2021, 7, [{1, 60.0, true}, {2, 55.0, true}])
      party_file(2026, 7, [{1, 40.0, false}, {2, 45.0, false}])
      party_file(2026, 52, [{1, 35.0, true}, {2, 30.0, false}])

      results = Maps.list_area_results(:ward, [1, 2, 3])

      assert %{leader: 52, status: :complete, previous_leader: 7} = results[1]
      assert %{leader: 7, share: 45.0, status: :counting} = results[2]
      refute Map.has_key?(results, 3)
    end
  end

  test "view_box/1 frames every outline with a margin" do
    boundaries = [
      %Boundary{min_x: 0, min_y: 0, max_x: 100, max_y: 50},
      %Boundary{min_x: 50, min_y: 25, max_x: 200, max_y: 100}
    ]

    assert Maps.view_box(boundaries) == "-4 -4 208 108"
  end

  test "list_boundaries/2 filters by municipality" do
    now = DateTime.utc_now()

    rows =
      for {area_id, municipality_id} <- [{1, 3003}, {2, 3003}, {3, 3004}] do
        %{
          level: :ward,
          area_id: area_id,
          municipality_id: municipality_id,
          province_id: 3,
          name: "Ward #{area_id}",
          path: "M0 0l1 0 0 1z",
          min_x: 0,
          min_y: 0,
          max_x: 1,
          max_y: 1,
          inserted_at: now
        }
      end

    Repo.insert_all(Boundary, rows)

    assert [1, 2] == Maps.list_boundaries(:ward, municipality_id: 3003) |> Enum.map(& &1.area_id)
  end

  test "list_nearby_ward_ids/2 lists the wards around a ward, nearest first" do
    now = DateTime.utc_now()

    # Ward 1 is a 10-unit square; 2 touches it, 3 is a little further off, 4 is far away.
    rows =
      for {area_id, min_x} <- [{1, 0}, {2, 10}, {3, 11}, {4, 100}] do
        %{
          election: 2026,
          level: :ward,
          area_id: area_id,
          municipality_id: 3003,
          province_id: 3,
          name: "Ward #{area_id}",
          path: "M0 0l1 0 0 1z",
          min_x: min_x,
          min_y: 0,
          max_x: min_x + 10,
          max_y: 10,
          inserted_at: now
        }
      end

    Repo.insert_all(Boundary, rows)

    assert Maps.list_nearby_ward_ids(1) == [2, 3]
    assert Maps.list_nearby_ward_ids(1, 1) == [2]
    assert Maps.list_nearby_ward_ids(5) == []
  end
end
