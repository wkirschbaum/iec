defmodule Iec.ResultsTest do
  use Iec.DataCase, async: true

  alias Iec.Results
  alias Iec.Results.Change

  @feed %{
    election: 2026,
    name: "province-3",
    kind: :province,
    url: "https://results.example/p3.js"
  }

  defp party(id, name, votes, seats) do
    %{
      "ID" => id,
      "Name" => name,
      "TotalValidVotes" => votes,
      "PercOfVotes" => votes / 10,
      "TotalSeatsWon" => seats,
      "IOrder" => id,
      "RegisteredVoters" => 2000,
      "TotalVotesCast" => 1010,
      "ValidVotesCast" => 1000,
      "SpoiltVotes" => 10,
      "SpecialVotes" => 5
    }
  end

  defp province_file(report_date, anc_votes, voting_districts_complete) do
    %{
      "ProvinceID" => 3,
      "Province" => "Gauteng",
      "ReportDate" => report_date,
      "VDsComplete" => voting_districts_complete,
      "VDExpected" => 10,
      "PartyBallotResults" => [party(7, "ANC", anc_votes, 3), party(52, "DA", 400, 2)],
      "MunicipalityResults" => [
        %{
          "MunicipalityID" => 3003,
          "Municipality" => "JHB - City of Johannesburg",
          "ReportDate" => report_date,
          "VDsComplete" => 4,
          "VDExpected" => 5,
          "PartyBallotResults" => [party(52, "DA", 300, 1)]
        }
      ]
    }
  end

  defp ingest(feed \\ @feed, data) do
    {:ok, snapshots} = Results.ingest(feed, data, Jason.encode!(data), %{etag: nil})
    snapshots
  end

  describe "ingest/4" do
    test "stores a snapshot per area the first time" do
      snapshots = ingest(province_file("2026-11-06T07:00:00.1+02:00", 500, 6))

      assert [:province, :municipality] == Enum.map(snapshots, & &1.level)
      assert Enum.all?(snapshots, &is_nil(&1.previous_snapshot_id))
      assert [_, _] = Results.get_latest_snapshot(:province, 3).party_results
    end

    test "skips areas whose figures did not change, even with a new report date" do
      ingest(province_file("2026-11-06T07:00:00+02:00", 500, 6))

      assert [] == ingest(province_file("2026-11-06T07:05:00+02:00", 500, 6))
    end

    test "links a changed area to its previous snapshot" do
      [first_province, _municipality] = ingest(province_file("2026-11-06T07:00:00+02:00", 500, 6))

      assert [changed] = ingest(province_file("2026-11-06T07:05:00+02:00", 550, 7))
      assert changed.level == :province
      assert changed.previous_snapshot_id == first_province.id
    end

    test "keeps elections apart" do
      ingest(%{@feed | election: 2021}, province_file("2022-01-15T17:00:00+02:00", 900, 10))
      ingest(province_file("2026-11-06T07:00:00+02:00", 500, 6))

      assert Results.get_latest_snapshot(:province, 3).voting_districts_complete == 6

      assert Results.get_latest_snapshot(:province, 3, election: 2021).voting_districts_complete ==
               10
    end
  end

  describe "list_area_summaries/1" do
    test "names each area from its latest live snapshot, and says if a council is done" do
      ingest(%{@feed | election: 2021}, province_file("2022-01-15T17:00:00+02:00", 900, 10))
      ingest(province_file("2026-11-06T07:00:00+02:00", 500, 6))

      renamed =
        province_file("2026-11-06T07:05:00+02:00", 500, 6)
        |> put_in(["MunicipalityResults", Access.at(0), "Municipality"], "JHB - Joburg")
        |> put_in(["MunicipalityResults", Access.at(0), "MuncipalitiesComplete"], 1)

      ingest(renamed)

      assert Results.list_area_summaries(:municipality) == %{
               3003 => %{id: 3003, name: "JHB - Joburg", province_id: 3, complete: true}
             }

      assert %{3 => %{name: "Gauteng", complete: false}} = Results.list_area_summaries(:province)
      assert Results.list_area_names(:municipality) == %{3003 => "JHB - Joburg"}
      assert Results.get_area_name(:municipality, 3003) == "JHB - Joburg"
      assert Results.get_area_name(:municipality, 3004) == nil
    end
  end

  describe "Parser.parse/2" do
    test "takes the totals from a party with registered voters, skipping those without" do
      data = %{
        "PartyBallotResults" => [
          Map.put(party(7, "ANC", 500, 3), "RegisteredVoters", nil),
          Map.put(party(52, "DA", 400, 2), "RegisteredVoters", 0),
          Map.put(party(1, "IFP", 100, 1), "RegisteredVoters", 3000)
        ]
      }

      assert [%{registered_voters: 3000, total_votes_cast: 1010}] =
               Iec.Results.Parser.parse(:national, data)
    end
  end

  describe "Change.compare/1" do
    test "reports progress, vote and leader changes" do
      ingest(province_file("2026-11-06T07:00:00+02:00", 300, 6))
      ingest(province_file("2026-11-06T07:05:00+02:00", 450, 8))

      [change | _] = Results.list_changes(level: :province) |> Enum.map(&Change.compare/1)

      assert {"voting districts", 2, 8} in change.progress
      assert [%{party_id: 7, votes: 150}] = change.parties

      assert %{from: %{party_id: 52}, to: %{party_id: 7}} = change.leader
    end

    test "a first snapshot has nothing to compare" do
      ingest(province_file("2026-11-06T07:00:00+02:00", 300, 6))

      [change | _] = Results.list_changes(level: :province) |> Enum.map(&Change.compare/1)

      assert Change.first?(change)
    end
  end
end
