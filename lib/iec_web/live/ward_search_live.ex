defmodule IecWeb.WardSearchLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias IecWeb.{LiveUpdates, WardSearch}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results, :parties]}

  # Searches to try, shown before anything is typed.
  @examples ["Pretoria 45", "Durban", "Cape Town 115", "Gqeberha", "Stellenbosch 3"]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Find your ward",
       examples: @examples,
       query: ""
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:query, String.trim(params["q"] || "")) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, push_patch(socket, to: search_path(String.trim(query)), replace: true)}
  end

  # Enter opens the best match. The query is searched afresh: the page may not have
  # caught up with the last keystrokes yet.
  def handle_event("open", %{"q" => query}, socket) do
    socket = socket |> assign(:query, String.trim(query)) |> refresh()

    case socket.assigns.top do
      nil -> {:noreply, push_patch(socket, to: search_path(socket.assigns.query))}
      top -> {:noreply, push_navigate(socket, to: top.path)}
    end
  end

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp search_path(""), do: ~p"/wards"
  defp search_path(query), do: ~p"/wards?#{[q: query]}"

  @impl LiveUpdates
  def refresh(socket),
    do: assign(socket, WardSearch.results(socket.assigns.query, socket.assigns.parties))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:wards}
      feed_status={@feed_status}
      count_progress={@count_progress}
    >
      <.page_header eyebrow="Wards" title="Find your ward">
        <:lede>
          Type your suburb or town, or your municipality and ward number. Spelling needn't
          be exact.
        </:lede>
      </.page_header>

      <div id="ward-finder" phx-hook=".ResultKeys" class="space-y-10">
        <.search_form query={@query} top={@top} start_hint={@start_hint} />

        <%!-- Before anything is typed: the big cities and a few searches to try. --%>
        <section :if={@query == ""} id="ward-search-start" class="space-y-6">
          <div class="space-y-3">
            <h2 class="eyebrow">Metros</h2>
            <ul class="flex flex-wrap gap-2">
              <li :for={metro <- @metros}>
                <.link
                  patch={search_path(metro.code)}
                  data-result
                  class="inline-flex min-h-10 items-center rounded-full border border-base-300 bg-base-100 px-4 text-sm transition-all hover:-translate-y-px hover:border-base-content/30 hover:shadow-sm focus-visible:outline-2 focus-visible:outline-primary active:scale-95"
                >
                  {metro.name}
                </.link>
              </li>
            </ul>
          </div>
          <div class="space-y-3">
            <h2 class="eyebrow">Try</h2>
            <ul class="flex flex-wrap gap-2">
              <li :for={example <- @examples}>
                <.link
                  patch={search_path(example)}
                  data-result
                  class="inline-flex min-h-10 items-center gap-1.5 rounded-full px-3 text-sm text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content focus-visible:outline-2 focus-visible:outline-primary"
                >
                  <.icon name="hero-magnifying-glass-micro" class="size-3.5 opacity-50" />
                  {example}
                </.link>
              </li>
            </ul>
          </div>
        </section>

        <p :if={@nothing} id="ward-search-empty" class="panel max-w-2xl p-6 text-base-content/70">
          Nothing matches “{@query}”. Try your suburb or town, or your municipality and ward
          number. Street names are not known here; the IEC (elections.org.za) can tell you
          your ward from your address or ID number.
        </p>

        <%!-- Wards found by number or id, the first as the answer. --%>
        <section :if={@ward_rows != []} id="ward-results" class="space-y-3">
          <.ward_card row={hd(@ward_rows)} parties={@parties} />
          <ul :if={length(@ward_rows) > 1} class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={row <- tl(@ward_rows)}>
              <.ward_row id={"ward-results-#{row.ward_id}"} row={row} parties={@parties} />
            </li>
          </ul>
          <p :if={@more_wards > 0} class="text-sm text-base-content/60">
            {@more_wards} more wards have that number: add a municipality or city to narrow it down.
          </p>
        </section>

        <%!-- A town or suburb that matches better than any municipality, as the answer. --%>
        <section :if={@places_first} id="place-results" class="space-y-3">
          <.ward_card row={hd(@place_rows)} parties={@parties} />
          <ul :if={length(@place_rows) > 1} class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={{row, index} <- Enum.with_index(tl(@place_rows), 1)}>
              <.ward_row id={"place-results-#{index}"} row={row} parties={@parties} />
            </li>
          </ul>
          <.place_note />
        </section>

        <.best_municipality
          :if={@best}
          municipality={@best}
          ward_number={@ward_number}
          parties={@parties}
        />

        <section
          :if={not @places_first and @place_rows != []}
          id="place-results"
          class="space-y-3"
        >
          <h2 class="eyebrow">Towns and suburbs</h2>
          <ul class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={{row, index} <- Enum.with_index(@place_rows)}>
              <.ward_row id={"place-results-#{index}"} row={row} parties={@parties} />
            </li>
          </ul>
          <.place_note />
        </section>

        <section :if={@others != []} id="ward-search-others" class="space-y-3">
          <h2 class="eyebrow">Also matching</h2>
          <ul class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={municipality <- @others} class="flex items-center">
              <.municipality_row municipality={municipality} parties={@parties} />
              <.link
                patch={search_path(municipality.code)}
                class="mr-2 inline-flex min-h-10 shrink-0 items-center rounded-full px-3 text-sm text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
                aria-label={"Wards of #{municipality.municipality_name}"}
              >
                Wards
              </.link>
            </li>
          </ul>
        </section>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ResultKeys">
          // ↓ from the search box moves into the results, ↑ ↓ move between them, Escape
          // goes back to typing. Enter on a result opens it, as on any link.
          export default {
            mounted() {
              this.el.addEventListener("keydown", (event) => {
                const input = this.el.querySelector("#ward-search-input")
                const results = [...this.el.querySelectorAll("[data-result]")]
                const index = results.indexOf(document.activeElement)

                if (event.key === "ArrowDown") {
                  const next = document.activeElement === input ? results[0] : results[index + 1]
                  if (next) { event.preventDefault(); next.focus() }
                } else if (event.key === "ArrowUp" && index >= 0) {
                  event.preventDefault()
                  index === 0 ? input.focus() : results[index - 1].focus()
                } else if (event.key === "Escape" && document.activeElement !== input) {
                  input.focus()
                }
              })
            }
          }
        </script>
      </div>
    </Layouts.app>
    """
  end

  attr :query, :string, required: true
  attr :top, :map, default: nil, doc: "what Enter opens"
  attr :start_hint, :string, required: true

  # The search box, and under it what Enter opens.
  defp search_form(assigns) do
    ~H"""
    <form
      id="ward-search"
      phx-change="search"
      phx-submit="open"
      class="sticky top-[4.5rem] z-20 -mx-4 space-y-2 bg-base-100/85 px-4 py-2 backdrop-blur-xl sm:static sm:mx-0 sm:max-w-2xl sm:bg-transparent sm:p-0 sm:backdrop-blur-none"
    >
      <label class="input input-lg flex w-full items-center gap-3 rounded-full shadow-sm">
        <.icon name="hero-magnifying-glass" class="size-5 shrink-0 opacity-50" />
        <input
          id="ward-search-input"
          phx-mounted={JS.focus()}
          type="search"
          name="q"
          value={@query}
          placeholder="e.g. Pretoria 45"
          autocomplete="off"
          autocorrect="off"
          autocapitalize="off"
          spellcheck="false"
          enterkeyhint="go"
          autofocus
          phx-debounce="150"
          aria-label="Municipality or city, and ward number"
          aria-describedby="ward-search-hint"
          class="min-w-0 grow"
        />
      </label>
      <p id="ward-search-hint" class="min-h-5 px-5 text-sm text-base-content/60">
        <span :if={@top}>
          <span class="hidden sm:inline"><kbd class="kbd kbd-xs">Enter</kbd> opens</span>
          <span class="sm:hidden">Top match:</span>
          <span class="font-medium text-base-content">{@top.label}</span>
          <span class="hidden sm:inline">· <kbd class="kbd kbd-xs">↓</kbd> to pick another</span>
        </span>
        <span :if={is_nil(@top) and @query == ""}>{@start_hint}</span>
      </p>
    </form>
    """
  end

  # Places are points: a suburb can reach past the ward its point is in.
  defp place_note(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      A suburb can reach into neighbouring wards: each ward's page shows the wards around
      it. Town and suburb names: © OpenStreetMap contributors.
    </p>
    """
  end

  attr :municipality, :map, required: true, doc: "from IecWeb.WardSearch, with its wards"
  attr :ward_number, :integer, default: nil, doc: "the ward number typed"
  attr :parties, :map, required: true

  # The best municipality, with every ward to pick from.
  defp best_municipality(assigns) do
    ~H"""
    <section id={"ward-search-municipality-#{@municipality.municipality_id}"} class="space-y-4">
      <div class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300 pb-3">
        <div class="min-w-0 space-y-1">
          <p :if={@municipality.found_by} class="text-sm text-base-content/60">
            {@municipality.found_by} is in
          </p>
          <h2 class="text-xl font-medium sm:text-2xl">
            <.link
              navigate={~p"/municipalities/#{@municipality.municipality_id}"}
              data-result
              class="hover:underline focus-visible:outline-2 focus-visible:outline-primary"
            >
              <.highlighted segments={@municipality.segments} />
            </.link>
          </h2>
          <p class="flex flex-wrap items-center gap-x-2 text-sm text-base-content/60">
            {@municipality.province_name} · {length(@municipality.wards)} wards
            <span :if={@municipality.leader_id} class="inline-flex items-center gap-1.5">
              ·
              <.party_label parties={@parties} party_result={%{party_id: @municipality.leader_id}} />
              {format_percentage(@municipality.leader_share)}
            </span>
          </p>
        </div>
        <div class="flex items-center gap-4">
          <.leader_sparkline municipality={@municipality} parties={@parties} class="h-8 w-20" />
          <.link
            navigate={~p"/municipalities/#{@municipality.municipality_id}"}
            class="btn min-h-10 rounded-full"
          >
            Dashboard <.icon name="hero-arrow-right-micro" class="size-4" />
          </.link>
        </div>
      </div>
      <p :if={@ward_number} class="text-sm text-base-content/60">
        Wards starting {@ward_number} are picked out.
      </p>
      <p :if={is_nil(@ward_number)} class="text-sm text-base-content/60">
        Pick your ward, or type its number.
      </p>
      <ul class="grid grid-cols-[repeat(auto-fill,minmax(4rem,1fr))] gap-2">
        <li :for={ward <- @municipality.wards}>
          <.ward_chip
            ward_id={ward.ward_id}
            ward_number={ward.ward_number}
            name={ward.name}
            result={ward.result}
            parties={@parties}
            current={ward.current}
            dimmed={ward.dimmed}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :municipality, :map, required: true
  attr :parties, :map, required: true
  attr :class, :string, required: true

  # How the council's leader has done across elections.
  defp leader_sparkline(assigns) do
    ~H"""
    <.sparkline
      :if={@municipality.leader_id}
      points={@municipality.points}
      colour={party_colour(@parties, %{party_id: @municipality.leader_id})}
      label={party_abbreviation(@parties, %{party_id: @municipality.leader_id})}
      class={@class}
    />
    """
  end

  attr :municipality, :map, required: true
  attr :parties, :map, required: true

  # Another municipality matching: where it is, and who leads it.
  defp municipality_row(assigns) do
    ~H"""
    <.link_row
      navigate={~p"/municipalities/#{@municipality.municipality_id}"}
      data-result
      chevron={false}
      class="min-h-14 min-w-0 flex-1 py-2.5"
    >
      <span class="min-w-0 flex-1">
        <span class="block truncate font-medium">
          <.highlighted segments={@municipality.segments} />
        </span>
        <span class="block text-xs text-base-content/55">
          {municipality_detail(@municipality)}
        </span>
      </span>
      <.leader_sparkline
        municipality={@municipality}
        parties={@parties}
        class="hidden h-6 w-14 sm:block"
      />
      <span :if={@municipality.leader_id} class="w-24 text-right text-sm">
        <.party_label
          parties={@parties}
          party_result={%{party_id: @municipality.leader_id}}
          link={false}
        />
      </span>
    </.link_row>
    """
  end

  attr :row, :map, required: true
  attr :parties, :map, required: true

  # The answer: the first ward found, large.
  defp ward_card(assigns) do
    ~H"""
    <.link_card
      navigate={~p"/wards/#{@row.ward_id}"}
      id={"ward-results-#{@row.ward_id}"}
      data-result
      class="flex items-stretch gap-4 overflow-hidden p-0"
    >
      <span
        class="w-1.5 shrink-0"
        style={"background-color: #{leader_colour(@parties, @row.leader_id)}"}
      />
      <span class="flex min-w-0 flex-1 flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 pr-4">
        <span class="min-w-0">
          <span class="eyebrow block">
            {in_municipality(@row[:place_name], @row.municipality_name)}
          </span>
          <span class="block font-serif text-3xl leading-tight">Ward {@row.ward_number}</span>
          <span :if={@row.ward_name} class="block text-sm text-base-content/70">
            {@row.ward_name}
          </span>
        </span>
        <span class="flex items-center gap-6">
          <span class="space-y-1">
            <span class="eyebrow block">{status_label(@row.status)}</span>
            <.party_or_dash parties={@parties} party_id={@row.leader_id} link={false} />
          </span>
          <span :if={@row.share} class="text-right">
            <span class="block font-serif text-2xl tabular-nums leading-none">
              {format_percentage(@row.share)}
            </span>
            <span :if={@row.margin} class="text-xs tabular-nums text-base-content/55">
              lead {format_points(@row.margin)}
            </span>
          </span>
          <.icon
            name="hero-chevron-right"
            class="size-5 text-base-content/30 transition-transform group-hover:translate-x-0.5"
          />
        </span>
      </span>
    </.link_card>
    """
  end

  # "Pretoria · Gauteng · 105 wards": the place it was found by, if any, and where it is.
  defp municipality_detail(municipality) do
    Enum.join(
      List.wrap(municipality.found_by) ++
        [municipality.province_name, "#{length(municipality.wards)} wards"],
      " · "
    )
  end

  # "Meadowridge · CPT - City of Cape Town", or the municipality alone.
  defp in_municipality(place, municipality_name),
    do: Enum.join(List.wrap(place) ++ [municipality_name], " · ")

  defp leader_colour(_parties, nil), do: "var(--color-base-300)"
  defp leader_colour(parties, party_id), do: party_colour(parties, %{party_id: party_id})

  defp status_label("declared"), do: "Won by"
  defp status_label("counting"), do: "Leading"
  defp status_label(_no_results), do: "No results yet"

  attr :id, :string, required: true
  attr :row, :map, required: true, doc: "a ward, or a town or suburb with its ward"
  attr :parties, :map, required: true

  defp ward_row(assigns) do
    ~H"""
    <.link_row navigate={~p"/wards/#{@row.ward_id}"} id={@id} data-result class="min-h-14 py-2.5">
      <span class="min-w-0 flex-1">
        <span :if={@row[:place_name]} class="block truncate font-medium">
          <.highlighted segments={@row.segments} />
          <span :if={@row.place} class="text-xs font-normal text-base-content/55">
            ({@row.place})
          </span>
        </span>
        <span :if={is_nil(@row[:place_name])} class="block truncate font-medium">
          <.ward_label number={@row.ward_number} name={@row.ward_name} />
        </span>
        <span class="block truncate text-xs text-base-content/55">
          {in_municipality(@row[:place_name] && "Ward #{@row.ward_number}", @row.municipality_name)}
        </span>
      </span>
      <.party_or_dash parties={@parties} party_id={@row.leader_id} link={false} empty="no results" />
      <span class="w-16 text-right text-sm tabular-nums">{format_percentage(@row.share)}</span>
    </.link_row>
    """
  end
end
