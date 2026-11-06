defmodule IecWeb.MunicipalityLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.{Contests, Maps, Parties, Results}
  alias Iec.Results.Change
  alias IecWeb.{LiveUpdates, Narrative, TableRows, Trends}

  # Parties shown at first, and how many more each "Show more" adds.
  @page_size 10
  @more 25

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results, :parties]}

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

  @impl LiveUpdates
  def refresh(socket),
    do: LiveUpdates.assign_cached(socket, {__MODULE__, socket.assigns.municipality_id}, &load/1)

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

    party_rows =
      TableRows.council_party_rows(
        overview.parties,
        municipality,
        previous_municipality,
        parties
      )

    ward_rows = TableRows.ward_winner_rows(overview.wards, parties)
    ward_ids = Enum.map(ward_rows, & &1.ward_id)
    history = Results.list_snapshots_by_election(:municipality, municipality_id)
    decided = council_decided?(municipality)

    %{
      page_title: (municipality && municipality.area_name) || "Municipality",
      trend: Trends.series(history, :vote_percentage, parties, limit: 5),
      counting: municipality != nil and not decided,
      ward_results: Maps.list_area_results(:ward, ward_ids),
      ward_tally: ward_rows |> TableRows.ward_tally(parties) |> Enum.take(6),
      closest_wards:
        live_year |> Contests.list_ward_leads(ward_ids) |> TableRows.closest_ward_rows(6),
      flipped_wards: Enum.filter(ward_rows, & &1.changed_hands),
      municipality: municipality,
      decided: decided,
      province_name: municipality && Results.get_area_name(:province, municipality.province_id),
      previous_municipality: previous_municipality,
      from_party_files: overview.parties != [],
      party_rows: party_rows,
      summary: Narrative.summary(municipality, party_rows, parties, previous_year),
      ward_rows: ward_rows,
      wards_declared: Enum.count(ward_rows, & &1.holder),
      control: control[{live_year, municipality_id}],
      previous_control: control[{previous_year, municipality_id}],
      changes:
        Results.list_changes(level: :municipality, area_id: municipality_id, changed_only: true)
        |> Enum.map(&Change.compare/1)
    }
  end

  @impl Phoenix.LiveView
  def render(%{municipality: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.not_found eyebrow="Municipality" title="No results">
        No results for this municipality yet, or no municipality has this id.
        <.link navigate={~p"/wards"} class="link">Find a ward or municipality</.link>
      </.not_found>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header
        eyebrow={@summary && @summary.eyebrow}
        live={@summary != nil and @summary.live}
        title={@municipality.area_name}
        crumbs={[
          {"Overview", ~p"/"},
          {@province_name, ~p"/provinces/#{@municipality.province_id}"}
        ]}
      >
        <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
      </.page_header>

      <.key_figures
        municipality={@municipality}
        previous_municipality={@previous_municipality}
        party_rows={@party_rows}
        parties={@parties}
        previous_year={@previous_year}
        decided={@decided}
        wards={length(@ward_rows)}
        wards_declared={@wards_declared}
        wards_changed={length(@flipped_wards)}
        control={@control}
        previous_control={@previous_control}
      />

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
          <.ward_tally
            rows={@ward_tally}
            parties={@parties}
            previous_year={@previous_year}
            wards={length(@ward_rows)}
            wards_declared={@wards_declared}
          />
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
              name={ward.ward_name}
              result={@ward_results[ward.ward_id]}
              parties={@parties}
            />
          </li>
        </ul>
      </section>

      <section :if={@closest_wards != [] or @flipped_wards != []} class="grid gap-6 lg:grid-cols-2">
        <div :if={@closest_wards != []} class="space-y-3">
          <.section_heading title="Closest wards">
            <:subtitle>Lead of the first party over the second</:subtitle>
          </.section_heading>
          <ul class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={ward <- @closest_wards} id={"closest-ward-#{ward.ward_id}"}>
              <.ward_row
                ward={ward}
                first={ward.leader_id}
                second={ward.runner_up_id}
                parties={@parties}
              >
                <:between>over</:between>
                <:figure>{format_points(ward.margin)}</:figure>
              </.ward_row>
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
              <.ward_row
                ward={ward}
                first={ward.previous_holder}
                second={ward.holder}
                parties={@parties}
              >
                <:between>→</:between>
              </.ward_row>
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
            {@wards_declared} of {length(@ward_rows)} declared · {length(@flipped_wards)} changed hands
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
        <.empty :if={@changes == []}>Nothing has moved since start-up.</.empty>
        <ul id="municipality-changes" class="divide-y divide-base-300">
          <.change_entry
            :for={change <- @changes}
            change={change}
            parties={@parties}
            show_area={false}
          />
        </ul>
      </section>
    </Layouts.app>
    """
  end

  attr :municipality, :map, required: true
  attr :previous_municipality, :map, default: nil
  attr :party_rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :decided, :boolean, required: true
  attr :wards, :integer, required: true
  attr :wards_declared, :integer, required: true
  attr :wards_changed, :integer, required: true
  attr :control, :map, default: nil
  attr :previous_control, :map, default: nil

  # The vote share, the count, who runs the council now and before, and the ballots
  # against the previous election.
  defp key_figures(assigns) do
    ~H"""
    <section class="panel space-y-8 p-5 sm:p-7">
      <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
      <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
        <.districts_kpi snapshot={@municipality} />
        <.kpi label="Wards declared" value={format_number(@wards_declared)}>
          of {@wards} · {@wards_changed} changed hands
        </.kpi>
        <.council_fact parties={@parties} control={@control} decided={@decided} />
        <.fact label={"Council in #{@previous_year}"}>
          <.council_control parties={@parties} control={@previous_control} />
        </.fact>
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
          label={if @decided, do: "Ballots cast", else: "Ballots so far"}
          value={format_compact(@municipality.total_votes_cast)}
        >
          <span :if={@previous_municipality}>
            {format_compact(@previous_municipality.total_votes_cast)} in {@previous_year}
          </span>
        </.kpi>
        <.kpi
          label="Spoilt"
          value={format_share_of(@municipality.spoilt_votes, @municipality.total_votes_cast)}
        >
          <span :if={@previous_municipality}>
            {format_share_of(
              @previous_municipality.spoilt_votes,
              @previous_municipality.total_votes_cast
            )} in {@previous_year}
          </span>
        </.kpi>
        <.kpi label="Seats declared" value={format_number(@municipality.seats_complete)}>
          of {format_number(@municipality.seats_expected)}
        </.kpi>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true, doc: "from IecWeb.TableRows.ward_tally/2"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :wards, :integer, required: true
  attr :wards_declared, :integer, required: true

  # Wards won per party as bars, with the previous election's count faint behind.
  defp ward_tally(assigns) do
    ~H"""
    <ul id="municipality-ward-tally" class="panel space-y-3 p-5 sm:p-6">
      <li :for={row <- @rows} id={"ward-tally-#{row.party_id}"}>
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
              style={"width: #{row.previous_width}%; background-color: #{party_colour(@parties, row)}"}
            />
            <span
              class="absolute inset-y-0 left-0 rounded-full transition-[width] duration-1000"
              style={"width: #{row.width}%; background-color: #{party_colour(@parties, row)}"}
            />
          </span>
        </.link>
      </li>
      <li class="pt-1 text-xs text-base-content/55">
        Faint bar: {@previous_year}. {@wards_declared} of {@wards} wards declared.
      </li>
    </ul>
    """
  end

  attr :ward, :map, required: true, doc: "with `ward_id`, `ward_number` and `ward_name`"
  attr :first, :integer, doc: "the party named first"
  attr :second, :integer, doc: "the party named second"
  attr :parties, :map, required: true
  slot :between, required: true
  slot :figure

  # A ward as a linked row: its number and name, two parties, and a figure.
  defp ward_row(assigns) do
    ~H"""
    <.link_row navigate={~p"/wards/#{@ward.ward_id}"}>
      <span class="w-28 min-w-0 shrink-0">
        <span class="block whitespace-nowrap font-medium">Ward {@ward.ward_number}</span>
        <span :if={@ward.ward_name} class="block truncate text-xs text-base-content/55">
          {@ward.ward_name}
        </span>
      </span>
      <span class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 text-sm">
        <.party_label parties={@parties} party_result={%{party_id: @first}} link={false} />
        <span class="text-base-content/50">{render_slot(@between)}</span>
        <.party_label parties={@parties} party_result={%{party_id: @second}} link={false} />
      </span>
      <span :if={@figure != []} class="text-right text-sm font-medium tabular-nums">
        {render_slot(@figure)}
      </span>
    </.link_row>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :shown, :integer, required: true
  attr :sorts, :map, required: true

  # Every followed party's share and seats in this council, from the party files.
  defp council_party_table(assigns) do
    assigns =
      assign(assigns, :page, sorted_page(assigns.rows, assigns.sorts[assigns.id], assigns.shown))

    ~H"""
    <.sortable_table
      id={@id}
      rows={@page.rows}
      sorts={@sorts}
      sorted
      row_id={&"#{@id}-#{&1.party_id}"}
    >
      <:column :let={row} label="Party" field="party" first="asc">
        <.party_label parties={@parties} party_result={row} />
        <span :if={row.majority} class="badge badge-success badge-sm ml-2">majority</span>
      </:column>
      <:column :let={row} label="Share" field="share" align="right">
        {format_percentage(row.share)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_share"
        align="right"
        class="opacity-60"
      >
        {format_percentage(row.previous_share)}
      </:column>
      <:column :let={row} label="Swing" field="swing" align="right" class={&delta_class(&1.swing)}>
        {format_delta(row.swing, :points)}
      </:column>
      <:column :let={row} label="Seats" field="seats" align="right">
        {format_number(row.seats)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_seats"
        align="right"
        class="opacity-60"
      >
        {format_number(row.previous_seats)}
      </:column>
      <.show_more table={@id} shown={@page.shown} total={@page.total} />
      <p class="mt-2 text-sm opacity-60">
        Every party standing in this council, from its party file.
      </p>
    </.sortable_table>
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
    <.sortable_table
      id={@id}
      rows={@rows}
      sorts={@sorts}
      row_id={&"ward-#{&1.ward_id}"}
      row_class={&(&1.changed_hands && "bg-warning/10")}
    >
      <:column :let={ward} label="Ward" field="ward_number" first="asc" class="tabular-nums">
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
      </:column>
      <:column :let={ward} label="Winner" field="holder_name" first="asc">
        <.party_or_dash parties={@parties} party_id={ward.holder} empty="not declared" />
      </:column>
      <:column :let={ward} label="Share" field="share" align="right">
        {format_percentage(ward.share)}
      </:column>
      <:column
        :let={ward}
        label={"#{@previous_year}"}
        field="previous_holder_name"
        first="asc"
        class="opacity-75"
      >
        <.party_or_dash parties={@parties} party_id={ward.previous_holder} />
      </:column>
      <:column
        :let={ward}
        label={"#{@previous_year} share"}
        field="previous_share"
        align="right"
        class="opacity-60"
      >
        {format_percentage(ward.previous_share)}
      </:column>
      <:column :let={ward} label="Declared" field="declared_at" class="tabular-nums opacity-75">
        <.declared_at ward={ward} />
      </:column>
    </.sortable_table>
    """
  end
end
