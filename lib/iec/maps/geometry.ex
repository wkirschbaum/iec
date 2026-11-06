defmodule Iec.Maps.Geometry do
  @moduledoc """
  Turns GeoJSON (WGS84 longitude/latitude) into compact SVG path data.

  Every shape is projected into one shared plane, so a province, its municipalities and
  their wards line up and any of them can be framed with an SVG `viewBox`:

    * x: longitude east of 16°E, scaled by cos(29°S) so shapes keep their proportions at
      South Africa's latitude
    * y: degrees south of 22°S
    * 1 000 units per degree, rounded to whole units (about 110 m)

  Rings are simplified with Douglas–Peucker at a tolerance chosen per level, written as
  relative path commands, and dropped when they shrink to nothing.
  """

  @units_per_degree 1_000
  @west 16.0
  @north -22.0
  @longitude_scale :math.cos(29 * :math.pi() / 180)

  @doc """
  Converts a GeoJSON geometry into `{path, {min_x, min_y, max_x, max_y}}`, or nil when
  nothing is left after simplification.
  """
  def to_svg(%{"type" => "Polygon", "coordinates" => rings}, tolerance),
    do: rings_to_svg(rings, tolerance)

  def to_svg(%{"type" => "MultiPolygon", "coordinates" => polygons}, tolerance),
    do: polygons |> Enum.concat() |> rings_to_svg(tolerance)

  def to_svg(_geometry, _tolerance), do: nil

  defp rings_to_svg(rings, tolerance) do
    rings =
      rings
      |> Enum.map(fn ring -> ring |> Enum.map(&project/1) |> dedupe() |> simplify(tolerance) end)
      |> Enum.filter(&(length(&1) >= 4))

    case rings do
      [] ->
        nil

      rings ->
        points = Enum.concat(rings)
        {min_x, max_x} = points |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        {min_y, max_y} = points |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
        {Enum.map_join(rings, &ring_path/1), {min_x, min_y, max_x, max_y}}
    end
  end

  defp project([longitude, latitude | _altitude]) do
    {round((longitude - @west) * @longitude_scale * @units_per_degree),
     round((@north - latitude) * @units_per_degree)}
  end

  defp dedupe(points), do: Enum.dedup(points)

  # "M x y" then relative "l" moves, closed with "z".
  defp ring_path([{x, y} | rest]) do
    {moves, _last} =
      Enum.map_reduce(rest, {x, y}, fn {next_x, next_y}, {previous_x, previous_y} ->
        {"#{next_x - previous_x} #{next_y - previous_y}", {next_x, next_y}}
      end)

    "M#{x} #{y}l" <> Enum.join(moves, " ") <> "z"
  end

  @doc "Douglas–Peucker simplification of a closed ring, keeping its first and last point."
  def simplify(points, tolerance) when length(points) < 4 or tolerance <= 0, do: points

  def simplify(points, tolerance) do
    points
    |> List.to_tuple()
    |> then(fn tuple -> douglas_peucker(tuple, 0, tuple_size(tuple) - 1, tolerance) end)
    |> then(&[elem(List.to_tuple(points), 0) | &1])
  end

  # Returns the kept points after `first`, up to and including `last`.
  defp douglas_peucker(points, first, last, _tolerance) when last <= first + 1,
    do: if(last > first, do: [elem(points, last)], else: [])

  defp douglas_peucker(points, first, last, tolerance) do
    start = elem(points, first)
    finish = elem(points, last)

    {farthest, distance} =
      Enum.reduce((first + 1)..(last - 1)//1, {first, -1.0}, fn index, {best, best_distance} ->
        distance = distance_to_segment(elem(points, index), start, finish)
        if distance > best_distance, do: {index, distance}, else: {best, best_distance}
      end)

    if distance > tolerance do
      douglas_peucker(points, first, farthest, tolerance) ++
        douglas_peucker(points, farthest, last, tolerance)
    else
      [finish]
    end
  end

  defp distance_to_segment({x, y}, {x1, y1}, {x2, y2}) do
    dx = x2 - x1
    dy = y2 - y1
    length_squared = dx * dx + dy * dy

    if length_squared == 0 do
      :math.sqrt((x - x1) ** 2 + (y - y1) ** 2)
    else
      t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / length_squared))
      :math.sqrt((x - (x1 + t * dx)) ** 2 + (y - (y1 + t * dy)) ** 2)
    end
  end
end
