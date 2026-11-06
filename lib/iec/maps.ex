defmodule Iec.Maps do
  @moduledoc """
  Election maps: area outlines from the IEC's election map, and how each area is
  coloured by its results.

  Outlines are imported once (`import_boundaries/0`) and stored as SVG path data in one
  shared plane (`Iec.Maps.Geometry`). `list_area_results/2` says who leads each area, by
  how much, whether its count is finished, and who led it in the previous election.
  """

  import Ecto.Query

  require Logger

  alias Iec.Repo
  alias Iec.Results
  alias Iec.Results.{Feed, PartyWardResult}
  alias Iec.Maps.{Boundary, Geometry}

  # File on the IEC's map server, and the simplification tolerance in map units
  # (about 110 m each): coarser for big areas, finer for wards.
  @boundary_files [
    province: {"nationalProvince", 8},
    municipality: {"nationalMunic", 4},
    ward: {"nationalWard", 1}
  ]

  # Coarser ward outlines for showing every ward in the country at once.
  @overview_tolerance 4

  ## Importing

  @doc """
  Imports every outline set not stored yet (the live election's provinces, municipalities
  and wards, and the previous election's wards), then marks the wards redrawn since the
  previous election. The ward files are about 40 MB each, so the first run takes a
  minute; after that it does nothing.
  """
  def import_boundaries do
    live = Feed.live_election()
    previous = Feed.previous_election()

    sets =
      for {level, file_and_tolerance} <- @boundary_files,
          do: {live, level, file_and_tolerance}

    for {election, level, {file, tolerance}} <- sets ++ [{previous, :ward, {"nationalWard", 2}}],
        not imported?(election.year, level) do
      url = Feed.map_url(election, file)

      case Feed.get(url, %{etag: nil, last_modified: nil}, receive_timeout: :timer.minutes(3)) do
        {:ok, %{"features" => features}, _body, _cache} ->
          Repo.delete_all(
            from boundary in Boundary,
              where: boundary.election == ^election.year and boundary.level == ^level
          )

          insert_boundaries(election.year, level, features, tolerance)

        other ->
          Logger.warning("Map outlines: #{url} failed (#{inspect(other)})")
      end
    end

    mark_redrawn_wards(live.year, previous.year)
  end

  # Stored and complete: wards of the live election also need their overview outline.
  defp imported?(year, level) do
    Boundary
    |> where([boundary], boundary.election == ^year and boundary.level == ^level)
    |> where([boundary], not is_nil(boundary.area))
    |> then(fn query ->
      if level == :ward and year == Results.live_year(),
        do: where(query, [boundary], not is_nil(boundary.overview_path)),
        else: query
    end)
    |> Repo.exists?()
  end

  defp insert_boundaries(year, level, features, tolerance) do
    now = DateTime.utc_now()
    municipality_ids = municipality_ids_by_name()

    features
    |> Enum.flat_map(fn %{"properties" => properties, "geometry" => geometry} ->
      case Geometry.to_svg(geometry, tolerance) do
        nil ->
          []

        {path, {min_x, min_y, max_x, max_y}} ->
          overview =
            if level == :ward,
              do:
                with(
                  {overview, _box} <- Geometry.to_svg(geometry, @overview_tolerance),
                  do: overview
                )

          [
            Map.merge(area_attributes(level, properties, municipality_ids), %{
              election: year,
              level: level,
              path: path,
              overview_path: overview,
              area: Geometry.area(geometry),
              min_x: min_x,
              min_y: min_y,
              max_x: max_x,
              max_y: max_y,
              inserted_at: now
            })
          ]
      end
    end)
    |> Enum.uniq_by(& &1.area_id)
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Boundary, &1, on_conflict: :nothing))
  end

  # A ward counts as redrawn when the previous election's ward with its id covers a
  # clearly different area: its area changed by more than about a fifth, or the two
  # bounding boxes overlap by less than 75%. Smaller edits still count as the same ward.
  defp mark_redrawn_wards(live_year, previous_year) do
    previous =
      Repo.all(
        from boundary in Boundary,
          where: boundary.election == ^previous_year and boundary.level == :ward
      )
      |> Map.new(&{&1.area_id, &1})

    redrawn =
      for ward <-
            Repo.all(
              from boundary in Boundary,
                where: boundary.election == ^live_year and boundary.level == :ward
            ),
          before = previous[ward.area_id],
          before != nil and reshaped?(ward, before),
          do: ward.area_id

    Repo.update_all(
      from(boundary in Boundary,
        where: boundary.election == ^live_year and boundary.level == :ward
      ),
      set: [redrawn: false]
    )

    Repo.update_all(
      from(boundary in Boundary,
        where:
          boundary.election == ^live_year and boundary.level == :ward and
            boundary.area_id in ^redrawn
      ),
      set: [redrawn: true]
    )

    :ok
  end

  defp reshaped?(ward, before) do
    area_ratio = if before.area > 0, do: ward.area / before.area, else: 0
    area_ratio < 0.8 or area_ratio > 1.25 or box_overlap(ward, before) < 0.75
  end

  # Intersection over union of two bounding boxes.
  defp box_overlap(first, second) do
    width = min(first.max_x, second.max_x) - max(first.min_x, second.min_x)
    height = min(first.max_y, second.max_y) - max(first.min_y, second.min_y)
    intersection = max(width, 0) * max(height, 0)
    box_area = fn box -> (box.max_x - box.min_x) * (box.max_y - box.min_y) end
    union = box_area.(first) + box_area.(second) - intersection
    if union > 0, do: intersection / union, else: 0
  end

  @doc "Ids of the live election's wards whose outline changed since the previous election."
  def list_redrawn_ward_ids do
    Repo.all(
      from boundary in Boundary,
        where:
          boundary.election == ^Results.live_year() and boundary.level == :ward and
            boundary.redrawn,
        select: boundary.area_id
    )
    |> MapSet.new()
  end

  # The national ward file names each ward's municipality but leaves out its id.
  defp municipality_ids_by_name do
    Repo.all(
      from boundary in Boundary,
        where: boundary.level == :municipality and boundary.election == ^Results.live_year(),
        select: {boundary.name, boundary.area_id}
    )
    |> Map.new()
  end

  defp area_attributes(:province, properties, _municipality_ids) do
    %{
      area_id: properties["ProvinceId"],
      province_id: properties["ProvinceId"],
      name: properties["Province"]
    }
  end

  defp area_attributes(:municipality, properties, _municipality_ids) do
    %{
      area_id: properties["MunicId"],
      province_id: properties["ProvinceId"],
      municipality_id: properties["MunicId"],
      name: properties["Municipali"]
    }
  end

  defp area_attributes(:ward, properties, municipality_ids) do
    %{
      area_id: properties["PklWardID"],
      province_id: properties["ProvincId"] || properties["ProvinceId"],
      municipality_id: properties["MunicId"] || municipality_ids[properties["Municipali"]],
      name: "#{properties["Municipali"]} · ward #{properties["WardNo"]}"
    }
  end

  ## Reading

  @doc """
  The outlines of one level, optionally within a province or municipality.

  Filters: `:province_id`, `:municipality_id`.
  """
  def list_boundaries(level, filters \\ []) do
    Boundary
    |> where([boundary], boundary.level == ^level and boundary.election == ^Results.live_year())
    |> filter_boundaries(filters)
    |> order_by([boundary], boundary.area_id)
    |> Repo.all()
  end

  defp filter_boundaries(query, filters) do
    Enum.reduce(filters, query, fn
      {:province_id, nil}, query -> query
      {:province_id, id}, query -> where(query, [boundary], boundary.province_id == ^id)
      {:municipality_id, nil}, query -> query
      {:municipality_id, id}, query -> where(query, [boundary], boundary.municipality_id == ^id)
      {_other, _value}, query -> query
    end)
  end

  @doc "A viewBox (`\"x y width height\"`) framing every outline, with a small margin."
  def view_box([]), do: "0 0 1000 1000"

  def view_box(boundaries) do
    min_x = boundaries |> Enum.map(& &1.min_x) |> Enum.min()
    min_y = boundaries |> Enum.map(& &1.min_y) |> Enum.min()
    max_x = boundaries |> Enum.map(& &1.max_x) |> Enum.max()
    max_y = boundaries |> Enum.map(& &1.max_y) |> Enum.max()
    margin = round(max(max_x - min_x, max_y - min_y) * 0.02)

    "#{min_x - margin} #{min_y - margin} #{max_x - min_x + 2 * margin} #{max_y - min_y + 2 * margin}"
  end

  @doc """
  Results per area, keyed by area id:
  `%{leader: party_id, share: float, status: :none | :counting | :complete, previous_leader: party_id}`.

  Provinces and municipalities lead by votes in their latest snapshot; wards by the
  followed parties' shares, a declared ward by its winner. Areas without results are
  left out.
  """
  def list_area_results(level, area_ids) when level in [:province, :municipality] do
    previous_leaders =
      Results.list_latest_snapshots(election: Results.previous_year(), level: level)
      |> Map.new(&{&1.area_id, Results.leading_party(&1)})

    for snapshot <- Results.list_latest_snapshots(level: level),
        snapshot.area_id in area_ids,
        leader = Results.leading_party(snapshot),
        into: %{} do
      status =
        cond do
          (snapshot.voting_districts_complete || 0) == 0 -> :none
          snapshot.voting_districts_complete >= snapshot.voting_districts_expected -> :complete
          true -> :counting
        end

      previous = previous_leaders[snapshot.area_id]

      {snapshot.area_id,
       %{
         leader: leader.party_id,
         share: leader.vote_percentage,
         status: status,
         previous_leader: previous && previous.party_id
       }}
    end
  end

  def list_area_results(:ward, ward_ids) do
    leaders = fn year, declared_only ->
      PartyWardResult
      |> where([result], result.election == ^year and result.ward_id in ^ward_ids)
      |> where([result], result.vote_percentage > 0.0 or result.won)
      |> then(&if declared_only, do: where(&1, [result], result.won), else: &1)
      |> distinct([result], result.ward_id)
      |> order_by([result], asc: result.ward_id, desc: result.won, desc: result.vote_percentage)
      |> select([result], {result.ward_id, result})
      |> Repo.all()
      |> Map.new()
    end

    previous = leaders.(Results.previous_year(), true)
    redrawn = list_redrawn_ward_ids()

    for {ward_id, leader} <- leaders.(Results.live_year(), false), into: %{} do
      # A redrawn ward has no like-for-like previous leader.
      previous_leader = if ward_id in redrawn, do: nil, else: previous[ward_id]

      {ward_id,
       %{
         leader: leader.party_id,
         share: leader.vote_percentage,
         status: if(leader.won, do: :complete, else: :counting),
         previous_leader: previous_leader && previous_leader.party_id
       }}
    end
  end
end
