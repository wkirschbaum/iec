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
      |> Enum.map(fn ring ->
        ring |> Enum.map(&project/1) |> Enum.dedup() |> simplify(tolerance)
      end)
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

  @doc "A longitude and latitude in the shared plane, as `{x, y}`."
  def project_point(longitude, latitude), do: project([longitude, latitude])

  @doc """
  The rings of a path written by `to_svg/2`, as lists of `{x, y}` points: the path read
  back, for testing whether a point lies inside it.
  """
  def rings(path) do
    ~r/M(-?\d+) (-?\d+)l([^z]*)z/
    |> Regex.scan(path, capture: :all_but_first)
    |> Enum.map(fn [x, y, moves] ->
      start = {String.to_integer(x), String.to_integer(y)}

      moves
      |> String.split(" ", trim: true)
      |> Enum.map(&String.to_integer/1)
      |> Enum.chunk_every(2)
      |> Enum.scan(start, fn [delta_x, delta_y], {previous_x, previous_y} ->
        {previous_x + delta_x, previous_y + delta_y}
      end)
      |> then(&[start | &1])
    end)
  end

  @doc """
  Whether a point lies inside a shape's rings (even–odd: a point inside a hole is
  outside).
  """
  def contains?(rings, {x, y}) do
    rings
    |> Enum.map(fn ring -> crossings(ring, x, y) end)
    |> Enum.sum()
    |> rem(2) == 1
  end

  # How many of a ring's edges a ray from the point towards +x crosses.
  defp crossings(ring, x, y) do
    ring
    |> Enum.zip(tl(ring) ++ [hd(ring)])
    |> Enum.count(fn {{x1, y1}, {x2, y2}} ->
      y1 > y != y2 > y and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1
    end)
  end

  @doc """
  The area of a GeoJSON polygon or multipolygon in square map units (holes subtracted),
  measured before simplification.
  """
  def area(%{"type" => "Polygon", "coordinates" => rings}), do: polygon_area(rings)

  def area(%{"type" => "MultiPolygon", "coordinates" => polygons}),
    do: polygons |> Enum.map(&polygon_area/1) |> Enum.sum()

  def area(_geometry), do: 0

  defp polygon_area([outer | holes]) do
    ring_area = fn ring -> ring |> Enum.map(&project/1) |> shoelace() end
    max(ring_area.(outer) - (holes |> Enum.map(ring_area) |> Enum.sum()), 0)
  end

  defp polygon_area([]), do: 0

  defp shoelace(points) do
    points
    |> Enum.zip(tl(points) ++ [hd(points)])
    |> Enum.reduce(0, fn {{x1, y1}, {x2, y2}}, sum -> sum + x1 * y2 - x2 * y1 end)
    |> abs()
    |> div(2)
  end

  defp project([longitude, latitude | _altitude]) do
    {round((longitude - @west) * @longitude_scale * @units_per_degree),
     round((@north - latitude) * @units_per_degree)}
  end

  # "M x y" then relative "l" moves, closed with "z".
  defp ring_path([{x, y} | rest]) do
    {moves, _last} =
      Enum.map_reduce(rest, {x, y}, fn {next_x, next_y}, {previous_x, previous_y} ->
        {"#{next_x - previous_x} #{next_y - previous_y}", {next_x, next_y}}
      end)

    "M#{x} #{y}l" <> Enum.join(moves, " ") <> "z"
  end

  # Douglas–Peucker simplification of a closed ring, keeping its first and last point.
  defp simplify(points, tolerance) when length(points) < 4 or tolerance <= 0, do: points

  defp simplify(points, tolerance) do
    points
    |> List.to_tuple()
    |> then(fn tuple -> douglas_peucker(tuple, 0, tuple_size(tuple) - 1, tolerance) end)
    |> then(&[hd(points) | &1])
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
    delta_x = x2 - x1
    delta_y = y2 - y1
    length_squared = delta_x * delta_x + delta_y * delta_y

    if length_squared == 0 do
      :math.sqrt((x - x1) ** 2 + (y - y1) ** 2)
    else
      fraction = max(0.0, min(1.0, ((x - x1) * delta_x + (y - y1) * delta_y) / length_squared))
      :math.sqrt((x - (x1 + fraction * delta_x)) ** 2 + (y - (y1 + fraction * delta_y)) ** 2)
    end
  end
end
