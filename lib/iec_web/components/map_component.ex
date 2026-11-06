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

  Options: `province_id` / `municipality_id` to show one area's children, or `area_ids`
  to show just those areas; `highlight` (an area id) to outline one area; and `mode`:

    * `:leader` – the leader's colour, stronger for a bigger share; hatched while
      counting, grey before any results
    * `:flips` – only areas whose leader differs from the previous election are coloured
    * `:margin` – close contests: stronger the narrower the lead over the runner-up
    * `:spoilt` – spoilt ballots as a share of ballots cast (provinces and municipalities;
      the IEC publishes no ward figure)

  Outlines stream in once; after that each refresh (`refreshed_at` changing) re-sends
  only the areas whose colour changed, so the map never flickers or reloads.
  """
  use IecWeb, :live_component

  import IecWeb.ResultsComponents,
    only: [format_number: 1, party_abbreviation: 2, party_colour: 2]

  alias Iec.Maps

  @share_bands [{70, 1.0}, {60, 0.85}, {50, 0.7}, {40, 0.55}, {0, 0.4}]

  # The figure-based modes shade one colour in bands: `{label, from, below, opacity}`, a
  # value falling in a band when `from <= value < below` (nil is open-ended).
  @metric_colour "var(--color-primary)"

  @metric_bands %{
    margin: [
      {"under 2 pts", nil, 2, 1.0},
      {"2–5", 2, 5, 0.75},
      {"5–10", 5, 10, 0.5},
      {"10–20", 10, 20, 0.3},
      {"20+ pts", 20, nil, 0.15}
    ],
    spoilt: [
      {"under 1%", nil, 1, 0.15},
      {"1–1.5%", 1, 1.5, 0.3},
      {"1.5–2%", 1.5, 2, 0.5},
      {"2–3%", 2, 3, 0.75},
      {"3%+", 3, nil, 1.0}
    ]
  }

  @doc "The modes a level can be shown in: spoilt ballots are not published per ward."
  def modes(:ward), do: [:leader, :flips, :margin]
  def modes(_level), do: [:leader, :flips, :margin, :spoilt]

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(shape_key: nil, styles: %{}, summary: []) |> stream(:areas, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.put_new(assigns, :mode, :leader))
    socket = assign(socket, :connected, connected?(socket))

    shape_key =
      {socket.assigns.level, assigns[:province_id], assigns[:municipality_id], assigns[:area_ids]}

    socket =
      if socket.assigns.shape_key == shape_key do
        socket
      else
        boundaries =
          Maps.list_boundaries(socket.assigns.level,
            province_id: assigns[:province_id],
            municipality_id: assigns[:municipality_id],
            area_ids: assigns[:area_ids]
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

    highlighted = Enum.find(socket.assigns.boundaries, &(&1.area_id == assigns[:highlight]))

    {:ok, socket |> assign(:highlight_path, highlighted && highlighted.path) |> restyle()}
  end

  # Colours every area and streams only those whose look changed since the last render.
  defp restyle(socket) do
    %{boundaries: boundaries, level: level, mode: mode, parties: parties} = socket.assigns

    # Shared by every viewer of the same map, computed once per data change.
    results =
      Iec.Cache.fetch({:area_results, socket.assigns.shape_key}, fn ->
        Maps.list_area_results(level, Enum.map(boundaries, & &1.area_id))
      end)

    areas =
      for boundary <- boundaries do
        result = results[boundary.area_id]

        Map.merge(
          area_style(result, mode, parties),
          area_details(boundary, result, mode, parties, overview?(socket.assigns))
        )
      end

    changed =
      Enum.reject(areas, fn area -> socket.assigns.styles[area.id] == style_key(area) end)

    socket
    |> assign(
      styles: Map.new(areas, &{&1.id, style_key(&1)}),
      hatch_colours: areas |> Enum.filter(& &1.hatched) |> Enum.map(& &1.colour) |> Enum.uniq(),
      summary: summary(results, mode, boundaries)
    )
    |> then(fn socket ->
      # Shapes go out once, over the live connection, not also in the first HTML.
      if connected?(socket),
        do: Enum.reduce(changed, socket, &stream_insert(&2, :areas, &1)),
        else: socket
    end)
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

  defp area_style(result, mode, _parties) when mode in [:margin, :spoilt] do
    case metric_band(mode, metric_value(result, mode)) do
      nil ->
        %{colour: nil, opacity: 1.0, hatched: false}

      {_label, _from, _below, opacity} ->
        %{colour: @metric_colour, opacity: opacity, hatched: result.status == :counting}
    end
  end

  defp share_opacity(nil), do: 0.4

  defp share_opacity(share),
    do: Enum.find_value(@share_bands, fn {floor, opacity} -> share >= floor && opacity end)

  defp metric_value(result, :margin), do: result.margin
  defp metric_value(result, :spoilt), do: result.spoilt_share

  defp metric_band(_mode, nil), do: nil

  defp metric_band(mode, value) do
    Enum.find(@metric_bands[mode], fn {_label, from, below, _opacity} ->
      (is_nil(from) or value >= from) and (is_nil(below) or value < below)
    end)
  end

  # Every ward in the country at once uses the coarser outlines.
  defp overview?(assigns),
    do:
      assigns.level == :ward and is_nil(assigns[:province_id]) and
        is_nil(assigns[:municipality_id]) and is_nil(assigns[:area_ids])

  defp area_details(boundary, result, mode, parties, overview) do
    title =
      if is_nil(result) or result.status == :none,
        do: "#{boundary.name}: no results yet",
        else: "#{boundary.name}: #{describe(result, mode, parties)}#{counting_note(result)}"

    %{
      id: "#{boundary.level}-#{boundary.area_id}",
      path: if(overview, do: boundary.overview_path || boundary.path, else: boundary.path),
      title: title,
      href: area_href(boundary)
    }
  end

  defp counting_note(%{status: :counting}), do: " (counting)"
  defp counting_note(_result), do: ""

  # The tooltip's figures for an area with results, in the terms of the mode.
  defp describe(result, :margin, parties) do
    leader = party_abbreviation(parties, %{party_id: result.leader})

    case result do
      %{runner_up: nil} ->
        "#{leader} unopposed so far"

      # Ward shares count every ballot; the seat goes by the ward ballot alone.
      %{margin: nil, runner_up: runner_up} ->
        "#{leader} won the ward ballot; " <>
          "#{party_abbreviation(parties, %{party_id: runner_up})} has the bigger share"

      %{runner_up: runner_up} ->
        votes = if result.margin_votes, do: " · #{format_number(result.margin_votes)} votes"

        "#{leader} ahead of #{party_abbreviation(parties, %{party_id: runner_up})} " <>
          "by #{decimal(result.margin)} pts#{votes}"
    end
  end

  defp describe(%{spoilt_share: nil}, :spoilt, _parties), do: "no spoilt ballot figure"

  defp describe(result, :spoilt, _parties) do
    "#{decimal(result.spoilt_share)}% spoilt · " <>
      "#{format_number(result.spoilt_votes)} of #{format_number(result.ballots)} ballots"
  end

  defp describe(result, _leader_or_flips, parties) do
    leader = party_abbreviation(parties, %{party_id: result.leader})
    share = if result.share, do: " #{decimal(result.share)}%", else: ""

    previous =
      if result.previous_leader,
        do: " · #{party_abbreviation(parties, %{party_id: result.previous_leader})} before",
        else: ""

    "#{leader}#{share}#{previous}"
  end

  defp decimal(value), do: :erlang.float_to_binary(value / 1, decimals: 1)

  defp area_href(%{level: :province, area_id: id}), do: ~p"/provinces/#{id}"
  defp area_href(%{level: :municipality, area_id: id}), do: ~p"/municipalities/#{id}"

  defp area_href(%{level: :ward, area_id: id}), do: ~p"/wards/#{id}"

  # Legend counts: areas led (or, for flips, won from someone else) per party, or for
  # the figure-based modes, areas per band.
  defp summary(results, mode, boundaries) do
    reporting = results |> Map.values() |> Enum.reject(&(&1.status == :none))

    %{
      title: legend_title(mode),
      parties: party_counts(reporting, mode),
      bands: band_counts(reporting, mode),
      empty_label: if(mode in [:margin, :spoilt], do: "no figure yet", else: "no results yet"),
      total: length(boundaries),
      reporting: length(reporting),
      complete: Enum.count(reporting, &(&1.status == :complete))
    }
  end

  defp legend_title(:leader), do: "Leading party"
  defp legend_title(:flips), do: "New leader since #{Iec.Results.previous_year()}"
  defp legend_title(:margin), do: "Lead over the runner-up"
  defp legend_title(:spoilt), do: "Spoilt ballots, share of ballots cast"

  defp party_counts(results, mode) when mode in [:leader, :flips] do
    results
    |> Enum.filter(fn result ->
      mode == :leader or (result.previous_leader && result.leader != result.previous_leader)
    end)
    |> Enum.frequencies_by(& &1.leader)
    |> Enum.sort_by(fn {_party_id, count} -> -count end)
  end

  defp party_counts(_results, _mode), do: []

  defp band_counts(results, mode) when mode in [:margin, :spoilt] do
    counts = Enum.frequencies_by(results, &metric_band(mode, metric_value(&1, mode)))

    for {label, _from, _below, opacity} = band <- @metric_bands[mode],
        do: %{label: label, opacity: opacity, count: Map.get(counts, band, 0)}
  end

  defp band_counts(_results, _mode), do: nil

  defp fill(%{colour: nil}, _component_id), do: "var(--color-base-300)"
  defp fill(%{colour: :unchanged}, _component_id), do: "var(--color-base-200)"

  defp fill(%{hatched: true, colour: colour}, component_id),
    do: "url(##{hatch_id(component_id, colour)})"

  defp fill(%{colour: colour}, _component_id), do: colour

  # Colours are hex codes or CSS variables; keep only what an id may hold.
  defp hatch_id(component_id, colour),
    do: "#{component_id}-hatch-#{String.replace(colour, ~r/[^A-Za-z0-9]/, "")}"

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
      <div class="relative overflow-hidden rounded-box border border-base-300 bg-base-100">
        <svg
          viewBox={@view_box}
          class="h-auto max-h-[70vh] w-full touch-none select-none"
          role="img"
          aria-label="Election map"
          phx-hook=".ElectionMap"
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
          <%!-- The hook pans and zooms by setting this group's transform. --%>
          <g id={"#{@id}-viewport"} phx-mounted={JS.ignore_attributes(["transform"])}>
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
            <path
              :if={@highlight_path}
              id={"#{@id}-highlight"}
              d={@highlight_path}
              fill="none"
              class="pointer-events-none stroke-base-content [stroke-width:2.5] [vector-effect:non-scaling-stroke]"
            />
            <path
              id={"#{@id}-hover"}
              fill="none"
              style="opacity: 0"
              phx-mounted={JS.ignore_attributes(["d", "style"])}
              class="pointer-events-none stroke-base-content [stroke-width:1.5] [vector-effect:non-scaling-stroke] transition-opacity duration-150"
            />
          </g>
        </svg>

        <div class="absolute right-2 top-2 flex flex-col overflow-hidden rounded-box border border-base-300 bg-base-100/90 shadow-sm backdrop-blur">
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square rounded-none"
            aria-label="Zoom in"
            phx-click={JS.dispatch("map:zoom", to: "##{@id}-svg", detail: %{by: 1.6})}
          >
            <.icon name="hero-plus-micro" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square rounded-none border-t border-base-300"
            aria-label="Zoom out"
            phx-click={JS.dispatch("map:zoom", to: "##{@id}-svg", detail: %{by: 1 / 1.6})}
          >
            <.icon name="hero-minus-micro" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square rounded-none border-t border-base-300"
            aria-label="Show everything"
            phx-click={JS.dispatch("map:reset", to: "##{@id}-svg")}
          >
            <.icon name="hero-arrows-pointing-out-micro" class="size-4" />
          </button>
        </div>

        <p
          :if={not @connected}
          class="pointer-events-none absolute inset-0 grid place-items-center text-sm opacity-60"
        >
          Loading map…
        </p>

        <p class="pointer-events-none absolute bottom-2 left-3 text-xs opacity-50">
          Scroll or pinch to zoom · drag to move · click to open
        </p>

        <div
          id={"#{@id}-tooltip"}
          class="pointer-events-none absolute z-10 hidden max-w-xs rounded-box border border-base-300 bg-base-100/95 px-3 py-1.5 text-sm shadow-lg backdrop-blur"
        />
      </div>

      <.legend summary={@summary} mode={@mode} parties={@parties} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ElectionMap">
        // Pan and zoom by transforming the viewport group (the server owns the viewBox),
        // a tooltip that follows the pointer, and click-through that ignores drags.
        export default {
          mounted() {
            this.viewport = this.el.querySelector("g[id$='-viewport']")
            this.tooltip = document.getElementById(this.el.id.replace(/-svg$/, "-tooltip"))
            this.viewBox = this.el.getAttribute("viewBox")
            this.pointers = new Map()
            this.reset()

            this.el.addEventListener("wheel", (event) => {
              event.preventDefault()
              this.zoomAt(this.point(event), Math.exp(-event.deltaY * 0.0015))
            }, {passive: false})

            this.el.addEventListener("pointerdown", (event) => {
              // Capturing the pointer sends the click to the svg, not to the area, so the
              // pressed area is remembered here.
              this.pressed = event.target.closest && event.target.closest("[data-href]")
              this.pointerType = event.pointerType
              this.el.setPointerCapture(event.pointerId)
              this.pointers.set(event.pointerId, this.point(event))
              this.moved = 0
            })

            this.el.addEventListener("pointermove", (event) => {
              if (this.pointers.has(event.pointerId)) {
                const previous = this.pointers.get(event.pointerId)
                const current = this.point(event)

                if (this.pointers.size === 2) {
                  const [other] = [...this.pointers].filter(([id]) => id !== event.pointerId).map(([, p]) => p)
                  const before = Math.hypot(previous.x - other.x, previous.y - other.y)
                  const after = Math.hypot(current.x - other.x, current.y - other.y)
                  if (before > 0) this.zoomAt({x: (current.x + other.x) / 2, y: (current.y + other.y) / 2}, after / before)
                } else {
                  this.panBy(current.x - previous.x, current.y - previous.y)
                }

                this.moved += Math.hypot(current.x - previous.x, current.y - previous.y)
                this.pointers.set(event.pointerId, this.point(event))
                this.hideTooltip()
                return
              }
              if (event.pointerType !== "touch") this.showTooltip(event.target, event)
            })

            const release = (event) => this.pointers.delete(event.pointerId)
            this.el.addEventListener("pointerup", release)
            this.el.addEventListener("pointercancel", release)
            this.el.addEventListener("pointerleave", () => {
              if (this.pointerType !== "touch") this.hideTooltip()
            })

            // A click opens the area; a drag never does. On a touch screen the first tap
            // shows what the area is, and a second tap on it opens it.
            this.el.addEventListener("click", (event) => {
              const area = this.pressed
              this.pressed = null
              if (this.moved >= this.dragThreshold()) return
              if (!area) { this.hideTooltip(); return }

              if (this.pointerType === "touch" && this.selected !== area) {
                this.showTooltip(area, event, "Tap again to open")
                this.selected = area
              } else {
                this.outline(area)
                this.js().navigate(area.dataset.href)
              }
            })

            this.el.addEventListener("map:zoom", (event) => {
              const box = this.el.viewBox.baseVal
              this.zoomAt({x: box.x + box.width / 2, y: box.y + box.height / 2}, event.detail.by)
            })
            this.el.addEventListener("map:reset", () => this.reset())
          },

          // A new area was framed (another province, level or municipality): start over.
          updated() {
            if (this.el.getAttribute("viewBox") !== this.viewBox) {
              this.viewBox = this.el.getAttribute("viewBox")
              this.reset()
            }
          },

          // Pointer position in viewBox units, before the viewport transform.
          point(event) {
            const point = this.el.createSVGPoint()
            point.x = event.clientX
            point.y = event.clientY
            return point.matrixTransform(this.el.getScreenCTM().inverse())
          },

          dragThreshold() {
            return this.el.viewBox.baseVal.width / 150
          },

          reset() {
            this.scale = 1
            this.x = 0
            this.y = 0
            this.apply()
          },

          zoomAt(point, factor) {
            const scale = Math.min(Math.max(this.scale * factor, 1), 60)
            const ratio = scale / this.scale
            this.x = point.x - (point.x - this.x) * ratio
            this.y = point.y - (point.y - this.y) * ratio
            this.scale = scale
            if (scale === 1) { this.x = 0; this.y = 0 }
            this.apply()
          },

          panBy(dx, dy) {
            if (this.scale === 1) return
            this.x += dx
            this.y += dy
            this.apply()
          },

          apply() {
            this.viewport.setAttribute("transform", `translate(${this.x} ${this.y}) scale(${this.scale})`)
          },

          // The hovered or tapped area, outlined above its neighbours.
          outline(area) {
            const hover = this.el.querySelector("path[id$='-hover']")
            if (!hover) return
            if (area) hover.setAttribute("d", area.getAttribute("d"))
            hover.style.opacity = area ? 1 : 0
          },

          hideTooltip() {
            this.tooltip.classList.add("hidden")
            this.selected = null
            this.outline(null)
          },

          showTooltip(target, event, hint) {
            const area = target && target.closest && target.closest("[data-tip]")
            const tip = area && area.dataset.tip
            if (!tip) { this.hideTooltip(); return }
            this.outline(area)
            const bounds = this.el.parentElement.getBoundingClientRect()
            this.tooltip.textContent = tip
            if (hint) {
              const line = document.createElement("span")
              line.className = "mt-0.5 block text-xs font-medium text-primary"
              line.textContent = hint
              this.tooltip.appendChild(line)
            }
            this.tooltip.classList.remove("hidden")
            const left = Math.min(event.clientX - bounds.left + 14, bounds.width - this.tooltip.offsetWidth - 4)
            this.tooltip.style.left = `${Math.max(left, 4)}px`
            this.tooltip.style.top = `${event.clientY - bounds.top + 14}px`
          }
        }
      </script>
    </div>
    """
  end

  attr :summary, :map, required: true
  attr :mode, :atom, required: true
  attr :parties, :map, required: true

  defp legend(assigns) do
    ~H"""
    <div class="panel grid gap-4 p-4 text-sm sm:grid-cols-[1fr_auto]">
      <div class="space-y-2">
        <div class="text-xs font-medium uppercase tracking-wider opacity-60">
          {@summary.title}
        </div>
        <p :if={is_nil(@summary.bands) and @summary.parties == []} class="opacity-60">None yet.</p>
        <div :if={@summary.bands} id="map-bands" class="flex max-w-md">
          <div :for={band <- @summary.bands} class="flex-1 text-center">
            <div
              class="h-2.5 bg-primary first:rounded-l last:rounded-r"
              style={"opacity: #{band.opacity}"}
            />
            <div class="mt-0.5 text-xs tabular-nums opacity-70">{band.label}</div>
            <div class="text-xs font-medium tabular-nums">{band.count}</div>
          </div>
        </div>
        <div class="flex flex-wrap gap-x-4 gap-y-1.5">
          <span :for={{party_id, count} <- @summary.parties} class="inline-flex items-center gap-1.5">
            <span
              class="inline-block size-3.5 rounded-sm"
              style={"background-color: #{party_colour(@parties, %{party_id: party_id})}"}
            />
            {party_abbreviation(@parties, %{party_id: party_id})}
            <span class="tabular-nums opacity-60">{count}</span>
          </span>
        </div>
      </div>

      <div class="space-y-2 sm:min-w-64">
        <div :if={@mode == :leader} class="space-y-1">
          <div class="text-xs font-medium uppercase tracking-wider opacity-60">Leader's share</div>
          <div class="flex">
            <div :for={{label, opacity} <- share_legend()} class="flex-1 text-center">
              <div class="h-2.5 bg-base-content first:rounded-l" style={"opacity: #{opacity}"} />
              <div class="mt-0.5 text-xs tabular-nums opacity-70">{label}</div>
            </div>
          </div>
        </div>
        <div class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block size-3.5 rounded-sm border border-base-300 bg-[repeating-linear-gradient(45deg,currentColor_0_2px,transparent_2px_5px)] opacity-70" />
            counting
          </span>
          <span :if={@mode == :flips} class="inline-flex items-center gap-1.5">
            <span class="inline-block size-3.5 rounded-sm border border-base-300 bg-base-200" />
            same leader
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="inline-block size-3.5 rounded-sm bg-base-300" />
            {@summary.empty_label}
          </span>
        </div>
        <div class="text-xs tabular-nums opacity-70">
          {@summary.reporting} of {@summary.total} reporting · {@summary.complete} final
        </div>
      </div>
    </div>
    """
  end

  defp share_legend do
    @share_bands
    |> Enum.reverse()
    |> Enum.map(fn
      {0, opacity} -> {"<40%", opacity}
      {70, opacity} -> {"70%+", opacity}
      {floor, opacity} -> {"#{floor}%", opacity}
    end)
  end
end
