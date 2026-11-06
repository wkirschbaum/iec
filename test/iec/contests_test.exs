defmodule Iec.ContestsTest do
  use Iec.DataCase, async: true

  alias Iec.{Parties, Contests, Repo, Results}
  alias Iec.Results.Ward

  # A province file with one municipality per entry: `{municipality_id, [{party_id, votes}],
  # districts_complete}` out of ten districts.
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
            "Municipality" => "M#{municipality_id}",
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

    {:ok, _snapshots} = Results.ingest(feed, data, "{}", %{})
  end

  # One party's file with its share of each ward: `{ward_id, share, won}`.
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
  end

  describe "list_council_contests/0" do
    test "lists councils closest first, with the lead in points and votes" do
      # 3004 was 70–30 in 2021 and is now 52–48; 3003 is a 60–40 contest; 3005 has
      # only one party on the board.
      ingest_province(2021, [{3004, [{7, 700}, {52, 300}], 10}])

      ingest_province(2026, [
        {3003, [{7, 600}, {52, 400}], 10},
        {3004, [{52, 480}, {7, 520}], 4},
        {3005, [{7, 100}], 1}
      ])

      assert [closest, next] = Contests.list_council_contests()

      assert %{
               municipality_id: 3004,
               leader_id: 7,
               runner_up_id: 52,
               margin: 4.0,
               margin_votes: 40,
               counted: 40.0,
               complete: false,
               previous_leader_id: 7,
               previous_margin: 40.0
             } = closest

      assert %{municipality_id: 3003, margin: 20.0, complete: true, previous_margin: nil} = next
    end
  end

  describe "list_ward_contests/0" do
    test "lists wards closest first, a declared ward led by its winner" do
      Repo.insert_all(Ward, [
        %{id: 79_800_001, municipality_id: 3003, ward_number: 1, inserted_at: DateTime.utc_now()},
        %{id: 79_800_002, municipality_id: 3003, ward_number: 2, inserted_at: DateTime.utc_now()}
      ])

      ingest_province(2026, [{3003, [{7, 600}, {52, 400}], 10}])
      # Ward 1: 7 won with 47.5 to 52's 46.0. Ward 2: 52 leads 60 to 30, still counting.
      ingest_party_wards(2026, 7, [{79_800_001, 47.5, true}, {79_800_002, 30.0, false}])
      ingest_party_wards(2026, 52, [{79_800_001, 46.0, false}, {79_800_002, 60.0, false}])
      # Only one party has a share in ward 3, so it is no contest yet.
      ingest_party_wards(2026, 99, [{79_800_003, 80.0, false}])

      assert [first, second] = Contests.list_ward_contests()

      assert %{
               ward_id: 79_800_001,
               ward_number: 1,
               municipality_id: 3003,
               municipality_name: "M3003",
               leader_id: 7,
               runner_up_id: 52,
               margin: 1.5,
               declared: true
             } = first

      assert %{ward_id: 79_800_002, leader_id: 52, margin: 30.0, declared: false} = second
    end
  end

  describe "list_ward_leads/2" do
    test "a ward with one party on the board has no runner-up" do
      ingest_party_wards(2026, 7, [{79_800_001, 55.0, false}])

      assert %{79_800_001 => %{leader_id: 7, runner_up_id: nil, margin: nil}} =
               Contests.list_ward_leads(2026, [79_800_001])

      assert Contests.list_ward_leads(2026, [79_800_002]) == %{}
    end

    test "a winner trailing on the shares has no margin, and is no ward contest" do
      # Independents won the ward ballot with a smaller share of all the ward's votes.
      ingest_party_wards(2026, 0, [{79_800_001, 23.1, true}])
      ingest_party_wards(2026, 52, [{79_800_001, 26.0, false}])

      assert %{79_800_001 => %{leader_id: 0, runner_up_id: 52, margin: nil, declared: true}} =
               Contests.list_ward_leads(2026)

      assert Contests.list_ward_contests() == []
    end
  end
end
