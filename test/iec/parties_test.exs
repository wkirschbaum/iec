defmodule Iec.PartiesTest do
  use Iec.DataCase, async: true

  alias Iec.{Parties, Repo, Results}
  alias Iec.Results.{PartyWardResult, Ward}

  defp party_feed(election, party_id) do
    %{
      election: election,
      name: "party-#{party_id}",
      kind: :party,
      party_id: party_id,
      url: "https://results.example/party#{party_id}.js"
    }
  end

  # The IEC nests every ward under the province's first municipality; mirror that.
  defp party_file(municipalities, wards) do
    %{
      "ReportDate" => "2026-11-06T07:00:00+02:00",
      "ProvinceResults" => [
        %{
          "ProvinceID" => 3,
          "MunicipalityResults" =>
            for {{municipality_id, share, majority}, index} <- Enum.with_index(municipalities) do
              %{
                "MunicipalityID" => municipality_id,
                "PartyBallotResults" => [
                  %{
                    "PercOfVotes" => share,
                    "TotalSeatsWon" => 10,
                    "MajorityWon" => if(majority, do: 1, else: 0),
                    "IsCouncilWinner" => majority
                  }
                ],
                "WardResults" =>
                  if index == 0 do
                    for {ward_id, share, won} <- wards do
                      %{
                        "WardID" => ward_id,
                        "PartyBallotResults" => [
                          %{"PercOfVotes" => share, "TotalSeatsWon" => if(won, do: 1, else: 0)}
                        ]
                      }
                    end
                  else
                    []
                  end
              }
            end
        }
      ]
    }
  end

  defp ingest(election, party_id, data) do
    {:ok, count} =
      Parties.ingest(party_feed(election, party_id), data, Jason.encode!(data), %{etag: nil})

    count
  end

  defp municipality_snapshot(municipality_id, name, complete) do
    feed = %{election: 2026, name: "province-3", kind: :province, url: "https://results.example"}

    data = %{
      "ProvinceID" => 3,
      "Province" => "Gauteng",
      "MunicipalityResults" => [
        %{
          "MunicipalityID" => municipality_id,
          "Municipality" => name,
          "MuncipalitiesComplete" => if(complete, do: 1, else: 0)
        }
      ]
    }

    {:ok, _} = Results.ingest(feed, data, "{}", %{})
  end

  describe "ingest/4" do
    test "counts only rows whose figures changed and records when a ward was first won" do
      data =
        party_file([{3003, 40.0, false}], [{79_800_001, 55.0, true}, {79_800_002, 20.0, false}])

      assert ingest(2026, 52, data) == 3
      assert ingest(2026, 52, data) == 0

      won = Repo.get_by!(PartyWardResult, ward_id: 79_800_001)
      assert won.won and won.first_won_at

      data =
        party_file([{3003, 40.0, false}], [{79_800_001, 56.0, true}, {79_800_002, 20.0, false}])

      assert ingest(2026, 52, data) == 1
      assert Repo.get_by!(PartyWardResult, ward_id: 79_800_001).first_won_at == won.first_won_at
    end
  end

  describe "get_party_overview/1" do
    setup do
      municipality_snapshot(3003, "JHB - City of Johannesburg", true)
      municipality_snapshot(3004, "TSH - City of Tshwane", false)

      # Wards 1 to 3 are in the live directory; ward 4 was abolished.
      Repo.insert_all(
        Ward,
        for ward_id <- 79_800_001..79_800_003 do
          %{
            id: ward_id,
            municipality_id: 3003,
            ward_number: Ward.ward_number(ward_id),
            inserted_at: DateTime.utc_now()
          }
        end
      )

      # 2021: party 7 held Johannesburg and Tshwane and wards 1, 2 and 4; party 52 held
      # ward 3.
      ingest(
        2021,
        7,
        party_file([{3003, 51.0, true}, {3004, 52.0, true}], [
          {79_800_001, 60.0, true},
          {79_800_002, 58.0, true},
          {79_800_003, 30.0, false},
          {79_800_004, 70.0, true}
        ])
      )

      ingest(2021, 52, party_file([{3003, 30.0, false}], [{79_800_003, 61.0, true}]))

      # 2026: party 7 lost Johannesburg (complete) and ward 1 to party 52, gained ward 3,
      # and ward 2 is not declared yet.
      ingest(
        2026,
        7,
        party_file([{3003, 40.0, false}, {3004, 45.0, false}], [
          {79_800_001, 35.0, false},
          {79_800_002, 50.0, false},
          {79_800_003, 52.0, true}
        ])
      )

      ingest(2026, 52, party_file([{3003, 45.0, false}], [{79_800_001, 58.0, true}]))
      :ok
    end

    test "classifies councils as lost when complete and pending while counting" do
      overview = Parties.get_party_overview(7)
      by_id = Map.new(overview.municipalities, &{&1.municipality_id, &1})

      assert %{status: :lost_hung, name: "JHB - City of Johannesburg", swing: -11.0} =
               by_id[3003]

      assert %{status: :pending} = by_id[3004]
      assert by_id[3003].previous_control.majority == 7
      assert %{majority: nil, largest: largest} = by_id[3003].control
      assert largest in [7, 52]
    end

    test "classifies wards with who held them before and who took them" do
      overview = Parties.get_party_overview(7)
      by_id = Map.new(overview.wards, &{&1.ward_id, &1})

      assert %{status: :lost, holder: 52, municipality_name: "JHB - City of Johannesburg"} =
               by_id[79_800_001]

      assert %{status: :pending, holder: nil} = by_id[79_800_002]
      assert %{status: :gained, previous_holder: 52, new_ward: false} = by_id[79_800_003]
      assert by_id[79_800_001].declared_at
    end

    test "an abolished ward is neither pending nor lost" do
      by_id = Map.new(Parties.get_party_overview(7).wards, &{&1.ward_id, &1})

      assert %{status: :none, abolished: true, new_ward: false} = by_id[79_800_004]
      refute by_id[79_800_002].abolished
    end
  end

  describe "get_municipality_overview/1 and get_ward_overview/1" do
    setup do
      # Ward 1 changed hands; ward 2 was redrawn and changed hands; ward 3 is new.
      Repo.insert_all(
        Ward,
        for ward_id <- 79_800_001..79_800_003 do
          %{
            id: ward_id,
            municipality_id: 3003,
            ward_number: Ward.ward_number(ward_id),
            inserted_at: DateTime.utc_now()
          }
        end
      )

      insert_redrawn_ward(79_800_002)

      ingest(
        2021,
        7,
        party_file([{3003, 51.0, true}], [{79_800_001, 60.0, true}, {79_800_002, 58.0, true}])
      )

      ingest(2021, 52, party_file([{3003, 30.0, false}], [{79_800_001, 30.0, false}]))

      ingest(
        2026,
        52,
        party_file([{3003, 45.0, false}], [
          {79_800_001, 58.0, true},
          {79_800_002, 57.0, true},
          {79_800_003, 70.0, true}
        ])
      )

      :ok
    end

    test "tells a ward that changed hands from a redrawn and a new one" do
      by_id = Map.new(Parties.get_municipality_overview(3003).wards, &{&1.ward_id, &1})

      assert %{holder: 52, previous_holder: 7, changed_hands: true, new_ward: false} =
               by_id[79_800_001]

      assert %{holder: 52, previous_holder: 7, changed_hands: false, redrawn: true} =
               by_id[79_800_002]

      refute by_id[79_800_002].new_ward

      assert %{holder: 52, previous_holder: nil, changed_hands: false, new_ward: true} =
               by_id[79_800_003]
    end

    test "compares the council share and seats of each party standing now" do
      assert %{parties: [party]} = Parties.get_municipality_overview(3003)

      assert %{
               party_id: 52,
               share: 45.0,
               previous_share: 30.0,
               swing: 15.0,
               seats: 10,
               previous_seats: 10,
               majority: false,
               previous_majority: false
             } = party
    end

    test "a ward's parties, its winner first, with the council share" do
      ward = Parties.get_ward_overview(79_800_001)

      assert %{municipality_id: 3003, holder: 52, changed_hands: true} = ward

      assert [%{party_id: 52, won: true, previous_won: false, council_share: 45.0}] =
               ward.parties

      assert Parties.get_ward_overview(79_800_009) == nil
    end
  end

  defp insert_redrawn_ward(ward_id) do
    Repo.insert_all(Iec.Maps.Boundary, [
      %{
        election: 2026,
        level: :ward,
        area_id: ward_id,
        municipality_id: 3003,
        province_id: 3,
        name: "JHB · ward #{Ward.ward_number(ward_id)}",
        path: "M0 0l1 0 0 1z",
        min_x: 0,
        min_y: 0,
        max_x: 1,
        max_y: 1,
        redrawn: true,
        inserted_at: DateTime.utc_now()
      }
    ])
  end

  describe "get_movers/0" do
    test "counts wards and complete councils gained and lost, a hung council lost by one" do
      municipality_snapshot(3003, "JHB - City of Johannesburg", true)
      municipality_snapshot(3004, "TSH - City of Tshwane", false)

      # Party 7 held both councils and wards 1 and 2; ward 2 has since been redrawn.
      ingest(
        2021,
        7,
        party_file([{3003, 55.0, true}, {3004, 55.0, true}], [
          {79_800_001, 60.0, true},
          {79_800_002, 60.0, true}
        ])
      )

      # Now Johannesburg is hung and Tshwane still counting; party 52 took both wards.
      ingest(2026, 7, party_file([{3003, 40.0, false}, {3004, 40.0, false}], []))
      insert_redrawn_ward(79_800_002)

      ingest(
        2026,
        52,
        party_file([{3003, 45.0, false}], [{79_800_001, 55.0, true}, {79_800_002, 55.0, true}])
      )

      national = %{election: 2026, name: "national", kind: :national, url: "x"}

      data = %{
        "PartyBallotResults" => [
          %{"ID" => 7, "TotalValidVotes" => 400, "PercOfVotes" => 40.0, "IOrder" => 1},
          %{"ID" => 52, "TotalValidVotes" => 450, "PercOfVotes" => 45.0, "IOrder" => 2}
        ]
      }

      {:ok, _snapshots} = Results.ingest(national, data, "{}", %{})

      by_party = Map.new(Parties.get_movers().parties, &{&1.party_id, &1})

      assert %{wards_gained: 0, wards_lost: 1, councils_gained: 0, councils_lost: 1} =
               by_party[7]

      assert %{wards_gained: 1, wards_lost: 0, councils_gained: 0, councils_lost: 0} =
               by_party[52]
    end

    test "leaves out a council share with no previous figure" do
      municipality_snapshot(3003, "JHB - City of Johannesburg", true)
      municipality_snapshot(3004, "TSH - City of Tshwane", true)
      ingest(2021, 7, party_file([{3003, nil, false}, {3004, 30.0, false}], []))
      ingest(2026, 7, party_file([{3003, 40.0, false}, {3004, 35.0, false}], []))

      assert %{local_swings: %{rises: [rise], falls: [_fall]}} = Parties.get_movers()
      assert %{municipality_id: 3004, swing: 5.0} = rise
    end
  end
end
