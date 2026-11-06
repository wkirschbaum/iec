defmodule IecWeb.MunicipalityLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.{Contests, Maps, Parties, Results}
  alias Iec.Results.Change
  alias IecWeb.{Narrative, TableRows, Trends}

  # Parties shown at first, and how many more each "Show more" adds.
  @page_size 10
  @more 25

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(
       municipality_id: IecWeb.Params.id(id),
       parties_shown: @page_size,
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_event("show_more", %{"table" => "municipality-parties"}, socket),
    do: {:noreply, update(socket, :parties_shown, &(&1 + @more))}

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    assign(socket, Iec.Cache.fetch(cache_key(socket.assigns), fn -> load(socket.assigns) end))
  end

  # Computed once per data change and shared by everyone viewing the same page.
  defp cache_key(assigns), do: {__MODULE__, assigns.municipality_id}

  defp load(%{municipality_id: nil}), do: %{page_title: "Municipality", municipality: nil}

  defp load(assigns) do
    %{
      municipality_id: municipality_id,
      live_year: live_year,
      previous_year: previous_year,
      parties: parties
    } = assigns

    municipality = Results.get_latest_snapshot(:municipality, municipality_id)
    overview = Parties.get_municipality_overview(municipality_id)
    control = Parties.get_council_control([municipality_id])

    previous_municipality =
      Results.get_latest_snapshot(:municipality, municipality_id, election: previous_year)

    # Every followed party from the party files; without them, the province feed's top three.
    party_rows =
      case overview.parties do
        [] -> TableRows.party_rows(municipality, previous_municipality, parties)
        rows -> TableRows.with_party_name(rows, parties, :party_id, :party)
      end

    ward_rows =
      overview.wards
      |> TableRows.with_party_name(parties, :holder, :holder_name)
      |> TableRows.with_party_name(parties, :previous_holder, :previous_holder_name)
      |> IecWeb.WardNames.with_names()

    ward_ids = Enum.map(ward_rows, & &1.ward_id)
    history = Results.list_snapshots_by_election(:municipality, municipality_id)

    closest_wards =
      Contests.list_ward_leads(live_year, ward_ids)
      |> Enum.filter(fn {_ward_id, lead} ->
        lead.margin != nil and (lead.declared or lead.margin > 0)
      end)
      |> Enum.sort_by(fn {_ward_id, lead} -> lead.margin end)
      |> Enum.take(6)
      |> Enum.map(fn {ward_id, lead} ->
        Map.merge(lead, %{ward_id: ward_id, ward_number: Iec.Results.Ward.ward_number(ward_id)})
      end)
      |> IecWeb.WardNames.with_names()

    Map.new(
      page_title: (municipality && municipality.area_name) || "Municipality",
      trend: Trends.series(history, :vote_percentage, parties, limit: 5),
      counting: municipality != nil and municipality.municipalities_complete != 1,
      ward_results: Maps.list_area_results(:ward, ward_ids),
      ward_tally: ward_tally(ward_rows, parties),
      closest_wards: closest_wards,
      flipped_wards: Enum.filter(ward_rows, & &1.changed_hands),
      municipality: municipality,
      complete: municipality != nil and municipality.municipalities_complete == 1,
      province_name: municipality && Results.get_area_name(:province, municipality.province_id),
      previous_municipality: previous_municipality,
      from_party_files: overview.parties != [],
      party_rows: party_rows,
      summary: Narrative.summary(municipality, party_rows, parties, previous_year),
      ward_rows: ward_rows,
      wards_declared: Enum.count(ward_rows, & &1.holder),
      wards_changed: Enum.count(ward_rows, & &1.changed_hands),
      control: control[{live_year, municipality_id}],
      previous_control: control[{previous_year, municipality_id}],
      changes:
        Results.list_changes(level: :municipality, area_id: municipality_id, changed_only: true)
        |> Enum.map(&Change.compare/1)
    )
  end

  # Wards won per party now and in the previous election, most first. The previous count
  # covers today's wards that existed then.
  defp ward_tally(ward_rows, parties) do
    now = Enum.frequencies_by(Enum.filter(ward_rows, & &1.holder), & &1.holder)

    before =
      Enum.frequencies_by(Enum.filter(ward_rows, & &1.previous_holder), & &1.previous_holder)

    (Map.keys(now) ++ Map.keys(before))
    |> Enum.uniq()
    |> Enum.map(fn party_id ->
      %{
        party_id: party_id,
        wards: Map.get(now, party_id, 0),
        previous_wards: Map.get(before, party_id, 0),
        change: Map.get(now, party_id, 0) - Map.get(before, party_id, 0)
      }
    end)
    |> Enum.sort_by(&{-&1.wards, -&1.previous_wards})
    |> TableRows.with_party_name(parties, :party_id, :party)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header :if={is_nil(@municipality)} eyebrow="Municipality" title="No results">
        <:breadcrumb><.link navigate={~p"/"} class="link-hover link">Overview</.link> /</:breadcrumb>
        <:lede>
          No results for this municipality yet, or no municipality has this id.
          <.link navigate={~p"/wards"} class="link">Find a ward or municipality</.link>
        </:lede>
      </.page_header>

      <div :if={@municipality} class="space-y-12">
        <.page_header
          eyebrow={@summary && @summary.eyebrow}
          live={@summary != nil and @summary.live}
          title={@municipality.area_name}
        >
          <:breadcrumb>
            <.link navigate={~p"/"} class="link-hover link">Overview</.link>
            /
            <.link navigate={~p"/provinces/#{@municipality.province_id}"} class="link-hover link">
              {@province_name}
            </.link>
            /
          </:breadcrumb>
          <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
        </.page_header>

        <section class="panel space-y-8 p-5 sm:p-7">
          <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
          <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
            <.kpi
              label="Districts counted"
              value={
                format_progress(
                  @municipality.voting_districts_complete,
                  @municipality.voting_districts_expected
                )
              }
            >
              {format_number(@municipality.voting_districts_complete)} of {format_number(
                @municipality.voting_districts_expected
              )}
            </.kpi>
            <.kpi label="Wards declared" value={format_number(@wards_declared)}>
              of {length(@ward_rows)} · {@wards_changed} changed hands
            </.kpi>
            <div class="min-w-0">
              <div class="eyebrow">Council {if @complete, do: "now", else: "so far"}</div>
              <div class="mt-2">
                <.council_control parties={@parties} control={@control} counting={not @complete} />
              </div>
            </div>
            <div class="min-w-0">
              <div class="eyebrow">Council in {@previous_year}</div>
              <div class="mt-2">
                <.council_control parties={@parties} control={@previous_control} />
              </div>
            </div>
          </div>
          <div
            id="municipality-ballots"
            class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4"
          >
            <.kpi label="Registered voters" value={format_compact(@municipality.registered_voters)}>
              <span :if={@previous_municipality}>
                {format_compact(@previous_municipality.registered_voters)} in {@previous_year}
              </span>
            </.kpi>
            <.kpi
              label={if @complete, do: "Ballots cast", else: "Ballots so far"}
              value={format_compact(@municipality.total_votes_cast)}
            >
              <span :if={@previous_municipality}>
                {format_compact(@previous_municipality.total_votes_cast)} in {@previous_year}
              </span>
            </.kpi>
            <.kpi
              label="Spoilt"
              value={format_share(@municipality.spoilt_votes, @municipality.total_votes_cast)}
            >
              <span :if={@previous_municipality}>
                {format_share(
                  @previous_municipality.spoilt_votes,
                  @previous_municipality.total_votes_cast
                )} in {@previous_year}
              </span>
            </.kpi>
            <.kpi
              label="Seats declared"
              value={format_number(@municipality.seats_complete)}
            >
              of {format_number(@municipality.seats_expected)}
            </.kpi>
          </div>
        </section>

        <section class="grid gap-6 lg:grid-cols-5">
          <div :if={length(@trend.years) > 1} class="space-y-3 lg:col-span-3">
            <.section_heading title={"Since #{List.first(@trend.years)}"}>
              <:subtitle>
                Share of the vote in every local election (the IEC lists each council's top
                three){if @counting, do: "; #{@live_year} is dashed while its count runs"}
              </:subtitle>
            </.section_heading>
            <div class="panel p-5 sm:p-6">
              <.line_chart
                id="municipality-trend"
                trend={@trend}
                live_year={@live_year}
                counting={@counting}
              />
            </div>
          </div>
          <div :if={@ward_tally != []} class="space-y-3 lg:col-span-2">
            <.section_heading title="Wards won">
              <:subtitle>The declared wards, against who won them in {@previous_year}</:subtitle>
            </.section_heading>
            <ul id="municipality-ward-tally" class="panel space-y-3 p-5 sm:p-6">
              <li :for={row <- Enum.take(@ward_tally, 6)} id={"ward-tally-#{row.party_id}"}>
                <.link navigate={~p"/parties/#{row.party_id}"} class="group block space-y-1.5">
                  <span class="flex items-baseline justify-between gap-3 text-sm">
                    <span class="inline-flex items-center gap-2 font-medium group-hover:underline">
                      <span
                        class="size-2.5 rounded-full"
                        style={"background-color: #{party_colour(@parties, row)}"}
                      />
                      {row.party}
                    </span>
                    <span class="tabular-nums">
                      <span class="font-medium">{row.wards}</span>
                      <span class={["ml-1 text-xs", delta_class(row.change)]}>
                        {format_delta(row.change, :count)}
                      </span>
                    </span>
                  </span>
                  <span class="relative block h-2 overflow-hidden rounded-full bg-base-200">
                    <span
                      class="absolute inset-y-0 left-0 rounded-full opacity-30"
                      style={"width: #{row.previous_wards / max(length(@ward_rows), 1) * 100}%; background-color: #{party_colour(@parties, row)}"}
                    />
                    <span
                      class="absolute inset-y-0 left-0 rounded-full transition-[width] duration-1000"
                      style={"width: #{row.wards / max(length(@ward_rows), 1) * 100}%; background-color: #{party_colour(@parties, row)}"}
                    />
                  </span>
                </.link>
              </li>
              <li class="pt-1 text-xs text-base-content/55">
                Faint bar: {@previous_year}. {@wards_declared} of {length(@ward_rows)} wards declared.
              </li>
            </ul>
          </div>
        </section>

        <section :if={@ward_rows != []} id="municipality-ward-picker" class="space-y-3">
          <.section_heading title="Pick a ward">
            <:subtitle>Each in its leader's colour; a hollow dot is still counting</:subtitle>
            <:actions>
              <.link navigate={~p"/wards"} class="link-hover link">Search all wards →</.link>
            </:actions>
          </.section_heading>
          <ul class="grid grid-cols-[repeat(auto-fill,minmax(4rem,1fr))] gap-2">
            <li :for={ward <- Enum.sort_by(@ward_rows, & &1.ward_number)}>
              <.ward_chip
                ward_id={ward.ward_id}
                ward_number={ward.ward_number}
                name={ward[:ward_name]}
                result={@ward_results[ward.ward_id]}
                parties={@parties}
              />
            </li>
          </ul>
        </section>

        <section
          :if={@closest_wards != [] or @flipped_wards != []}
          class="grid gap-6 lg:grid-cols-2"
        >
          <div :if={@closest_wards != []} class="space-y-3">
            <.section_heading title="Closest wards">
              <:subtitle>Lead of the first party over the second</:subtitle>
            </.section_heading>
            <ul class="panel divide-y divide-base-300 overflow-hidden">
              <li :for={ward <- @closest_wards} id={"closest-ward-#{ward.ward_id}"}>
                <.link
                  navigate={~p"/wards/#{ward.ward_id}"}
                  class="group flex min-h-12 items-center gap-3 px-4 py-2.5 transition-colors hover:bg-base-200/70"
                >
                  <span class="w-28 min-w-0 shrink-0">
                    <span class="block whitespace-nowrap font-medium">Ward {ward.ward_number}</span>
                    <span :if={ward.ward_name} class="block truncate text-xs text-base-content/55">
                      {ward.ward_name}
                    </span>
                  </span>
                  <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 text-sm">
                    <.party_label
                      parties={@parties}
                      party_result={%{party_id: ward.leader_id}}
                      link={false}
                    />
                    <span class="text-base-content/50">over</span>
                    <.party_label
                      parties={@parties}
                      party_result={%{party_id: ward.runner_up_id}}
                      link={false}
                    />
                  </span>
                  <span class="text-right text-sm font-medium tabular-nums">
                    {format_points(ward.margin)}
                  </span>
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-4 text-base-content/30 transition-transform group-hover:translate-x-0.5"
                  />
                </.link>
              </li>
            </ul>
          </div>
          <div :if={@flipped_wards != []} class="space-y-3">
            <.section_heading title="Changed hands">
              <:subtitle>
                {length(@flipped_wards)} wards with a new winner since {@previous_year}
              </:subtitle>
            </.section_heading>
            <ul class="panel divide-y divide-base-300 overflow-hidden">
              <li :for={ward <- Enum.take(@flipped_wards, 8)} id={"flipped-ward-#{ward.ward_id}"}>
                <.link
                  navigate={~p"/wards/#{ward.ward_id}"}
                  class="group flex min-h-12 items-center gap-3 px-4 py-2.5 transition-colors hover:bg-base-200/70"
                >
                  <span class="w-28 min-w-0 shrink-0">
                    <span class="block whitespace-nowrap font-medium">Ward {ward.ward_number}</span>
                    <span :if={ward.ward_name} class="block truncate text-xs text-base-content/55">
                      {ward.ward_name}
                    </span>
                  </span>
                  <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 text-sm">
                    <.party_label
                      parties={@parties}
                      party_result={%{party_id: ward.previous_holder}}
                      link={false}
                    />
                    <span class="text-base-content/50">→</span>
                    <.party_label
                      parties={@parties}
                      party_result={%{party_id: ward.holder}}
                      link={false}
                    />
                  </span>
                  <.icon
                    name="hero-chevron-right-micro"
                    class="size-4 text-base-content/30 transition-transform group-hover:translate-x-0.5"
                  />
                </.link>
              </li>
              <li :if={length(@flipped_wards) > 8} class="px-4 py-2.5 text-sm">
                <a href="#municipality-wards" class="link-hover link">
                  All {length(@flipped_wards)} in the wards table ↓
                </a>
              </li>
            </ul>
          </div>
        </section>

        <section class="space-y-2">
          <.section_heading title="Parties" />
          <div class="panel p-2 sm:p-4">
            <.party_table
              :if={not @from_party_files}
              id="municipality-parties"
              rows={@party_rows}
              parties={@parties}
              previous_year={@previous_year}
              sorts={@sorts}
            />
            <.council_party_table
              :if={@from_party_files}
              id="municipality-parties"
              rows={@party_rows}
              shown={@parties_shown}
              parties={@parties}
              previous_year={@previous_year}
              sorts={@sorts}
            />
          </div>
        </section>

        <section class="space-y-3">
          <.section_heading title="Wards map">
            <:subtitle>Each ward in its leading party's colour</:subtitle>
          </.section_heading>
          <.live_component
            module={IecWeb.MapComponent}
            id="municipality-map"
            level={:ward}
            municipality_id={@municipality_id}
            parties={@parties}
            refreshed_at={@refreshed_at}
          />
        </section>

        <section :if={@ward_rows != []} class="space-y-2">
          <.section_heading title="Wards">
            <:subtitle>
              {@wards_declared} of {length(@ward_rows)} declared · {@wards_changed} changed hands
            </:subtitle>
          </.section_heading>
          <div class="panel p-2 sm:p-4">
            <.ward_winners_table
              id="municipality-wards"
              rows={@ward_rows}
              parties={@parties}
              previous_year={@previous_year}
              sorts={@sorts}
            />
          </div>
        </section>

        <section class="space-y-2">
          <.section_heading title="History" />
          <p :if={@changes == []} class="text-sm opacity-60">Nothing has moved since start-up.</p>
          <ul id="municipality-changes" class="divide-y divide-base-300">
            <.change_entry
              :for={change <- @changes}
              change={change}
              parties={@parties}
              show_area={false}
            />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp format_share(part, whole) when is_integer(part) and is_integer(whole) and whole > 0,
    do: format_progress(part / whole * 100)

  defp format_share(_part, _whole), do: "–"

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :shown, :integer, required: true
  attr :sorts, :map, required: true

  # Every followed party's share and seats in this council, from the party files.
  defp council_party_table(assigns) do
    visible = assigns.rows |> sort_rows(assigns.sorts[assigns.id]) |> Enum.take(assigns.shown)
    assigns = assign(assigns, visible: visible, total: length(assigns.rows))

    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="party" sorts={@sorts} first="asc">Party</.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="swing" sorts={@sorts} align="right">Swing</.sort_header>
            <.sort_header table={@id} column="seats" sorts={@sorts} align="right">Seats</.sort_header>
            <.sort_header table={@id} column="previous_seats" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @visible} id={"#{@id}-#{row.party_id}"}>
            <td>
              <.party_label parties={@parties} party_result={row} />
              <span :if={row.majority} class="badge badge-success badge-sm ml-2">majority</span>
            </td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
            </td>
            <td class={["text-right tabular-nums", delta_class(row.swing)]}>
              {format_delta(row.swing, :points)}
            </td>
            <td class="text-right tabular-nums">{format_number(row.seats)}</td>
            <td class="text-right tabular-nums opacity-60">{format_number(row.previous_seats)}</td>
          </tr>
        </tbody>
      </table>
      <.show_more table={@id} shown={length(@visible)} total={@total} />
      <p class="mt-2 text-sm opacity-60">
        Every party standing in this council, from its party file.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  # Each ward's winner now and in the previous election.
  defp ward_winners_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="ward_number" sorts={@sorts} first="asc">
              Ward
            </.sort_header>
            <.sort_header table={@id} column="holder_name" sorts={@sorts} first="asc">
              Winner
            </.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_holder_name" sorts={@sorts} first="asc">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year} share
            </.sort_header>
            <.sort_header table={@id} column="declared_at" sorts={@sorts}>Declared</.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={ward <- sort_rows(@rows, @sorts[@id])}
            id={"ward-#{ward.ward_id}"}
            class={ward.changed_hands && "bg-warning/10"}
          >
            <td class="tabular-nums">
              <.link navigate={~p"/wards/#{ward.ward_id}"} class="link font-medium">
                {ward.ward_number}
              </.link>
              <span :if={ward.ward_name} class="block max-w-48 truncate text-xs text-base-content/60">
                {ward.ward_name}
              </span>
              <span :if={ward.new_ward} class="badge badge-ghost badge-sm">new</span>
              <span
                :if={ward.redrawn}
                class="badge badge-ghost badge-sm"
                title="Boundary changed since the previous election"
              >
                redrawn
              </span>
            </td>
            <td>
              <.party_or_dash parties={@parties} party_id={ward.holder} empty="not declared" />
            </td>
            <td class="text-right tabular-nums">{format_percentage(ward.share)}</td>
            <td class="opacity-75">
              <.party_or_dash parties={@parties} party_id={ward.previous_holder} />
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(ward.previous_share)}
            </td>
            <td class="tabular-nums opacity-75"><.declared_at ward={ward} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
