defmodule Iec.Places do
  @moduledoc """
  Towns and suburbs, so a ward can be found by where people live ("Meadowridge"): the IEC
  names wards by municipality and number only.

  The names come from OpenStreetMap (© OpenStreetMap contributors, ODbL; credited on the
  about page), read once through the Overpass API (`Iec.Places.Overpass`, which keeps to
  its rate limits) and stored; searching never calls it. Each place is a point (a mapped
  area counts at its centre), placed in the live ward whose outline holds it. A suburb
  larger than its point can reach into neighbouring wards, which the ward page shows
  beside it.
  """

  import Ecto.Query

  require Logger

  alias Iec.{Maps, Repo, Results}
  alias Iec.Maps.{Boundary, Geometry}
  alias Iec.Places.{Overpass, Place}

  # Other names people may type, from these OpenStreetMap tags.
  @alternate_name_tags ~w(name:en alt_name old_name official_name short_name)

  @doc """
  Reads the places and places each in its ward, once: skipped when places are stored,
  and until the ward outlines are. Returns `{:ok, count}` or `{:error, reason}`.
  """
  def import_places do
    cond do
      Repo.exists?(Place) ->
        {:ok, 0}

      not Repo.exists?(from boundary in Boundary, where: boundary.level == :ward) ->
        {:error, :no_ward_outlines}

      true ->
        with {:ok, elements} <- Overpass.fetch_places() do
          {:ok, elements |> parse() |> store()}
        end
    end
  end

  @doc """
  Repeats `import_places/0` until it succeeds, a few hours apart, so a busy Overpass is
  asked again much later rather than pressed.
  """
  def complete_import(attempts_left \\ 12) do
    case import_places() do
      {:ok, _count} ->
        :ok

      {:error, reason} when attempts_left > 1 ->
        Logger.warning("Places: not imported (#{inspect(reason)}); trying again in 2 hours")
        Process.sleep(:timer.hours(2))
        complete_import(attempts_left - 1)

      {:error, reason} ->
        Logger.warning("Places: not imported (#{inspect(reason)}); giving up until restart")
        :error
    end
  end

  @doc """
  Places from Overpass elements: `%{osm_type, osm_id, name, alternate_names, kind,
  population, latitude, longitude}`, one per element with a name and a position.
  """
  def parse(elements) do
    for %{"type" => type, "id" => id, "tags" => %{"name" => name} = tags} = element <- elements,
        {latitude, longitude} <- [position(element)] do
      %{
        osm_type: type,
        osm_id: id,
        name: name,
        alternate_names: alternate_names(tags, name),
        kind: tags["place"],
        population: population(tags["population"]),
        latitude: latitude,
        longitude: longitude
      }
    end
    |> Enum.uniq_by(&{&1.osm_type, &1.osm_id})
  end

  # A node has its position; a mapped area has its centre.
  defp position(%{"lat" => latitude, "lon" => longitude}), do: {latitude, longitude}

  defp position(%{"center" => %{"lat" => latitude, "lon" => longitude}}),
    do: {latitude, longitude}

  defp position(_element), do: nil

  # In the Latin alphabet, as people would type them; OpenStreetMap separates several
  # with semicolons.
  defp alternate_names(tags, name) do
    @alternate_name_tags
    |> Enum.flat_map(&String.split(tags[&1] || "", ";", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.match?(&1, ~r/^[\p{Latin}\p{N} '’.-]{3,}$/u))
    |> Enum.reject(&(&1 == name))
    |> Enum.uniq()
  end

  defp population(nil), do: nil

  defp population(text) do
    case Integer.parse(String.replace(text, ~r/[\s,]/, "")) do
      {population, _rest} when population > 0 -> population
      _not_a_number -> nil
    end
  end

  # Places each place in the ward holding it, and stores them all.
  defp store(places) do
    wards = ward_shapes()
    now = DateTime.utc_now()

    rows =
      for place <- places do
        point = Geometry.project_point(place.longitude, place.latitude)
        ward = Enum.find(wards, &inside?(&1, point))

        Map.merge(place, %{
          ward_id: ward && ward.area_id,
          municipality_id: ward && ward.municipality_id,
          inserted_at: now
        })
      end

    rows
    |> Enum.chunk_every(2_000)
    |> Enum.each(
      &Repo.insert_all(Place, &1, on_conflict: :nothing, conflict_target: [:osm_type, :osm_id])
    )

    Logger.info("Places: #{length(rows)} stored, #{Enum.count(rows, & &1.ward_id)} in a ward")
    Results.broadcast(:places_imported)
    length(rows)
  end

  defp ward_shapes do
    for boundary <- Maps.list_boundaries(:ward) do
      %{
        area_id: boundary.area_id,
        municipality_id: boundary.municipality_id,
        box: {boundary.min_x, boundary.min_y, boundary.max_x, boundary.max_y},
        rings: Geometry.rings(boundary.path)
      }
    end
  end

  defp inside?(%{box: {min_x, min_y, max_x, max_y}} = ward, {x, y} = point),
    do:
      x >= min_x and x <= max_x and y >= min_y and y <= max_y and
        Geometry.contains?(ward.rings, point)

  @doc """
  Every place in a live ward, for the search:
  `%{name, alternate_names, kind, population, ward_id, municipality_id}`.
  """
  def list_placed do
    Repo.all(
      from place in Place,
        where: not is_nil(place.ward_id),
        select:
          map(place, [:name, :alternate_names, :kind, :population, :ward_id, :municipality_id])
    )
  end

  @doc "The names of the places in a ward, those with the biggest population first."
  def list_ward_places(ward_id) do
    Repo.all(
      from place in Place,
        where: place.ward_id == ^ward_id,
        order_by: [desc_nulls_last: place.population, asc: place.name],
        select: place.name
    )
    |> Enum.uniq()
  end
end
