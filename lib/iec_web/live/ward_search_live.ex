defmodule IecWeb.WardSearchLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Maps, Results, Wards}
  alias IecWeb.{TableRows, Trends}

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  # Searches to try, shown before anything is typed.
  @examples ["Pretoria 45", "Durban", "Cape Town 115", "Gqeberha", "Stellenbosch 3"]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Find your ward",
       previous_year: Results.previous_year(),
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

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    %{query: query, parties: parties} = socket.assigns

    # Built once per data change and shared by every searcher, so a keystroke costs a
    # search in memory and nothing in the database.
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

    assign(socket,
      ward_total: length(index.wards),
      place_total: length(index.places),
      metros: metros(index),
      ward_rows: ward_rows,
      place_rows: place_rows,
      places_first: places_first,
      more_wards: found.more,
      ward_number: found.ward_number,
      # Only the wards on show, not every ward's result in every searcher's page.
      ward_results: Map.take(ward_results, Enum.map((best && best.wards) || [], & &1.ward_id)),
      best: best && with_council(best),
      others: Enum.map(others, &with_council/1),
      top: top(ward_rows, place_rows, best, places_first),
      nothing: query != "" and ward_rows == [] and place_rows == [] and is_nil(best)
    )
  end

  defp split_best([]), do: {nil, []}
  defp split_best([best | others]), do: {best, others}

  # Who leads the council and how the leader has done across elections.
  defp with_council(municipality) do
    council = municipality_results()[municipality.municipality_id]
    leader = council && council.leader

    Map.merge(municipality, %{
      leader_id: leader,
      leader_share: council && council.share,
      points:
        (leader && get_in(municipality_points(), [municipality.municipality_id, leader])) || []
    })
  end

  defp municipality_results do
    Iec.Cache.fetch(:municipality_results, fn ->
      Maps.list_area_results(:municipality, Map.keys(Results.list_area_names(:municipality)))
    end)
  end

  defp municipality_points do
    Iec.Cache.fetch(:municipality_points, fn ->
      Map.new(Results.list_snapshots_by_election(:municipality), fn {id, snapshots} ->
        {id, Trends.points_by_party(snapshots)}
      end)
    end)
  end

  # What Enter opens: the first ward found by number, else the best place or municipality.
  defp top([ward | _rest], _places, _best, _places_first), do: ward_target(ward)
  defp top([], [place | _rest], _best, true), do: ward_target(place)

  defp top([], _places, %{} = best, _places_first),
    do: %{path: ~p"/municipalities/#{best.municipality_id}", label: best.municipality_name}

  defp top([], [place | _rest], nil, _places_first), do: ward_target(place)
  defp top([], [], nil, _places_first), do: nil

  defp ward_target(ward) do
    place = if ward[:place_name], do: "#{ward.place_name}: ", else: ""

    %{
      path: ~p"/wards/#{ward.ward_id}",
      label: "#{place}Ward #{ward.ward_number} · #{ward.municipality_name}"
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
            <span :if={is_nil(@top) and @query == ""}>
              Or the IEC's eight-digit ward ID. Every one of the {format_number(@ward_total)} wards has a page{if @place_total >
                                                                                                                    0,
                                                                                                                  do:
                                                                                                                    ", findable from #{format_number(@place_total)} towns and suburbs"}.
            </span>
          </p>
        </form>

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

        <%!-- The best municipality, with every ward to pick from. --%>
        <section
          :if={@best}
          id={"ward-search-municipality-#{@best.municipality_id}"}
          class="space-y-4"
        >
          <div class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300 pb-3">
            <div class="min-w-0 space-y-1">
              <p :if={@best.place} class="text-sm text-base-content/60">
                {title_case(@best.place)} is in
              </p>
              <h2 class="text-xl font-medium sm:text-2xl">
                <.link
                  navigate={~p"/municipalities/#{@best.municipality_id}"}
                  data-result
                  class="hover:underline focus-visible:outline-2 focus-visible:outline-primary"
                >
                  <.highlighted segments={@best.segments} />
                </.link>
              </h2>
              <p class="flex flex-wrap items-center gap-x-2 text-sm text-base-content/60">
                {@best.province_name} · {length(@best.wards)} wards
                <span :if={@best.leader_id} class="inline-flex items-center gap-1.5">
                  · <.party_label parties={@parties} party_result={%{party_id: @best.leader_id}} />
                  {format_percentage(@best.leader_share)}
                </span>
              </p>
            </div>
            <div class="flex items-center gap-4">
              <.sparkline
                :if={@best.leader_id}
                points={@best.points}
                colour={party_colour(@parties, %{party_id: @best.leader_id})}
                label={party_abbreviation(@parties, %{party_id: @best.leader_id})}
                class="h-8 w-20"
              />
              <.link
                navigate={~p"/municipalities/#{@best.municipality_id}"}
                class="btn min-h-10 rounded-full"
              >
                Dashboard <.icon name="hero-arrow-right-micro" class="size-4" />
              </.link>
            </div>
          </div>
          <p class="text-sm text-base-content/60">
            {if @ward_number,
              do: "Wards starting #{@ward_number} are picked out.",
              else: "Pick your ward, or type its number."}
          </p>
          <ul class="grid grid-cols-[repeat(auto-fill,minmax(4rem,1fr))] gap-2">
            <li :for={ward <- @best.wards}>
              <.ward_chip
                ward_id={ward.ward_id}
                ward_number={ward.ward_number}
                result={@ward_results[ward.ward_id]}
                parties={@parties}
                current={@ward_number == ward.ward_number}
                dimmed={
                  @ward_number != nil and
                    not String.starts_with?(
                      Integer.to_string(ward.ward_number),
                      Integer.to_string(@ward_number)
                    )
                }
              />
            </li>
          </ul>
        </section>

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
              <.link
                navigate={~p"/municipalities/#{municipality.municipality_id}"}
                data-result
                class="group flex min-h-14 min-w-0 flex-1 items-center gap-3 px-4 py-2.5 transition-colors hover:bg-base-200/70 focus-visible:bg-base-200 focus-visible:outline-none"
              >
                <span class="min-w-0 flex-1">
                  <span class="block truncate font-medium">
                    <.highlighted segments={municipality.segments} />
                  </span>
                  <span class="block text-xs text-base-content/55">
                    {if municipality.place, do: "#{title_case(municipality.place)} · "}{municipality.province_name} · {length(
                      municipality.wards
                    )} wards
                  </span>
                </span>
                <.sparkline
                  :if={municipality.leader_id}
                  points={municipality.points}
                  colour={party_colour(@parties, %{party_id: municipality.leader_id})}
                  label={party_abbreviation(@parties, %{party_id: municipality.leader_id})}
                  class="hidden h-6 w-14 sm:block"
                />
                <span :if={municipality.leader_id} class="w-24 text-right text-sm">
                  <.party_label
                    parties={@parties}
                    party_result={%{party_id: municipality.leader_id}}
                    link={false}
                  />
                </span>
              </.link>
              <.link
                patch={search_path(municipality_code(municipality.municipality_name))}
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

  # "port elizabeth" → "Port Elizabeth".
  defp title_case(place), do: place |> String.split() |> Enum.map_join(" ", &String.capitalize/1)

  # Places are points: a suburb can reach past the ward its point is in.
  defp place_note(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60">
      A suburb can reach into neighbouring wards: each ward's page shows the wards around
      it. Town and suburb names: © OpenStreetMap contributors.
    </p>
    """
  end

  # "TSH - City of Tshwane" → "TSH", which matches that municipality alone.
  defp municipality_code(name), do: name |> String.split(" - ") |> List.first()

  attr :row, :map, required: true
  attr :parties, :map, required: true

  # The answer: the first ward found, large.
  defp ward_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/wards/#{@row.ward_id}"}
      id={"ward-results-#{@row.ward_id}"}
      data-result
      class="panel group flex items-stretch gap-4 overflow-hidden p-0 transition-all hover:-translate-y-0.5 hover:shadow-lg focus-visible:outline-2 focus-visible:outline-primary"
    >
      <span
        class="w-1.5 shrink-0"
        style={"background-color: #{if @row.leader_id, do: party_colour(@parties, %{party_id: @row.leader_id}), else: "var(--color-base-300)"}"}
      />
      <span class="flex min-w-0 flex-1 flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 pr-4">
        <span class="min-w-0">
          <span class="eyebrow block">
            {if @row[:place_name], do: "#{@row.place_name} · "}{@row.municipality_name}
          </span>
          <span class="block font-serif text-3xl leading-tight">Ward {@row.ward_number}</span>
        </span>
        <span class="flex items-center gap-6">
          <span class="space-y-1">
            <span class="eyebrow block">
              {case @row.status do
                "declared" -> "Won by"
                "counting" -> "Leading"
                _no_results -> "No results yet"
              end}
            </span>
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
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :row, :map, required: true, doc: "a ward, or a town or suburb with its ward"
  attr :parties, :map, required: true

  defp ward_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/wards/#{@row.ward_id}"}
      id={@id}
      data-result
      class="group flex min-h-14 items-center gap-3 px-4 py-2.5 transition-colors hover:bg-base-200/70 focus-visible:bg-base-200 focus-visible:outline-none"
    >
      <span class="min-w-0 flex-1">
        <span :if={@row[:place_name]} class="block truncate font-medium">
          <.highlighted segments={@row.segments} />
          <span :if={@row.place} class="text-xs font-normal text-base-content/55">
            ({@row.place})
          </span>
        </span>
        <span :if={is_nil(@row[:place_name])} class="block font-medium">Ward {@row.ward_number}</span>
        <span class="block truncate text-xs text-base-content/55">
          {if @row[:place_name], do: "Ward #{@row.ward_number} · "}{@row.municipality_name}
        </span>
      </span>
      <.party_or_dash parties={@parties} party_id={@row.leader_id} link={false} empty="no results" />
      <span class="w-16 text-right text-sm tabular-nums">{format_percentage(@row.share)}</span>
      <.icon
        name="hero-chevron-right-micro"
        class="size-4 text-base-content/30 transition-transform group-hover:translate-x-0.5"
      />
    </.link>
    """
  end
end
