defmodule IecWeb.WardSearch do
  @moduledoc """
  What the ward search shows for a query (`Iec.Wards.search/2`): the wards found by
  number, towns and suburbs, the best municipality with every ward to pick from, the
  other municipalities, and what Enter opens.

  The index and every ward's result are built once per data change and shared by every
  searcher, so a keystroke costs a search in memory and nothing in the database.
  """
  use IecWeb, :verified_routes

  import IecWeb.ResultsComponents, only: [format_number: 1]

  alias Iec.{Maps, Results, Wards}
  alias IecWeb.{TableRows, Trends, WardNames}

  @doc "Everything the search page shows for `query`."
  def results(query, parties) do
    index = Iec.Cache.fetch(:ward_index, &Wards.build_index/0)

    ward_results =
      Iec.Cache.fetch(:ward_results, fn ->
        Maps.list_area_results(:ward, Enum.map(index.wards, & &1.ward_id))
      end)

    found = Wards.search(query, index)
    ward_rows = TableRows.ward_result_rows(found.wards, ward_results, parties)
    place_rows = TableRows.ward_result_rows(found.places, ward_results, parties)
    {best, others} = split_best(found.municipalities)

    # A place that matches better than any municipality ("Meadowridge") is the answer.
    places_first =
      ward_rows == [] and place_rows != [] and
        (is_nil(best) or hd(place_rows).score > best.score)

    %{
      start_hint: start_hint(length(index.wards), length(index.places)),
      metros: metros(index),
      ward_rows: ward_rows,
      place_rows: place_rows,
      places_first: places_first,
      more_wards: found.more,
      ward_number: found.ward_number,
      best: best && best |> with_council() |> with_ward_picker(ward_results, found.ward_number),
      others: Enum.map(others, &with_council/1),
      top: top(ward_rows, place_rows, best, places_first),
      nothing: query != "" and ward_rows == [] and place_rows == [] and is_nil(best)
    }
  end

  defp split_best([]), do: {nil, []}
  defp split_best([best | others]), do: {best, others}

  defp start_hint(ward_total, 0),
    do:
      "Or the IEC's eight-digit ward ID. Every one of the #{format_number(ward_total)} wards has a page."

  defp start_hint(ward_total, place_total) do
    "Or the IEC's eight-digit ward ID. Every one of the #{format_number(ward_total)} wards " <>
      "has a page, findable from #{format_number(place_total)} towns and suburbs."
  end

  # Who leads the council and how the leader has done across elections, the place the
  # municipality was found by (`found_by`), and its code (which finds it alone).
  defp with_council(municipality) do
    council = municipality_results()[municipality.municipality_id]
    leader = council && council.leader

    Map.merge(municipality, %{
      leader_id: leader,
      leader_share: council && council.share,
      points:
        (leader && get_in(municipality_points(), [municipality.municipality_id, leader])) || [],
      found_by: municipality.place && title_case(municipality.place),
      code: municipality_code(municipality.municipality_name)
    })
  end

  # Every ward of the best municipality with its name and result, those starting with
  # the number typed picked out.
  defp with_ward_picker(municipality, ward_results, ward_number) do
    names = WardNames.all()

    wards =
      Enum.map(municipality.wards, fn ward ->
        Map.merge(ward, %{
          name: names[ward.ward_id],
          result: ward_results[ward.ward_id],
          current: ward_number == ward.ward_number,
          dimmed: ward_number != nil and not starts_with?(ward.ward_number, ward_number)
        })
      end)

    %{municipality | wards: wards}
  end

  defp starts_with?(number, prefix),
    do: String.starts_with?(Integer.to_string(number), Integer.to_string(prefix))

  defp municipality_results do
    Iec.Cache.fetch(:municipality_results, fn ->
      Maps.list_area_results(:municipality, Map.keys(Results.list_area_names(:municipality)))
    end)
  end

  defp municipality_points do
    Iec.Cache.fetch(:municipality_points, fn ->
      Trends.points_by_area(Results.list_snapshots_by_election(:municipality))
    end)
  end

  # What Enter opens: the first ward found by number, else the best place or municipality.
  defp top([ward | _rest], _places, _best, _places_first), do: ward_target(ward)
  defp top([], [place | _rest], _best, true), do: ward_target(place)

  defp top([], _places, %{} = best, _places_first),
    do: %{path: ~p"/municipalities/#{best.municipality_id}", label: best.municipality_name}

  defp top([], [place | _rest], nil, _places_first), do: ward_target(place)
  defp top([], [], nil, _places_first), do: nil

  defp ward_target(%{place_name: place_name} = place) when is_binary(place_name) do
    %{
      path: ~p"/wards/#{place.ward_id}",
      label: "#{place_name}: Ward #{place.ward_number} · #{place.municipality_name}"
    }
  end

  defp ward_target(ward) do
    %{
      path: ~p"/wards/#{ward.ward_id}",
      label: "#{WardNames.label(ward.ward_id, ward.ward_number)} · #{ward.municipality_name}"
    }
  end

  # The metros: their codes are three letters ("TSH - City of Tshwane").
  defp metros(index) do
    index.municipalities
    |> Enum.filter(&(&1.municipality_name =~ ~r/^[A-Z]{3} - /))
    |> Enum.map(fn municipality ->
      [code, name] = String.split(municipality.municipality_name, " - ", parts: 2)
      %{code: code, name: String.replace_prefix(name, "City of ", "")}
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  # "port elizabeth" → "Port Elizabeth".
  defp title_case(place), do: place |> String.split() |> Enum.map_join(" ", &String.capitalize/1)

  # "TSH - City of Tshwane" → "TSH", which matches that municipality alone.
  defp municipality_code(name), do: name |> String.split(" - ") |> List.first()
end
