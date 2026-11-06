defmodule Iec.FollowingTest do
  use Iec.DataCase, async: false

  alias Iec.{Maps, Parties, Repo, Results}
  alias Iec.Parties.Import
  alias Iec.Results.{Feed, PartyWardResult, Ward}

  # A square around (longitude, latitude), `size` degrees wide.
  defp square(longitude, latitude, size) do
    %{
      "type" => "Polygon",
      "coordinates" => [
        [
          [longitude, latitude],
          [longitude + size, latitude],
          [longitude + size, latitude - size],
          [longitude, latitude - size],
          [longitude, latitude]
        ]
      ]
    }
  end

  defp ward_feature(ward_id, geometry) do
    %{
      "properties" => %{
        "PklWardID" => ward_id,
        "ProvinceId" => 3,
        "MunicId" => 3003,
        "Municipali" => "JHB",
        "WardNo" => rem(ward_id, 1000)
      },
      "geometry" => geometry
    }
  end

  defp municipality_file(wards) do
    %{
      "WardResults" =>
        for {ward_id, parties} <- wards do
          %{
            "WardID" => ward_id,
            "PartyBallotResults" =>
              for {party_id, votes} <- parties do
                %{"ID" => party_id, "TotalValidVotes" => votes, "PercOfVotes" => votes / 10}
              end
          }
        end
    }
  end

  # Serves each IEC file this test needs, by the end of its URL.
  defp stub_iec(files) do
    Req.Test.stub(Feed, fn conn ->
      case Enum.find(files, fn {suffix, _body} -> String.ends_with?(conn.request_path, suffix) end) do
        {_suffix, body} -> Req.Test.json(conn, body)
        nil -> Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end

  setup do
    # One live municipality, so the municipality files have something to read.
    feed = %{election: 2026, name: "province-3", kind: :province, url: "x"}

    {:ok, _} =
      Results.ingest(
        feed,
        %{
          "ProvinceID" => 3,
          "Province" => "Gauteng",
          "MunicipalityResults" => [%{"MunicipalityID" => 3003, "Municipality" => "JHB"}]
        },
        "{}",
        %{}
      )

    :ok
  end

  test "municipality files map wards and follow every party standing" do
    stub_iec([
      {"2026/EEID1887Munic3003.js",
       municipality_file([{79_800_001, [{7, 10}, {52, 20}, {1234, 5}]}])}
    ])

    Import.import_municipality_files()

    assert Repo.get!(Ward, 79_800_001).municipality_id == 3003
    assert Enum.sort(Import.list_followed_party_ids()) == [7, 52, 1234]

    # Read once: a second pass asks nothing (the stub would now fail every request).
    stub_iec([])
    Import.import_municipality_files()
  end

  test "previous-election municipality files give every ward's winner, whichever party" do
    stub_iec([
      {"2021/EEID1091Munic3003.js",
       municipality_file([{79_800_001, [{7, 30}, {999, 70}]}, {79_800_002, [{7, 60}, {52, 40}]}])}
    ])

    Import.import_previous_ward_results()

    winners =
      Repo.all(
        from result in PartyWardResult,
          where: result.won,
          select: {result.ward_id, result.party_id}
      )

    assert Enum.sort(winners) == [{79_800_001, 999}, {79_800_002, 7}]
  end

  test "wards whose outline changed since the previous election count as redrawn" do
    stub_iec([
      {"2026/nationalProvince.js", %{"features" => []}},
      {"2026/nationalMunic.js", %{"features" => []}},
      {"2026/nationalWard.js",
       %{
         "features" => [
           ward_feature(79_800_001, square(28.0, -26.0, 0.1)),
           ward_feature(79_800_002, square(28.5, -26.0, 0.1))
         ]
       }},
      {"2021/nationalWard.js",
       %{
         "features" => [
           ward_feature(79_800_001, square(28.0, -26.0, 0.1)),
           # Ward 2 was half the size in 2021.
           ward_feature(79_800_002, square(28.5, -26.0, 0.07))
         ]
       }}
    ])

    Maps.import_boundaries()

    assert Maps.list_redrawn_ward_ids() == MapSet.new([79_800_002])
  end

  test "a redrawn ward is neither gained nor lost, only won" do
    Repo.insert_all(Iec.Maps.Boundary, [
      %{
        election: 2026,
        level: :ward,
        area_id: 79_800_001,
        municipality_id: 3003,
        province_id: 3,
        name: "JHB · ward 1",
        path: "M0 0l1 0 0 1z",
        min_x: 0,
        min_y: 0,
        max_x: 1,
        max_y: 1,
        redrawn: true,
        inserted_at: DateTime.utc_now()
      }
    ])

    party_file = fn election, party_id, won ->
      data = %{
        "ProvinceResults" => [
          %{
            "ProvinceID" => 3,
            "MunicipalityResults" => [
              %{
                "MunicipalityID" => 3003,
                "WardResults" => [
                  %{
                    "WardID" => 79_800_001,
                    "PartyBallotResults" => [
                      %{"PercOfVotes" => 50.0, "TotalSeatsWon" => if(won, do: 1, else: 0)}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      }

      feed = %{
        election: election,
        name: "party-#{party_id}",
        kind: :party,
        party_id: party_id,
        url: "x"
      }

      {:ok, _} = Parties.ingest(feed, data, "{}", %{})
    end

    party_file.(2021, 7, true)
    party_file.(2026, 7, false)
    party_file.(2026, 52, true)

    assert [%{status: :none, new_ward: true, redrawn: true}] =
             Parties.get_party_overview(7).wards

    assert [%{status: :won_new, previous_holder: nil}] = Parties.get_party_overview(52).wards
  end
end
