defmodule IecWeb.ChangeDigest do
  @moduledoc """
  Turns a stream of area changes into something a person can follow: update rounds (all
  changes stored in the same minute, one poll of the feeds), each with a one-line summary
  and its notable events — a lead changing hands, a council's count finishing — while the
  routine count updates stay folded away.
  """

  alias Iec.Results.Change

  @doc """
  Rounds, newest first: `%{id, at, areas, voting_districts, votes, events, changes}`.
  `voting_districts` and `votes` are the national counts' movement in the round (nil
  when the national figures did not move).
  """
  def rounds(changes) do
    changes
    |> Enum.group_by(&round_key/1)
    |> Enum.map(fn {key, changes} ->
      national = Enum.find(changes, &(&1.snapshot.level == :national))

      %{
        id: "round-#{key}",
        at: changes |> Enum.map(& &1.snapshot.inserted_at) |> Enum.max(DateTime),
        areas: length(changes),
        voting_districts: national && progress(national, "voting districts"),
        votes: national && progress(national, "votes cast"),
        events: Enum.flat_map(changes, &events/1),
        changes: changes
      }
    end)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  @doc "The notable events across changes, newest first."
  def highlights(changes) do
    changes
    |> Enum.flat_map(&events/1)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  # One poll of the feeds lands within the same minute.
  defp round_key(%Change{snapshot: snapshot}),
    do: Calendar.strftime(snapshot.inserted_at, "%Y%m%d%H%M")

  defp progress(%Change{progress: progress}, label) do
    Enum.find_value(progress, fn
      {^label, delta, _now} -> delta
      _other -> nil
    end)
  end

  # `%{kind: :lead | :decided, at, snapshot, from, to}`.
  defp events(%Change{snapshot: snapshot} = change) do
    lead =
      if change.leader && change.leader.from do
        [
          %{
            kind: :lead,
            at: snapshot.inserted_at,
            snapshot: snapshot,
            from: change.leader.from,
            to: change.leader.to
          }
        ]
      else
        []
      end

    decided =
      if decided?(change) do
        [
          %{
            kind: :decided,
            at: snapshot.inserted_at,
            snapshot: snapshot,
            from: nil,
            to: leader(change)
          }
        ]
      else
        []
      end

    lead ++ decided
  end

  # A municipality whose count finished in this change.
  defp decided?(%Change{snapshot: %{level: :municipality} = snapshot, previous: previous})
       when not is_nil(previous),
       do: snapshot.municipalities_complete == 1 and previous.municipalities_complete != 1

  defp decided?(_change), do: false

  defp leader(%Change{snapshot: snapshot}) do
    case Iec.Results.leading_party(snapshot) do
      nil -> nil
      party -> %{party_id: party.party_id, party_name: party.party_name}
    end
  end
end
