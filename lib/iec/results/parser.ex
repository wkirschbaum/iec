defmodule Iec.Results.Parser do
  @moduledoc """
  Turns a decoded IEC results file into area maps ready to store as snapshots.

  The national file yields the national area with every party. A province file yields
  the province with every party, plus each of its municipalities with the top parties
  the IEC includes there (the IEC trims those to three).
  """

  alias Iec.Results.Snapshot

  @doc "Parses the file of the given feed kind into a list of area maps."
  def parse(:national, data), do: [area(:national, 0, "South Africa", nil, data)]

  def parse(:province, data) do
    province_id = data["ProvinceID"]
    province = area(:province, province_id, data["Province"], province_id, data)

    municipalities =
      for municipality <- data["MunicipalityResults"] || [] do
        area(
          :municipality,
          municipality["MunicipalityID"],
          municipality["Municipality"],
          province_id,
          municipality
        )
      end

    [province | municipalities]
  end

  @doc """
  Parses a party file into the party's rows per municipality and per ward.

  The IEC nests every ward of a province under that province's first municipality, so
  wards are returned flat; `Iec.Results.Ward` maps them to municipalities.
  """
  def parse_party(data) do
    municipalities =
      for province <- data["ProvinceResults"] || [],
          municipality <- province["MunicipalityResults"] || [],
          party <- Enum.take(municipality["PartyBallotResults"] || [], 1) do
        %{
          municipality_id: municipality["MunicipalityID"],
          province_id: province["ProvinceID"],
          vote_percentage: to_float(party["PercOfVotes"]),
          seats_won: party["TotalSeatsWon"],
          majority: party["MajorityWon"] == 1,
          council_winner: party["IsCouncilWinner"] == true
        }
      end

    # A ward's TotalSeatsWon is 1 once it is declared for this party; these add up to
    # the party's WardSeatsWon. (IsLeadingPartyVotes is true for every ward.)
    wards =
      for province <- data["ProvinceResults"] || [],
          municipality <- province["MunicipalityResults"] || [],
          ward <- municipality["WardResults"] || [],
          party <- Enum.take(ward["PartyBallotResults"] || [], 1) do
        %{
          ward_id: ward["WardID"],
          vote_percentage: to_float(party["PercOfVotes"]),
          won: party["TotalSeatsWon"] == 1
        }
      end

    %{municipalities: municipalities, wards: Enum.uniq_by(wards, & &1.ward_id)}
  end

  @doc "The report date of a file, as UTC."
  def report_date(data), do: parse_date(data["ReportDate"])

  defp area(level, area_id, area_name, province_id, data) do
    party_results =
      (data["PartyBallotResults"] || [])
      |> Enum.map(&party_result/1)
      |> Enum.sort_by(& &1.position)

    totals = Enum.find(data["PartyBallotResults"] || [], %{}, &(&1["RegisteredVoters"] > 0))

    attributes = %{
      level: level,
      area_id: area_id,
      area_name: area_name,
      province_id: province_id,
      registered_voters: totals["RegisteredVoters"] || data["RegPop"],
      total_votes_cast: totals["TotalVotesCast"],
      valid_votes_cast: totals["ValidVotesCast"],
      spoilt_votes: totals["SpoiltVotes"],
      special_votes: totals["SpecialVotes"],
      voting_districts_complete: data["VDsComplete"],
      voting_districts_expected: data["VDExpected"],
      wards_complete: data["WardsComplete"],
      wards_expected: data["WardExpected"],
      municipalities_complete: data["MuncipalitiesComplete"],
      municipalities_expected: data["MunicExpected"],
      seats_complete: data["SeatsComplete"],
      seats_expected: data["SeatsExpected"],
      hung_councils: data["HungCouncils"],
      majority_councils: data["MajorityCouncils"],
      drawn_councils: data["TotalDrawnCouncils"],
      party_results: party_results
    }

    attributes
    |> Map.put(:content_hash, content_hash(attributes))
    |> Map.put(:report_date, parse_date(data["ReportDate"]))
  end

  defp party_result(party) do
    %{
      party_id: party["ID"],
      party_name: party["Name"],
      position: party["IOrder"],
      total_valid_votes: party["TotalValidVotes"],
      vote_percentage: to_float(party["PercOfVotes"]),
      ward_votes: party["WardVotes"],
      pr_votes: party["PRVotes"],
      ward_seats_won: party["WardSeatsWon"],
      pr_seats_won: party["PRSeatsWon"],
      total_seats_won: party["TotalSeatsWon"],
      available_seats: party["AvailableSeats"],
      councils_won: party["CouncilsWon"],
      majority_won: party["MajorityWon"],
      council_winner: party["IsCouncilWinner"]
    }
  end

  # The report date moves on every regeneration, so it stays out of the hash: a new
  # snapshot is stored only when the figures themselves change.
  defp content_hash(attributes) do
    figures =
      Map.take(attributes, [:area_name, :party_results | Snapshot.progress_fields()])

    :crypto.hash(:sha256, :erlang.term_to_binary(figures)) |> Base.encode16(case: :lower)
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case DateTime.from_iso8601(value) do
      # The IEC writes between one and seven fractional digits; store all as microseconds.
      {:ok, %DateTime{microsecond: {microseconds, _precision}} = date_time, _offset} ->
        %{date_time | microsecond: {microseconds, 6}}

      {:error, _reason} ->
        nil
    end
  end

  defp to_float(nil), do: nil
  defp to_float(value) when is_number(value), do: value / 1
end
