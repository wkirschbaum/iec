defmodule IecWeb.TableRows do
  @moduledoc """
  Builds the rows the tables render: flat maps with one field per column, already
  formatted for sorting (party abbreviations, swings, council control labels). Templates
  only display them, and `IecWeb.Sorting` sorts them by field.
  """

  import IecWeb.ResultsComponents, only: [party_abbreviation: 2, percentage_of: 2]

  alias Iec.Results
  alias Iec.Results.Snapshot

  @doc "One row per party in a snapshot, against the same party in the previous election."
  def party_rows(%Snapshot{} = snapshot, previous_snapshot, parties) do
    previous_by_party =
      Map.new((previous_snapshot && previous_snapshot.party_results) || [], &{&1.party_id, &1})

    snapshot.party_results
    |> Enum.sort_by(&(-(&1.total_valid_votes || 0)))
    |> Enum.map(fn party_result ->
      previous = previous_by_party[party_result.party_id]

      %{
        party_id: party_result.party_id,
        party_name: party_result.party_name,
        party: party_abbreviation(parties, party_result),
        votes: party_result.total_valid_votes,
        share: party_result.vote_percentage,
        previous_share: previous && previous.vote_percentage,
        swing: Results.swing(party_result.vote_percentage, previous && previous.vote_percentage),
        seats: party_result.total_seats_won,
        previous_seats: previous && previous.total_seats_won,
        councils: party_result.councils_won,
        previous_councils: previous && previous.councils_won
      }
    end)
  end

  def party_rows(nil, _previous_snapshot, _parties), do: []

  @doc """
  One row per area (provinces on the national page, municipalities on a province page):
  how far its count is, who leads now and who led before. `control` adds who runs each
  council, from `Iec.Parties.get_council_control/1`.
  """
  def area_rows(snapshots, previous_by_area, parties, control \\ %{}) do
    for snapshot <- snapshots do
      leader = Results.leading_party(snapshot)
      previous_leader = Results.leading_party(previous_by_area[snapshot.area_id])
      complete = snapshot.municipalities_complete == snapshot.municipalities_expected
      council = control[snapshot.area_id]

      %{
        area_id: snapshot.area_id,
        name: snapshot.area_name,
        counted:
          percentage_of(snapshot.voting_districts_complete, snapshot.voting_districts_expected),
        leader_id: leader && leader.party_id,
        leader: leader && party_abbreviation(parties, leader),
        share: leader && leader.vote_percentage,
        previous_leader_id: previous_leader && previous_leader.party_id,
        previous_leader: previous_leader && party_abbreviation(parties, previous_leader),
        previous_share: previous_leader && previous_leader.vote_percentage,
        complete: complete,
        segments: segments(snapshot),
        control: council,
        council: if(complete, do: council_label(council, parties, false), else: "counting")
      }
    end
  end

  # The top parties' shares, biggest first, for a card's mini bar.
  defp segments(snapshot) do
    snapshot.party_results
    |> Enum.filter(&(&1.party_id >= 0 and (&1.vote_percentage || 0) > 0))
    |> Enum.sort_by(&(-&1.vote_percentage))
    |> Enum.take(5)
    |> Enum.map(&{&1.party_id, &1.vote_percentage})
  end

  @doc """
  Who runs a council, as sortable text: "ANC majority", "hung (ANC)", or while counting
  "ANC leading"; nil when unknown.
  """
  def council_label(%{majority: party_id}, parties, _counting) when not is_nil(party_id),
    do: "#{party_abbreviation(parties, %{party_id: party_id})} majority"

  def council_label(%{largest: party_id}, parties, counting) when not is_nil(party_id) do
    name = party_abbreviation(parties, %{party_id: party_id})
    if counting, do: "#{name} leading", else: "hung (#{name})"
  end

  def council_label(_control, _parties, _counting), do: nil

  @doc """
  Rows for the close council contests (`Iec.Contests.list_council_contests/0`): the two leading
  parties by name, the change in the lead since the previous election (negative when the
  contest tightened), and the leader's part of the two-party bar.
  """
  def council_contest_rows(contests, parties) do
    for contest <- contests do
      Map.merge(contest, %{
        leader: party_abbreviation(parties, %{party_id: contest.leader_id}),
        runner_up: party_abbreviation(parties, %{party_id: contest.runner_up_id}),
        previous_leader:
          contest.previous_leader_id &&
            party_abbreviation(parties, %{party_id: contest.previous_leader_id}),
        margin_change: Results.swing(contest.margin, contest.previous_margin),
        leader_width: two_party_width(contest.leader_share, contest.runner_up_share)
      })
    end
  end

  @doc """
  Rows for the close ward contests (`Iec.Contests.list_ward_contests/0`): the ward by municipality
  and number (sorting by both), the two leading parties by name and whether it is
  declared.
  """
  def ward_contest_rows(contests, parties) do
    names = IecWeb.WardNames.all()

    for contest <- contests do
      Map.merge(contest, %{
        ward_name: names[contest.ward_id],
        ward: {contest.municipality_name || "", contest.ward_number},
        leader: party_abbreviation(parties, %{party_id: contest.leader_id}),
        runner_up: party_abbreviation(parties, %{party_id: contest.runner_up_id}),
        status: if(contest.declared, do: "declared", else: "counting")
      })
    end
  end

  @doc """
  One row per ward from the directory (`Iec.Wards`) with its result from
  `Iec.Maps.list_area_results/2`: who leads and by how much, who led before, and whether
  it is declared. A ward without results has nil figures and the status "no results".
  """
  def ward_result_rows(wards, results, parties) do
    names = IecWeb.WardNames.all()

    for ward <- wards do
      result = results[ward.ward_id]
      leader_id = result && result.leader
      previous_leader_id = result && result.previous_leader

      Map.merge(ward, %{
        ward: {ward.municipality_name || "", ward.ward_number},
        ward_name: names[ward.ward_id],
        leader_id: leader_id,
        leader: leader_id && party_abbreviation(parties, %{party_id: leader_id}),
        share: result && result.share,
        margin: result && result.margin,
        previous_leader_id: previous_leader_id,
        previous_leader:
          previous_leader_id && party_abbreviation(parties, %{party_id: previous_leader_id}),
        status:
          case result do
            %{status: :complete} -> "declared"
            %{status: :counting} -> "counting"
            _no_results -> "no results"
          end
      })
    end
  end

  # The leader's part of a bar holding only the two leading parties, in percent.
  defp two_party_width(leader_share, runner_up_share)
       when is_number(leader_share) and is_number(runner_up_share) and
              leader_share + runner_up_share > 0,
       do: leader_share / (leader_share + runner_up_share) * 100

  defp two_party_width(_leader_share, _runner_up_share), do: 50.0

  @doc "Adds the sortable name of the party in `field` (a party id) as `label_field`."
  def with_party_name(rows, parties, field, label_field) do
    Enum.map(rows, fn row ->
      party_id = Map.get(row, field)
      Map.put(row, label_field, party_id && party_abbreviation(parties, %{party_id: party_id}))
    end)
  end

  @doc """
  A council's parties: every followed party from the party files (`Iec.Parties`'
  municipality overview), or without them the province feed's top three, from the
  snapshots.
  """
  def council_party_rows([], snapshot, previous_snapshot, parties),
    do: party_rows(snapshot, previous_snapshot, parties)

  def council_party_rows(overview_parties, _snapshot, _previous_snapshot, parties),
    do: with_party_name(overview_parties, parties, :party_id, :party)

  @doc """
  A council's wards (`Iec.Parties.get_municipality_overview/1`) with sortable names for
  the winner now and before, and the places in each.
  """
  def ward_winner_rows(wards, parties) do
    wards
    |> with_party_name(parties, :holder, :holder_name)
    |> with_party_name(parties, :previous_holder, :previous_holder_name)
    |> IecWeb.WardNames.with_names()
  end

  @doc """
  Wards won per party, most first, from `ward_winner_rows/2`, against who won the same
  wards in the previous election: only declared wards count on both sides, so the
  comparison holds while the count runs. `width` and `previous_width` are shares of all
  the wards, for bars.
  """
  def ward_tally(ward_rows, parties) do
    declared = Enum.filter(ward_rows, & &1.holder)
    now = Enum.frequencies_by(declared, & &1.holder)

    before =
      declared |> Enum.filter(& &1.previous_holder) |> Enum.frequencies_by(& &1.previous_holder)

    total = max(length(ward_rows), 1)

    (Map.keys(now) ++ Map.keys(before))
    |> Enum.uniq()
    |> Enum.map(fn party_id ->
      wards = Map.get(now, party_id, 0)
      previous_wards = Map.get(before, party_id, 0)

      %{
        party_id: party_id,
        wards: wards,
        previous_wards: previous_wards,
        change: wards - previous_wards,
        width: wards / total * 100,
        previous_width: previous_wards / total * 100
      }
    end)
    |> Enum.sort_by(&{-&1.wards, -&1.previous_wards})
    |> with_party_name(parties, :party_id, :party)
  end

  @doc """
  The `limit` closest wards from `Iec.Contests.list_ward_leads/2`, narrowest lead first.
  A ward whose winner trails on the shares (a negative lead) only counts once declared.
  """
  def closest_ward_rows(leads, limit) do
    leads
    |> Enum.filter(fn {_ward_id, lead} ->
      lead.margin != nil and (lead.declared or lead.margin > 0)
    end)
    |> Enum.sort_by(fn {_ward_id, lead} -> lead.margin end)
    |> Enum.take(limit)
    |> Enum.map(fn {ward_id, lead} ->
      Map.merge(lead, %{ward_id: ward_id, ward_number: Results.Ward.ward_number(ward_id)})
    end)
    |> IecWeb.WardNames.with_names()
  end

  @doc """
  Parties by their net gain of wards or councils (`gained` minus `lost`, fields of
  `Iec.Parties.get_movers/0`' parties), biggest first, leaving out parties with neither.
  """
  def net_rows(movers, gained, lost) do
    movers
    |> Enum.map(&Map.put(&1, :net, Map.fetch!(&1, gained) - Map.fetch!(&1, lost)))
    |> Enum.reject(&(Map.fetch!(&1, gained) == 0 and Map.fetch!(&1, lost) == 0))
    |> Enum.sort_by(& &1.net, :desc)
  end
end
