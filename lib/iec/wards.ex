defmodule Iec.Wards do
  @moduledoc """
  The ward directory, for finding a ward: every live ward with its number, municipality
  and province, and a search over it.

  The IEC names a ward only by its municipality and number (and an eight-digit ward id),
  so that is what a search matches: "Tshwane 45", "EC153 18", "ward 7 Drakenstein" or
  "21503018". It knows no suburbs or street names.
  """

  import Ecto.Query

  alias Iec.Repo
  alias Iec.Results.{Snapshot, Ward}
  alias Iec.Wards.NameMatch

  # Words people put around a ward number that name no municipality ("wyk" is Afrikaans).
  @filler_words ~w(ward wards wyk no nr number)

  # How far below the best match a municipality may score and still be shown.
  @close_enough 0.3

  @doc """
  Every ward of the live election, by municipality and number:
  `%{ward_id, ward_number, municipality_id, municipality_name, province_id, province_name}`.
  A ward whose municipality has no results yet has nil names.
  """
  def list_directory do
    municipalities = area_names(:municipality)
    provinces = area_names(:province)

    Repo.all(from ward in Ward, order_by: ward.id)
    |> Enum.map(fn ward ->
      municipality = municipalities[ward.municipality_id]
      province_id = municipality && municipality.province_id

      %{
        ward_id: ward.id,
        ward_number: ward.ward_number,
        municipality_id: ward.municipality_id,
        municipality_name: municipality && municipality.name,
        province_id: province_id,
        province_name: province_id && provinces[province_id] && provinces[province_id].name
      }
    end)
    |> Enum.sort_by(&{&1.municipality_name || "", &1.ward_number})
  end

  defp area_names(level) do
    Repo.all(
      from snapshot in Snapshot,
        where: snapshot.election == ^Iec.Results.live_year() and snapshot.level == ^level,
        distinct: snapshot.area_id,
        order_by: [asc: snapshot.area_id, desc: snapshot.id],
        select: %{
          id: snapshot.area_id,
          name: snapshot.area_name,
          province_id: snapshot.province_id
        }
    )
    |> Map.new(&{&1.id, &1})
  end

  @doc """
  A directory (`list_directory/0`) made ready to search: `%{wards, municipalities}`, each
  municipality with its wards and its name prepared for matching. Build it once per
  data change and search it on every keystroke.
  """
  def build_index(directory) do
    municipalities =
      directory
      |> Enum.reject(&is_nil(&1.municipality_name))
      |> Enum.group_by(&{&1.municipality_id, &1.municipality_name, &1.province_name})
      |> Enum.map(fn {{id, name, province_name}, wards} ->
        %{
          municipality_id: id,
          municipality_name: name,
          province_name: province_name,
          wards: Enum.sort_by(wards, & &1.ward_number),
          prepared: NameMatch.prepare(name)
        }
      end)

    %{wards: directory, municipalities: municipalities}
  end

  @doc """
  Searches an index (`build_index/1`), forgiving typos in municipality names
  (`Iec.Wards.NameMatch`): `%{municipalities, wards, more, ward_number}`.

    * a ward id (seven digits or more) finds that ward
    * words find municipalities, best match first (at most `:municipalities`, default 8),
      each with its wards, its `score`, the `segments` of its name to highlight, and the
      `place` it was found by ("Pretoria"), if any
    * a ward number finds that ward in the municipalities found, best first, or in every
      municipality without words; `ward_number` is the number typed

  `wards` holds at most `:limit` wards (default 30); `more` counts those left out.
  """
  def search(query, %{wards: directory} = index, options \\ []) do
    limit = Keyword.get(options, :limit, 30)
    municipality_limit = Keyword.get(options, :municipalities, 8)
    {numbers, words} = terms(query)

    case numbers do
      [number | _rest] when number >= 1_000_000 ->
        wards = Enum.filter(directory, &(&1.ward_id == number))
        %{municipalities: [], wards: wards, more: 0, ward_number: nil}

      _ward_numbers ->
        municipalities =
          if words == [], do: [], else: match_municipalities(index.municipalities, words)

        wards =
          cond do
            numbers == [] ->
              []

            words == [] ->
              Enum.filter(directory, &(&1.ward_number in numbers))

            true ->
              Enum.flat_map(
                municipalities,
                &Enum.filter(&1.wards, fn ward -> ward.ward_number in numbers end)
              )
          end

        %{
          municipalities: Enum.take(municipalities, municipality_limit),
          wards: Enum.take(wards, limit),
          more: max(length(wards) - limit, 0),
          ward_number: List.first(numbers)
        }
    end
  end

  defp match_municipalities(municipalities, words) do
    municipalities
    |> Enum.flat_map(fn municipality ->
      case NameMatch.match(municipality.prepared, words) do
        nil -> []
        match -> [municipality |> Map.delete(:prepared) |> Map.merge(match)]
      end
    end)
    |> Enum.sort_by(&{-&1.score, -length(&1.wards), &1.municipality_name})
    |> close_to_best()
  end

  # Much weaker matches than the best are noise ("EC135" when "EC153" matched exactly).
  defp close_to_best([]), do: []

  defp close_to_best([best | _rest] = matches),
    do: Enum.filter(matches, &(&1.score >= best.score - @close_enough))

  # Whole numbers are ward numbers (or a ward id); "EC153" is a municipality code, a word.
  # "ward45" is a ward number too.
  defp terms(query) do
    tokens =
      query
      |> String.replace(~r/\b(ward|wyk)(\d+)\b/iu, "\\1 \\2")
      |> NameMatch.normalise()
      |> String.split(" ", trim: true)
      |> Enum.reject(&(&1 in @filler_words))

    {numbers, words} = Enum.split_with(tokens, &(&1 =~ ~r/^\d+$/))
    {Enum.map(numbers, &String.to_integer/1), NameMatch.words(Enum.join(words, " "))}
  end
end
