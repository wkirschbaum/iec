defmodule IecWeb.Narrative do
  @moduledoc """
  Writes the one-line headline and summary at the top of a page from its numbers, the
  way a results desk would: who leads, by how much, what moved, how far the count is.
  """

  import IecWeb.ResultsComponents,
    only: [format_number: 1, format_progress: 2, party_abbreviation: 2, percentage_of: 2]

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

  # Level to a tenth of a point reads as a tie, not "0.0 points behind".
  defp runner_up(leader, [second | _], parties, final)
       when abs(leader.share - second.share) < 0.05,
       do:
         "#{party_abbreviation(parties, second)} #{if final, do: "finishes", else: "is"} level with it on #{percent(second.share)}."

  defp runner_up(leader, [second | _], parties, final),
    do:
      "#{party_abbreviation(parties, second)} #{if final, do: "finishes", else: "is"} second with #{percent(second.share)}, #{points(leader.share - second.share)} behind."

  defp runner_up(_leader, [], _parties, _final), do: nil

  # The biggest climber among the rest, or the strongest newcomer.
  defp biggest_mover(others, parties, previous_year) do
    climber =
      others |> Enum.filter(&is_number(&1.swing)) |> Enum.max_by(& &1.swing, fn -> nil end)

    # Without any previous figures (an area new since then) nobody is a newcomer.
    newcomer =
      if Enum.any?(others, &is_number(&1.previous_share)),
        do:
          others
          |> Enum.filter(&is_nil(&1.previous_share))
          |> Enum.max_by(& &1.share, fn -> nil end)

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

    case {hung, complete} do
      {1, 1} ->
        "The one decided council is hung."

      {0, 1} ->
        "The one decided council is not hung."

      {1, complete} ->
        "1 of #{complete} decided councils is hung."

      {hung, complete} ->
        "#{hung} of #{complete} decided councils are hung."
    end
  end

  defp councils(_snapshot), do: nil

  defp counted(snapshot) do
    percentage =
      percentage_of(snapshot.voting_districts_complete, snapshot.voting_districts_expected)

    if percentage < 100,
      do:
        "#{format_progress(snapshot.voting_districts_complete, snapshot.voting_districts_expected)} of voting districts counted.",
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
        nil -> "not on the #{previous_year} ballot"
        swing when swing >= 0.05 -> "up #{points(swing)} on #{previous_year}"
        swing when swing <= -0.05 -> "down #{points(swing)} on #{previous_year}"
        _flat -> "level with #{previous_year}"
      end

    "#{name} has #{percent(stats.share)} of the vote, #{swing}. " <>
      "It has gained #{count(stats.wards_gained, "ward")} and lost #{stats.wards_lost}, " <>
      "gained #{count(stats.councils_gained, "council majority", "council majorities")} " <>
      "and lost #{stats.councils_lost}."
  end

  @doc """
  `%{headline, lede, eyebrow, live}` for a ward (`Iec.Parties.get_ward_overview/1`): who
  won or leads it and by how much, whether it changed hands, and the runner-up. `lead`
  is the ward's entry from `Iec.Contests.list_ward_leads/2`. Nil before it has results.
  """
  def ward(_ward, nil, _parties, _previous_year), do: nil

  def ward(ward, lead, parties, previous_year) do
    leader = party_abbreviation(parties, %{party_id: lead.leader_id})
    verb = if lead.declared, do: "wins", else: "leads"

    %{
      headline:
        "#{leader} #{verb} ward #{ward.ward_number}" <>
          if(is_number(lead.leader_share), do: " with #{percent(lead.leader_share)}", else: ""),
      lede:
        [
          ward_runner_up(lead, parties),
          ward_history(ward, lead, parties, previous_year)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" "),
      eyebrow: if(lead.declared, do: "Declared", else: "Live · counting"),
      live: not lead.declared
    }
  end

  defp ward_runner_up(%{runner_up_id: nil}, _parties), do: "No other party has votes yet."

  # Shares count every ballot in the ward; the seat goes by the ward ballot alone.
  defp ward_runner_up(%{margin: nil} = lead, parties),
    do:
      "#{party_abbreviation(parties, %{party_id: lead.leader_id})} won the ward ballot, " <>
        "though #{party_abbreviation(parties, %{party_id: lead.runner_up_id})} has the " <>
        "bigger share of all the ward's votes, #{percent(lead.runner_up_share)}."

  defp ward_runner_up(%{margin: margin} = lead, parties) when margin < 0.05,
    do:
      "#{party_abbreviation(parties, %{party_id: lead.runner_up_id})} is level with it on " <>
        "#{percent(lead.runner_up_share)}."

  defp ward_runner_up(lead, parties),
    do:
      "#{party_abbreviation(parties, %{party_id: lead.runner_up_id})} is second with " <>
        "#{percent(lead.runner_up_share)}, #{points(lead.margin)} behind."

  defp ward_history(%{new_ward: true}, _lead, _parties, previous_year),
    do: "The ward is new since #{previous_year}."

  defp ward_history(%{redrawn: true}, _lead, _parties, previous_year),
    do: "Its boundary was redrawn since #{previous_year}, so it does not compare like for like."

  defp ward_history(%{previous_holder: nil}, _lead, _parties, _previous_year), do: nil

  defp ward_history(ward, lead, parties, previous_year) do
    previous = party_abbreviation(parties, %{party_id: ward.previous_holder})

    cond do
      ward.previous_holder == lead.leader_id and is_number(ward.previous_share) ->
        "#{previous} also won it in #{previous_year}, with #{percent(ward.previous_share)}."

      ward.previous_holder == lead.leader_id ->
        "#{previous} also won it in #{previous_year}."

      lead.declared ->
        "It takes the ward from #{previous}, which won it in #{previous_year}."

      true ->
        "#{previous} won it in #{previous_year}."
    end
  end

  @doc """
  One or two sentences on the close contests: the narrowest council (`closest`, a council
  contest row, or nil) and how many councils and wards are within `within` points. Nil
  before any council has two parties on the board.
  """
  def close_contests(nil, _counts, _within), do: nil

  def close_contests(closest, %{councils: councils, wards: wards}, within) do
    verb = if closest.complete, do: "beat", else: "leads"

    votes =
      case closest.margin_votes do
        nil -> ""
        1 -> ", 1 vote"
        margin_votes -> ", #{format_number(margin_votes)} votes"
      end

    "The tightest council contest is in #{closest.name}, where #{closest.leader} #{verb} " <>
      "#{closest.runner_up} by #{precise_points(closest.margin)}#{votes}. " <>
      "#{String.capitalize(count(councils, "council"))} and #{count(wards, "ward")} " <>
      "are within #{within} points."
  end

  defp precise_points(value),
    do: :erlang.float_to_binary(abs(value) / 1, decimals: 2) <> " points"

  defp final?(snapshot),
    do:
      is_integer(snapshot.voting_districts_expected) and
        snapshot.voting_districts_expected > 0 and
        snapshot.voting_districts_complete >= snapshot.voting_districts_expected

  defp counted_share(snapshot),
    do: format_progress(snapshot.voting_districts_complete, snapshot.voting_districts_expected)

  defp count(number, singular, plural \\ nil)
  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(number, singular, plural), do: "#{number} #{plural || singular <> "s"}"

  defp percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  defp points(value), do: :erlang.float_to_binary(abs(value) / 1, decimals: 1) <> " points"
end
