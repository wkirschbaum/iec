defmodule Iec.PlacesTest do
  use Iec.DataCase, async: false

  alias Iec.{Places, Repo, Wards}
  alias Iec.Maps.{Boundary, Geometry}
  alias Iec.Places.{Overpass, Place}

  # A square ward around Meadowridge, Cape Town (18.45 E, 34.03 S), about 2 km across.
  @square %{
    "type" => "Polygon",
    "coordinates" => [
      [[18.44, -34.04], [18.46, -34.04], [18.46, -34.02], [18.44, -34.02], [18.44, -34.04]]
    ]
  }

  defp insert_ward do
    {path, {min_x, min_y, max_x, max_y}} = Geometry.to_svg(@square, 1)

    Repo.insert_all(Boundary, [
      %{
        election: 2026,
        level: :ward,
        area_id: 19_100_073,
        municipality_id: 1910,
        province_id: 9,
        name: "CPT - City of Cape Town · ward 73",
        path: path,
        min_x: min_x,
        min_y: min_y,
        max_x: max_x,
        max_y: max_y,
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  @elements [
    %{
      "type" => "node",
      "id" => 1,
      "lat" => -34.0328,
      "lon" => 18.4529,
      "tags" => %{"name" => "Meadowridge", "place" => "suburb", "alt_name" => "Meadow Ridge"}
    },
    # A suburb mapped as an area counts at its centre.
    %{
      "type" => "way",
      "id" => 2,
      "center" => %{"lat" => -34.025, "lon" => 18.445},
      "tags" => %{"name" => "Bergvliet", "place" => "suburb", "population" => "9 000"}
    },
    # Outside every ward: stored, but in no ward.
    %{
      "type" => "node",
      "id" => 3,
      "lat" => -26.2,
      "lon" => 28.0,
      "tags" => %{"name" => "Johannesburg", "place" => "city"}
    }
  ]

  # Answers like Overpass: a free slot on the status page, and the elements to a query.
  defp stub_overpass(interpreter_responses) do
    {:ok, responses} = Agent.start_link(fn -> interpreter_responses end)

    Req.Test.stub(Overpass, fn conn ->
      case conn.request_path do
        "/api/status" ->
          Plug.Conn.send_resp(conn, 200, "Rate limit: 2\n2 slots available now.\n")

        "/api/interpreter" ->
          case Agent.get_and_update(responses, fn [next | rest] -> {next, rest ++ [next]} end) do
            {:busy, status} -> Plug.Conn.send_resp(conn, status, "busy")
            elements -> Req.Test.json(conn, %{"elements" => elements})
          end
      end
    end)
  end

  describe "Overpass.seconds_until_slot/1" do
    test "is zero with a free slot or no limit, else the shortest wait" do
      assert Overpass.seconds_until_slot("Rate limit: 2\n1 slots available now.") == 0
      assert Overpass.seconds_until_slot("Rate limit: 0\n") == 0

      status = """
      Rate limit: 2
      Slot available after: 2026-11-06T12:00:30Z, in 42 seconds.
      Slot available after: 2026-11-06T12:00:10Z, in 7 seconds.
      """

      assert Overpass.seconds_until_slot(status) == 7
    end
  end

  describe "Geometry.rings/1 and contains?/2" do
    test "read a path back and tell inside from outside" do
      {path, _box} = Geometry.to_svg(@square, 1)
      rings = Geometry.rings(path)

      assert Geometry.contains?(rings, Geometry.project_point(18.45, -34.03))
      refute Geometry.contains?(rings, Geometry.project_point(18.47, -34.03))
    end
  end

  describe "import_places/0" do
    test "waits for the ward outlines" do
      assert Places.import_places() == {:error, :no_ward_outlines}
    end

    test "stores every place, in the ward that holds it" do
      insert_ward()
      # Four tiles: the places come back in the first, the others are empty.
      stub_overpass([@elements, [], [], []])

      assert {:ok, 3} = Places.import_places()

      places = Repo.all(Place) |> Map.new(&{&1.name, &1})
      assert places["Meadowridge"].ward_id == 19_100_073
      assert places["Meadowridge"].alternate_names == ["Meadow Ridge"]
      assert places["Bergvliet"].ward_id == 19_100_073
      assert places["Bergvliet"].population == 9000
      assert places["Johannesburg"].ward_id == nil

      assert Places.list_ward_places(19_100_073) == ["Bergvliet", "Meadowridge"]

      # Stored once: a second import asks nothing.
      Req.Test.stub(Overpass, fn _conn -> flunk("asked Overpass again") end)
      assert Places.import_places() == {:ok, 0}
    end

    test "backs off and tries again when Overpass is busy" do
      insert_ward()
      stub_overpass([{:busy, 504}, @elements, [], [], []])

      assert {:ok, 3} = Places.import_places()
    end

    test "gives up, storing nothing, when Overpass stays busy" do
      insert_ward()
      stub_overpass([{:busy, 429}])

      assert {:error, {_tile, {:busy, 429}}} = Places.import_places()
      assert Repo.aggregate(Place, :count) == 0
    end
  end

  describe "searching by place" do
    test "finds a ward by a suburb in it, misspelt or by another name" do
      directory = [
        %{
          ward_id: 19_100_073,
          ward_number: 73,
          municipality_id: 1910,
          municipality_name: "CPT - City of Cape Town",
          province_id: 9,
          province_name: "Western Cape"
        }
      ]

      places = [
        %{
          name: "Meadowridge",
          alternate_names: ["Meadow Ridge"],
          kind: "suburb",
          population: nil,
          ward_id: 19_100_073,
          municipality_id: 1910
        }
      ]

      index = Wards.build_index(directory, places)

      for query <- ["meadowridge", "medowridge", "meadow ridge", "Meadowr"] do
        assert [%{place_name: "Meadowridge", ward_id: 19_100_073}] =
                 Wards.search(query, index).places,
               "#{query} found nothing"
      end

      assert Wards.search("bergvliet", index).places == []
    end
  end
end
