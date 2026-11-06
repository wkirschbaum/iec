defmodule IecWeb.Narrative do
  @moduledoc """
  Writes the one-line headline and summary at the top of a page from its numbers, the
  way a results desk would: who leads, by how much, what moved, how far the count is.
  """

  import IecWeb.ResultsComponents, only: [party_abbreviation: 2, percentage_of: 2]

  @doc """
  `%{headline, lede, eyebrow, live}` for an area: its snapshot and party rows (`IecWeb.TableRows`).
  Nil before there are results.
  """
  def summary(nil, _rows, _parties, _previous_year), do: nil
  def summary(_snapshot, [], _parties, _previous_year), do: nil

  def summary(snapshot, rows, parties, previous_year) do
    ranked =
      rows
      |> Enum.filter(&(&1.party_id >= 0 and (&1.share || 0) > 0))
      |> Enum.sort_by(&(-&1.share))

    case ranked do
      [] ->
        nil

      [leader | others] ->
        final = final?(snapshot)

        %{
          headline: headline(leader, parties, previous_year, final),
          lede: lede(snapshot, leader, others, parties, previous_year, final),
          eyebrow:
            if(final, do: "Final results", else: "Live · #{counted_share(snapshot)} counted"),
          live: not final
        }
    end
  end

  defp headline(leader, parties, previous_year, final) do
    name = party_abbreviation(parties, leader)
    share = percent(leader.share)
    verb = if final, do: "wins", else: "leads"

    case leader.swing do
      nil ->
        "#{name} #{verb} with #{share}"

      swing when swing <= -0.5 ->
        "#{name} #{verb} with #{share}, down #{points(swing)} on #{previous_year}"

      swing when swing >= 0.5 ->
        "#{name} #{verb} with #{share}, up #{points(swing)} on #{previous_year}"

      _flat ->
        "#{name} #{verb} with #{share}, level with #{previous_year}"
    end
  end

  defp lede(snapshot, leader, others, parties, previous_year, final) do
    [
      runner_up(leader, others, parties, final),
      biggest_mover(others, parties, previous_year),
      councils(snapshot),
      counted(snapshot)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp runner_up(leader, [second | _], parties, final),
    do:
      "#{party_abbreviation(parties, second)} #{if final, do: "finishes", else: "is"} second with #{percent(second.share)}, #{points(leader.share - second.share)} behind."

  defp runner_up(_leader, [], _parties, _final), do: nil

  # The biggest climber among the rest, or the strongest newcomer.
  defp biggest_mover(others, parties, previous_year) do
    climber =
      others |> Enum.filter(&is_number(&1.swing)) |> Enum.max_by(& &1.swing, fn -> nil end)

    newcomer =
      others |> Enum.filter(&is_nil(&1.previous_share)) |> Enum.max_by(& &1.share, fn -> nil end)

    cond do
      newcomer != nil and newcomer.share >= 1 and
          (is_nil(climber) or newcomer.share > climber.swing) ->
        "#{party_abbreviation(parties, newcomer)}, not on the #{previous_year} list, has #{percent(newcomer.share)}."

      climber != nil and climber.swing >= 0.5 ->
        "#{party_abbreviation(parties, climber)} has gained most, up #{points(climber.swing)}."

      true ->
        nil
    end
  end

  defp councils(
         %{municipalities_expected: expected, municipalities_complete: complete} = snapshot
       )
       when is_integer(expected) and expected > 1 and is_integer(complete) and complete > 0 do
    hung = snapshot.hung_councils || 0
    "#{hung} of #{complete} decided councils are hung."
  end

  defp councils(_snapshot), do: nil

  defp counted(snapshot) do
    percentage =
      percentage_of(snapshot.voting_districts_complete, snapshot.voting_districts_expected)

    if percentage < 100,
      do: "#{:erlang.float_to_binary(percentage, decimals: 1)}% of voting districts counted.",
      else: "Every voting district is counted."
  end

  @doc """
  One sentence on a party: its national share and swing, and the wards and councils it
  has gained and lost. Nil before it has results.
  """
  def party(%{share: nil}, _name, _previous_year), do: nil

  def party(stats, name, previous_year) do
    swing =
      case stats.swing do
        nil -> "standing for the first time since #{previous_year}"
        swing when swing >= 0.05 -> "up #{points(swing)} on #{previous_year}"
        swing when swing <= -0.05 -> "down #{points(swing)} on #{previous_year}"
        _flat -> "level with #{previous_year}"
      end

    "#{name} has #{percent(stats.share)} of the vote, #{swing}. " <>
      "It has gained #{count(stats.wards_gained, "ward")} and lost #{stats.wards_lost}, " <>
      "gained #{count(stats.councils_gained, "council majority", "council majorities")} " <>
      "and lost #{stats.councils_lost}."
  end

  defp final?(snapshot),
    do:
      is_integer(snapshot.voting_districts_expected) and
        snapshot.voting_districts_expected > 0 and
        snapshot.voting_districts_complete >= snapshot.voting_districts_expected

  defp counted_share(snapshot),
    do:
      :erlang.float_to_binary(
        percentage_of(snapshot.voting_districts_complete, snapshot.voting_districts_expected),
        decimals: 1
      ) <> "%"

  defp count(number, singular, plural \\ nil)
  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(number, singular, plural), do: "#{number} #{plural || singular <> "s"}"

  defp percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  defp points(value), do: :erlang.float_to_binary(abs(value) / 1, decimals: 1) <> " points"
end
