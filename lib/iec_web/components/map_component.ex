defmodule IecWeb.MapComponent do
  @moduledoc """
  A live election map: every area of one level coloured by its leading party.

      <.live_component
        module={IecWeb.MapComponent}
        id="national-map"
        level={:municipality}
        parties={@parties}
        refreshed_at={@refreshed_at}
      />

  Options: `province_id` / `municipality_id` to show one area's children, and `mode`:

    * `:leader` – the leader's colour, stronger for a bigger share; hatched while
      counting, grey before any results
    * `:flips` – only areas whose leader differs from the previous election are coloured

  Outlines stream in once; after that each refresh (`refreshed_at` changing) re-sends
  only the areas whose colour changed, so the map never flickers or reloads.
  """
  use IecWeb, :live_component

  import IecWeb.ResultsComponents, only: [party_abbreviation: 2, party_colour: 2]

  alias Iec.Maps

  @share_bands [{70, 1.0}, {60, 0.85}, {50, 0.7}, {40, 0.55}, {0, 0.4}]

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(shape_key: nil, styles: %{}, summary: []) |> stream(:areas, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.put_new(assigns, :mode, :leader))
    shape_key = {socket.assigns.level, assigns[:province_id], assigns[:municipality_id]}

    socket =
      if socket.assigns.shape_key == shape_key do
        socket
      else
        boundaries =
          Maps.list_boundaries(socket.assigns.level,
            province_id: assigns[:province_id],
            municipality_id: assigns[:municipality_id]
          )

        socket
        |> assign(
          shape_key: shape_key,
          boundaries: boundaries,
          view_box: Maps.view_box(boundaries),
          styles: %{}
        )
        |> stream(:areas, [], reset: true)
      end

    {:ok, restyle(socket)}
  end

  # Colours every area and streams only those whose look changed since the last render.
  defp restyle(socket) do
    %{boundaries: boundaries, level: level, mode: mode, parties: parties} = socket.assigns
    results = Maps.list_area_results(level, Enum.map(boundaries, & &1.area_id))

    areas =
      for boundary <- boundaries do
        result = results[boundary.area_id]
        Map.merge(area_style(result, mode, parties), area_details(boundary, result, parties))
      end

    changed =
      Enum.reject(areas, fn area -> socket.assigns.styles[area.id] == style_key(area) end)

    socket
    |> assign(
      styles: Map.new(areas, &{&1.id, style_key(&1)}),
      hatch_colours: areas |> Enum.filter(& &1.hatched) |> Enum.map(& &1.colour) |> Enum.uniq(),
      summary: summary(results, mode, boundaries)
    )
    |> then(fn socket -> Enum.reduce(changed, socket, &stream_insert(&2, :areas, &1)) end)
  end

  defp style_key(area), do: {area.colour, area.opacity, area.hatched, area.title}

  defp area_style(nil, _mode, _parties), do: %{colour: nil, opacity: 1.0, hatched: false}

  defp area_style(%{status: :none}, _mode, _parties),
    do: %{colour: nil, opacity: 1.0, hatched: false}

  defp area_style(result, :flips, parties) do
    if result.previous_leader && result.leader != result.previous_leader do
      %{
        colour: party_colour(parties, %{party_id: result.leader}),
        opacity: 1.0,
        hatched: result.status == :counting
      }
    else
      %{colour: :unchanged, opacity: 1.0, hatched: false}
    end
  end

  defp area_style(result, :leader, parties) do
    %{
      colour: party_colour(parties, %{party_id: result.leader}),
      opacity: share_opacity(result.share),
      hatched: result.status == :counting
    }
  end

  defp share_opacity(nil), do: 0.4

  defp share_opacity(share),
    do: Enum.find_value(@share_bands, fn {floor, opacity} -> share >= floor && opacity end)

  defp area_details(boundary, result, parties) do
    leader = result && result.leader && party_abbreviation(parties, %{party_id: result.leader})

    previous =
      result && result.previous_leader &&
        party_abbreviation(parties, %{party_id: result.previous_leader})

    title =
      cond do
        is_nil(result) or result.status == :none ->
          "#{boundary.name}: no results yet"

        true ->
          share =
            if result.share,
              do: " #{:erlang.float_to_binary(result.share / 1, decimals: 1)}%",
              else: ""

          counting = if result.status == :counting, do: " (counting)", else: ""
          was = if previous, do: " · #{previous} before", else: ""
          "#{boundary.name}: #{leader}#{share}#{counting}#{was}"
      end

    %{
      id: "#{boundary.level}-#{boundary.area_id}",
      path: boundary.path,
      title: title,
      href: area_href(boundary)
    }
  end

  defp area_href(%{level: :province, area_id: id}), do: ~p"/provinces/#{id}"
  defp area_href(%{level: :municipality, area_id: id}), do: ~p"/municipalities/#{id}"

  defp area_href(%{level: :ward, municipality_id: id, area_id: ward_id}),
    do: ~p"/municipalities/#{id}" <> "#ward-#{ward_id}"

  # Legend counts: areas led (or, for flips, won from someone else) per party.
  defp summary(results, mode, boundaries) do
    results
    |> Map.values()
    |> Enum.reject(&(&1.status == :none))
    |> Enum.filter(fn result ->
      mode == :leader or (result.previous_leader && result.leader != result.previous_leader)
    end)
    |> Enum.frequencies_by(& &1.leader)
    |> Enum.sort_by(fn {_party_id, count} -> -count end)
    |> then(fn counts ->
      %{
        parties: counts,
        total: length(boundaries),
        reporting: Enum.count(results, fn {_id, result} -> result.status != :none end),
        complete: Enum.count(results, fn {_id, result} -> result.status == :complete end)
      }
    end)
  end

  defp fill(%{colour: nil}, _component_id), do: "var(--color-base-300)"
  defp fill(%{colour: :unchanged}, _component_id), do: "var(--color-base-200)"

  defp fill(%{hatched: true, colour: colour}, component_id),
    do: "url(##{hatch_id(component_id, colour)})"

  defp fill(%{colour: colour}, _component_id), do: colour

  defp hatch_id(component_id, colour),
    do: "#{component_id}-hatch-#{String.trim_leading(colour, "#")}"

  # Hatch stripes scale with the framed area so they read the same at every zoom level.
  defp hatch_size(view_box) do
    [_x, _y, width, _height] = view_box |> String.split() |> Enum.map(&String.to_integer/1)
    max(round(width / 160), 1)
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :hatch_size, hatch_size(assigns.view_box))

    ~H"""
    <div id={@id} class="space-y-3">
      <div class="relative">
        <svg
          viewBox={@view_box}
          class="h-auto max-h-[70vh] w-full"
          role="img"
          aria-label="Election map"
          phx-hook=".MapTooltip"
          id={"#{@id}-svg"}
        >
          <defs>
            <pattern
              :for={colour <- @hatch_colours}
              id={hatch_id(@id, colour)}
              width={@hatch_size}
              height={@hatch_size}
              patternUnits="userSpaceOnUse"
              patternTransform="rotate(45)"
            >
              <rect width={@hatch_size} height={@hatch_size} fill={colour} fill-opacity="0.3" />
              <rect width={@hatch_size / 2} height={@hatch_size} fill={colour} />
            </pattern>
          </defs>
          <g
            id={"#{@id}-areas"}
            phx-update="stream"
            class="[&_path]:cursor-pointer [&_path]:stroke-base-100 [&_path]:[stroke-width:0.6] [&_path]:[vector-effect:non-scaling-stroke] [&_path]:transition-[fill-opacity] [&_path]:duration-700 [&_path:hover]:brightness-110 [&_path:hover]:stroke-base-content"
          >
            <path
              :for={{dom_id, area} <- @streams.areas}
              id={dom_id}
              d={area.path}
              fill={fill(area, @id)}
              fill-opacity={area.opacity}
              data-tip={area.title}
              data-href={area.href}
            />
          </g>
        </svg>
        <div
          id={"#{@id}-tooltip"}
          class="pointer-events-none absolute z-10 hidden rounded-box border border-base-300 bg-base-100/95 px-3 py-1.5 text-sm shadow-lg backdrop-blur"
        />
      </div>

      <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
        <span :for={{party_id, count} <- @summary.parties} class="inline-flex items-center gap-1.5">
          <span
            class="inline-block size-3 rounded-sm"
            style={"background-color: #{party_colour(@parties, %{party_id: party_id})}"}
          />
          {party_abbreviation(@parties, %{party_id: party_id})}
          <span class="tabular-nums opacity-60">{count}</span>
        </span>
        <span class="ml-auto inline-flex items-center gap-3 text-xs opacity-70">
          <span :if={@mode == :leader} class="inline-flex items-center gap-1">
            <span class="inline-flex h-3">
              <span
                :for={{_floor, opacity} <- Enum.reverse(share_bands())}
                class="inline-block w-2 bg-base-content"
                style={"opacity: #{opacity}"}
              />
            </span>
            stronger lead
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="inline-block size-3 rounded-sm bg-[repeating-linear-gradient(45deg,currentColor_0_2px,transparent_2px_4px)]" />
            counting
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="inline-block size-3 rounded-sm bg-base-300" /> no results
          </span>
          <span class="tabular-nums">{@summary.complete}/{@summary.total} final</span>
        </span>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".MapTooltip">
        export default {
          mounted() {
            const tooltip = document.getElementById(this.el.id.replace(/-svg$/, "-tooltip"))
            const box = this.el.parentElement

            this.el.addEventListener("pointermove", (event) => {
              const tip = event.target.dataset && event.target.dataset.tip
              if (!tip) { tooltip.classList.add("hidden"); return }
              const bounds = box.getBoundingClientRect()
              tooltip.textContent = tip
              tooltip.classList.remove("hidden")
              const left = Math.min(event.clientX - bounds.left + 14, bounds.width - tooltip.offsetWidth - 4)
              tooltip.style.left = `${Math.max(left, 4)}px`
              tooltip.style.top = `${event.clientY - bounds.top + 14}px`
            })
            this.el.addEventListener("pointerleave", () => tooltip.classList.add("hidden"))
            this.el.addEventListener("click", (event) => {
              const href = event.target.dataset && event.target.dataset.href
              if (href) this.js().navigate(href)
            })
          }
        }
      </script>
    </div>
    """
  end

  defp share_bands, do: @share_bands
end
