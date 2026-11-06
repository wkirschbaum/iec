defmodule Iec.Results.Change do
  @moduledoc "What differs between a snapshot and the one before it for the same area."

  alias Iec.Results.Snapshot

  defstruct [:snapshot, :previous, progress: [], parties: [], leader: nil]

  @counted_progress [
    voting_districts_complete: "voting districts",
    wards_complete: "wards",
    seats_complete: "seats",
    municipalities_complete: "councils",
    total_votes_cast: "votes cast"
  ]

  @doc """
  Compares a snapshot (with `previous_snapshot` and party results preloaded) against
  its previous one.

    * `progress` – `{label, delta, now}` for each counter that moved
    * `parties` – `%{party_id, party_name, votes, seats, percentage}` deltas, biggest vote gain first
    * `leader` – `{from, to}` (`%{party_id, party_name}`) when the vote leader changed
  """
  def compare(%Snapshot{previous_snapshot: previous} = snapshot) when not is_nil(previous) do
    progress =
      for {field, label} <- @counted_progress,
          now = Map.get(snapshot, field),
          before = Map.get(previous, field),
          is_integer(now) and is_integer(before) and now != before do
        {label, now - before, now}
      end

    before_by_party = Map.new(previous.party_results, &{&1.party_id, &1})

    parties =
      snapshot.party_results
      |> Enum.map(fn party ->
        before = Map.get(before_by_party, party.party_id, %{})

        %{
          party_id: party.party_id,
          party_name: party.party_name,
          votes: delta(party.total_valid_votes, Map.get(before, :total_valid_votes)),
          seats: delta(party.total_seats_won, Map.get(before, :total_seats_won)),
          percentage: delta(party.vote_percentage, Map.get(before, :vote_percentage))
        }
      end)
      |> Enum.reject(&(&1.votes == 0 and &1.seats == 0))
      |> Enum.sort_by(&(-&1.votes))

    leader =
      case {leader(previous), leader(snapshot)} do
        {same, same} -> nil
        {from, to} -> {from, to}
      end

    %__MODULE__{
      snapshot: snapshot,
      previous: previous,
      progress: progress,
      parties: parties,
      leader: leader
    }
  end

  def compare(%Snapshot{} = snapshot), do: %__MODULE__{snapshot: snapshot}

  @doc "True when this is the area's first snapshot."
  def first?(%__MODULE__{previous: previous}), do: is_nil(previous)

  defp leader(%Snapshot{party_results: party_results}) do
    case Enum.max_by(party_results, &(&1.total_valid_votes || 0), fn -> nil end) do
      nil -> nil
      party -> %{party_id: party.party_id, party_name: party.party_name}
    end
  end

  defp delta(now, nil), do: now || 0
  defp delta(nil, _before), do: 0
  defp delta(now, before) when is_float(now), do: Float.round(now - before, 2)
  defp delta(now, before), do: now - before
end
