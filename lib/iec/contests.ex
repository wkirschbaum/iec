defmodule Iec.Contests do
  @moduledoc """
  Close contests: how narrowly each council and ward is led, as the lead of the first party
  over the second.

  Councils compare votes cast for the council (from the province files, which carry each
  municipality's top three parties), so their lead is known in points and in votes.
  Wards compare the shares in the party files, which carry no vote counts, so their lead
  is in points only. Those shares are of all the ward's votes, while the seat goes to
  whoever wins the ward ballot (independents, for one, stand on that ballot only), so in
  a few declared wards the winner trails another party; such a ward has no margin and is
  left out of the ward contests.
  """

  import Ecto.Query

  alias Iec.{Maps, Repo, Results}
  alias Iec.Results.{PartyWardResult, Snapshot, Ward}

  @doc """
  The two leading parties of a snapshot and the gap between them:
  `%{leader, runner_up, margin, margin_votes}` with party results for the parties, the
  margin in percentage points and in votes. Nil until two parties have votes.
  """
  def lead(nil), do: nil

  def lead(%Snapshot{party_results: party_results}) do
    ranked =
      party_results
      |> Enum.filter(&(&1.party_id >= 0 and (&1.total_valid_votes || 0) > 0))
      |> Enum.sort_by(& &1.total_valid_votes, :desc)

    case ranked do
      [leader, runner_up | _others] ->
        %{
          leader: leader,
          runner_up: runner_up,
          margin: Results.swing(leader.vote_percentage, runner_up.vote_percentage),
          margin_votes: leader.total_valid_votes - runner_up.total_valid_votes
        }

      _fewer_than_two ->
        nil
    end
  end

  @doc """
  Every council with at least two parties on the board, closest first: its two leading
  parties and their shares, the lead in points and votes, how far its count is, and the
  lead in the previous election.
  """
  def list_council_contests do
    previous_leads =
      Results.list_latest_snapshots(election: Results.previous_year(), level: :municipality)
      |> Map.new(&{&1.area_id, lead(&1)})

    for snapshot <- Results.list_latest_snapshots(level: :municipality),
        lead = lead(snapshot) do
      previous = previous_leads[snapshot.area_id]

      %{
        municipality_id: snapshot.area_id,
        name: snapshot.area_name,
        province_id: snapshot.province_id,
        leader_id: lead.leader.party_id,
        leader_share: lead.leader.vote_percentage,
        runner_up_id: lead.runner_up.party_id,
        runner_up_share: lead.runner_up.vote_percentage,
        margin: lead.margin,
        margin_votes: lead.margin_votes,
        counted: counted(snapshot),
        complete: snapshot.municipalities_complete == 1,
        previous_leader_id: previous && previous.leader.party_id,
        previous_margin: previous && previous.margin
      }
    end
    |> Enum.sort_by(& &1.margin)
  end

  defp counted(%Snapshot{voting_districts_expected: expected}) when expected in [nil, 0],
    do: 0.0

  defp counted(snapshot),
    do:
      min((snapshot.voting_districts_complete || 0) / snapshot.voting_districts_expected, 1.0) *
        100

  @doc """
  Every ward with at least two parties on the board, closest first: its municipality and
  number, its two leading parties and their shares, the lead in points, and whether it is
  declared. A new or redrawn ward is marked as such.
  """
  def list_ward_contests do
    leads = list_ward_leads(Results.live_year())
    municipality_names = Results.list_area_names(:municipality)
    redrawn = Maps.list_redrawn_ward_ids()

    municipality_ids =
      Repo.all(
        from ward in Ward,
          where: ward.id in ^Map.keys(leads),
          select: {ward.id, ward.municipality_id}
      )
      |> Map.new()

    # An undeclared ward level at 0.00 is a handful of early votes, not a real tie.
    for {ward_id, lead} <- leads, lead.margin != nil, lead.declared or lead.margin > 0 do
      municipality_id = municipality_ids[ward_id]

      Map.merge(lead, %{
        ward_id: ward_id,
        ward_number: Ward.ward_number(ward_id),
        municipality_id: municipality_id,
        municipality_name: municipality_names[municipality_id],
        redrawn: ward_id in redrawn
      })
    end
    |> Enum.sort_by(& &1.margin)
  end

  @doc """
  The two leading parties of each ward in an election, from the party files, keyed by
  ward id: `%{leader_id, leader_share, runner_up_id, runner_up_share, margin, declared}`.
  A declared ward leads with its winner. Without a second party on the board the
  runner-up and margin are nil, and so is the margin of a winner trailing on these
  shares. Optionally limited to some wards.
  """
  def list_ward_leads(year, ward_ids \\ nil) do
    ranked =
      PartyWardResult
      |> where([result], result.election == ^year)
      |> where([result], result.vote_percentage > 0.0 or result.won)
      |> then(&if ward_ids, do: where(&1, [result], result.ward_id in ^ward_ids), else: &1)
      |> select([result], %{
        ward_id: result.ward_id,
        party_id: result.party_id,
        share: result.vote_percentage,
        won: result.won,
        rank:
          over(row_number(),
            partition_by: result.ward_id,
            order_by: [desc: result.won, desc: result.vote_percentage, asc: result.party_id]
          )
      })

    from(row in subquery(ranked), where: row.rank <= 2, order_by: [row.ward_id, row.rank])
    |> Repo.all()
    |> Enum.group_by(& &1.ward_id)
    |> Map.new(fn {ward_id, rows} -> {ward_id, ward_lead(rows)} end)
  end

  defp ward_lead([leader | rest]) do
    runner_up = List.first(rest)
    margin = runner_up && Results.swing(leader.share || 0.0, runner_up.share || 0.0)

    %{
      leader_id: leader.party_id,
      leader_share: leader.share,
      runner_up_id: runner_up && runner_up.party_id,
      runner_up_share: runner_up && runner_up.share,
      # A winner trailing on these shares has no meaningful lead to show.
      margin: if(margin && margin >= 0, do: margin),
      declared: leader.won
    }
  end
end
