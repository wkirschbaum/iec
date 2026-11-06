defmodule IecWeb.Trends do
  @moduledoc """
  Builds the trend charts' data from an area's snapshot in every election
  (`Iec.Results.list_snapshots_by_election/2`): one series per party that mattered, the
  vote totals, and a sentence on the long-run story.
  """

  import IecWeb.ResultsComponents, only: [party_abbreviation: 2, party_colour: 2]

  @doc """
  `%{years, series, max, step}`: a series per party for `field` of its results
  (`:vote_percentage`, `:total_seats_won`, `:majority_won`), keeping the `limit` parties
  with the highest peak, among those reaching `threshold` in some election.
  """
  def series(snapshots_by_year, field, parties, options \\ []) do
    limit = Keyword.get(options, :limit, 7)
    threshold = Keyword.get(options, :threshold, 0)
    years = Enum.map(snapshots_by_year, &elem(&1, 0))

    values =
      for {year, snapshot} <- snapshots_by_year,
          party <- snapshot.party_results,
          party.party_id >= 0,
          value = Map.get(party, field),
          is_number(value),
          reduce: %{} do
        values -> Map.update(values, party.party_id, [{year, value}], &(&1 ++ [{year, value}]))
      end

    series =
      values
      |> Enum.map(fn {party_id, points} ->
        %{
          party_id: party_id,
          label: party_abbreviation(parties, %{party_id: party_id}),
          colour: party_colour(parties, %{party_id: party_id}),
          points: points,
          peak: points |> Enum.map(&elem(&1, 1)) |> Enum.max()
        }
      end)
      |> Enum.filter(&(&1.peak >= threshold and &1.peak > 0))
      |> Enum.sort_by(&(-&1.peak))
      |> Enum.take(limit)

    {max, step} = series |> Enum.map(& &1.peak) |> Enum.max(fn -> 0 end) |> nice_scale()
    %{years: years, series: series, max: max, step: step}
  end

  @doc "`[%{year, registered, votes_cast}]`, oldest first."
  def totals(snapshots_by_year) do
    for {year, snapshot} <- snapshots_by_year do
      %{year: year, registered: snapshot.registered_voters, votes_cast: snapshot.total_votes_cast}
    end
  end

  @doc """
  A sentence on the long-run story of the biggest parties now: where each started and
  where it stands, e.g. "Since 2000 the ANC has gone from 59.4% to 31.9%, …".
  """
  def summary(%{years: [first_year | _] = years, series: series}, live_year, final) do
    latest =
      series
      |> Enum.filter(fn line -> List.keymember?(line.points, live_year, 0) end)
      |> Enum.sort_by(fn line -> -value_in(line, live_year) end)
      |> Enum.take(3)

    clauses =
      Enum.map(latest, fn line ->
        {start_year, start} = hd(line.points)
        now = percent(value_in(line, live_year))

        cond do
          start_year == live_year -> "#{line.label}, new this time, #{has(final)} #{now}"
          start_year == first_year -> "#{line.label} from #{percent(start)} to #{now}"
          true -> "#{line.label} from #{percent(start)} in #{start_year} to #{now}"
        end
      end)

    case clauses do
      [] -> nil
      clauses -> "Since #{first_year}: #{join(clauses)}#{if final, do: ".", else: " so far."}"
    end
    |> then(fn sentence -> if length(years) > 1, do: sentence end)
  end

  def summary(_trend, _live_year, _final), do: nil

  defp value_in(line, year), do: line.points |> List.keyfind(year, 0) |> elem(1)

  defp has(true), do: "won"
  defp has(false), do: "has"

  defp join([only]), do: only

  defp join(clauses),
    do: Enum.join(Enum.drop(clauses, -1), "; ") <> "; and " <> List.last(clauses)

  defp percent(value), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  # The chart's top and gridline step: round steps (1, 2, 2.5 or 5 times a power of ten)
  # giving at most five gridlines above the peak.
  defp nice_scale(peak) when peak <= 0, do: {1, 1}

  defp nice_scale(peak) do
    magnitude = :math.pow(10, Float.floor(:math.log10(peak)))

    step =
      [1, 2, 2.5, 5, 10]
      |> Enum.map(&(&1 * magnitude))
      |> Enum.find(fn step -> peak / step <= 5 end)

    {Float.ceil(peak / step) * step, step}
  end
end
