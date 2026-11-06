defmodule IecWeb.WardLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.{Contests, Maps, Parties, Places, Results, Wards}
  alias IecWeb.{LiveUpdates, Narrative, TableRows, Trends, WardNames}

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
       ward_id: IecWeb.Params.id(id),
       parties_shown: @page_size,
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl LiveUpdates
  def refresh(socket),
    do: LiveUpdates.assign_cached(socket, {__MODULE__, socket.assigns.ward_id}, &load/1)

  @impl Phoenix.LiveView
  def handle_event("show_more", %{"table" => "ward-parties"}, socket),
    do: {:noreply, update(socket, :parties_shown, &(&1 + @more))}

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(%{ward_id: nil}), do: %{page_title: "Ward", ward: nil}

  defp load(%{ward_id: ward_id} = assigns) do
    case Parties.get_ward_overview(ward_id) do
      nil -> %{page_title: "Ward", ward: nil}
      ward -> load(ward, assigns)
    end
  end

  defp load(ward, assigns) do
    %{live_year: live_year, previous_year: previous_year, parties: parties} = assigns
    municipality = Results.get_latest_snapshot(:municipality, ward.municipality_id)
    control = Parties.get_council_control([ward.municipality_id])
    lead = Contests.list_ward_leads(live_year, [ward.ward_id])[ward.ward_id]

    # A new or redrawn ward has no like-for-like lead to compare with.
    previous_lead =
      if not ward.new_ward and not ward.redrawn,
        do: Contests.list_ward_leads(previous_year, [ward.ward_id])[ward.ward_id]

    nearby_ids = Maps.list_nearby_ward_ids(ward.ward_id)
    party_rows = TableRows.with_party_name(ward.parties, parties, :party_id, :party)
    ward_label = WardNames.label(ward.ward_id, ward.ward_number)

    %{
      page_title:
        Enum.join([ward_label | List.wrap(municipality && municipality.area_name)], " · "),
      ward_label: ward_label,
      ward: ward,
      municipality: municipality,
      province_name: municipality && Results.get_area_name(:province, municipality.province_id),
      summary: Narrative.ward(ward, lead, parties, previous_year),
      lead: lead,
      previous_lead: previous_lead,
      # Towns and suburbs whose point lies in the ward, the biggest first.
      places:
        ward.ward_id |> Places.list_ward_places() |> Enum.take(8) |> Narrative.ward_places(),
      party_rows: party_rows,
      trend: Trends.from_shares(party_rows, parties, {previous_year, live_year}),
      council_trend:
        Results.list_snapshots_by_election(:municipality, ward.municipality_id)
        |> Trends.series(:vote_percentage, parties, limit: 4),
      counting: lead == nil or not lead.declared,
      council_decided: council_decided?(municipality),
      nearby_ids: nearby_ids,
      nearby_rows: nearby_rows(nearby_ids, parties),
      control: control[{live_year, ward.municipality_id}],
      previous_control: control[{previous_year, ward.municipality_id}]
    }
  end

  # The wards around this one, nearest first, from the search's index (shared with it).
  defp nearby_rows(nearby_ids, parties) do
    index = Iec.Cache.fetch(:ward_index, &Wards.build_index/0)
    by_id = index.wards |> Enum.filter(&(&1.ward_id in nearby_ids)) |> Map.new(&{&1.ward_id, &1})

    nearby_ids
    |> Enum.flat_map(&List.wrap(by_id[&1]))
    |> TableRows.ward_result_rows(Maps.list_area_results(:ward, nearby_ids), parties)
  end

  @impl Phoenix.LiveView
  def render(%{ward: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:wards}
      feed_status={@feed_status}
      count_progress={@count_progress}
    >
      <.not_found eyebrow="Ward">
        There is no such ward in the {@live_year} ward directory.
        <.link navigate={~p"/wards"} class="link">Find your ward</.link>
      </.not_found>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:wards}
      feed_status={@feed_status}
      count_progress={@count_progress}
    >
      <.page_header
        eyebrow={(@summary && @summary.eyebrow) || "No results yet"}
        live={@summary != nil and @summary.live}
        title={@ward_label}
        crumbs={crumbs(@municipality, @province_name)}
      >
        <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
        <:lede :if={@places}>
          <span id="ward-places" class="block text-base text-base-content/60">{@places}</span>
        </:lede>
        <:lede :if={is_nil(@summary)}>
          No party has votes in this ward yet. It fills in as the party files report.
        </:lede>
      </.page_header>

      <.key_figures
        ward={@ward}
        lead={@lead}
        previous_lead={@previous_lead}
        party_rows={@party_rows}
        parties={@parties}
        previous_year={@previous_year}
        council_decided={@council_decided}
        control={@control}
        previous_control={@previous_control}
      />

      <section class="grid gap-6 lg:grid-cols-2">
        <div :if={@trend.series != []} class="space-y-3">
          <.section_heading title={"This ward since #{@previous_year}"}>
            <:subtitle>{trend_subtitle(@ward, @live_year, @previous_year)}</:subtitle>
          </.section_heading>
          <div class="panel p-5 sm:p-6">
            <.line_chart id="ward-trend" trend={@trend} live_year={@live_year} counting={@counting} />
          </div>
        </div>
        <div :if={length(@council_trend.years) > 1 and @municipality} class="space-y-3">
          <.section_heading title={"The council since #{List.first(@council_trend.years)}"}>
            <:subtitle>{@municipality.area_name}, its top three in each election</:subtitle>
            <:actions>
              <.link navigate={~p"/municipalities/#{@ward.municipality_id}"} class="link-hover link">
                Dashboard →
              </.link>
            </:actions>
          </.section_heading>
          <div class="panel p-5 sm:p-6">
            <.line_chart
              id="ward-council-trend"
              trend={@council_trend}
              live_year={@live_year}
              counting={not @council_decided}
            />
          </div>
        </div>
      </section>

      <section :if={@party_rows != []} class="space-y-2">
        <.section_heading title="Parties">
          <:subtitle>Every party with votes in the ward, now and in {@previous_year}</:subtitle>
        </.section_heading>
        <div class="panel p-2 sm:p-4">
          <.ward_party_table
            id="ward-parties"
            rows={@party_rows}
            shown={@parties_shown}
            parties={@parties}
            previous_year={@previous_year}
            redrawn={@ward.redrawn}
            sorts={@sorts}
          />
        </div>
      </section>

      <section :if={@nearby_ids != []} class="space-y-3">
        <.section_heading title="Around the ward">
          <:subtitle>This ward, outlined, and the wards next to it</:subtitle>
        </.section_heading>
        <.live_component
          module={IecWeb.MapComponent}
          id="ward-map"
          level={:ward}
          area_ids={[@ward.ward_id | @nearby_ids]}
          highlight={@ward.ward_id}
          parties={@parties}
          refreshed_at={@refreshed_at}
        />
      </section>

      <section :if={@nearby_rows != []} class="space-y-2">
        <.section_heading title="Nearby wards">
          <:subtitle>Nearest first, in any municipality</:subtitle>
        </.section_heading>
        <div class="panel p-2 sm:p-4">
          <.ward_results_table
            id="nearby-wards"
            rows={@nearby_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp crumbs(nil, _province_name), do: [{"Overview", ~p"/"}]

  defp crumbs(municipality, province_name) do
    [
      {"Overview", ~p"/"},
      {province_name, ~p"/provinces/#{municipality.province_id}"},
      {municipality.area_name, ~p"/municipalities/#{municipality.area_id}"}
    ]
  end

  defp trend_subtitle(%{new_ward: true}, live_year, _previous_year),
    do: "A new ward: #{live_year} only"

  defp trend_subtitle(%{redrawn: true}, _live_year, previous_year),
    do: "Redrawn since #{previous_year}: that line is its old boundary"

  defp trend_subtitle(_ward, _live_year, _previous_year),
    do: "Share of the ward's votes, the biggest parties"

  attr :ward, :map, required: true
  attr :lead, :map, default: nil
  attr :previous_lead, :map, default: nil
  attr :party_rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :council_decided, :boolean, required: true
  attr :control, :map, default: nil
  attr :previous_control, :map, default: nil

  # The vote share, who won or leads and by how much, against the previous election, and
  # who runs the council.
  defp key_figures(assigns) do
    ~H"""
    <section class="panel space-y-8 p-5 sm:p-7">
      <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
      <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
        <.fact label={if @lead && @lead.declared, do: "Winner", else: "Leading"}>
          <.party_or_dash
            parties={@parties}
            party_id={@lead && @lead.leader_id}
            empty="no results yet"
          />
          <div :if={@lead} class="text-sm tabular-nums text-base-content/60">
            {format_percentage(@lead.leader_share)}
            <span :if={@ward.declared_at}>· declared <.declared_at ward={@ward} /></span>
          </div>
        </.fact>
        <.kpi label="Lead" value={format_points(@lead && @lead.margin)}>
          <span :if={@previous_lead && @previous_lead.margin}>
            {format_points(@previous_lead.margin)} in {@previous_year}
          </span>
          <span :if={@ward.new_ward}>new ward</span>
          <span :if={@ward.redrawn}>redrawn since {@previous_year}</span>
        </.kpi>
        <.fact label={"Won in #{@previous_year}"}>
          <.party_or_dash
            parties={@parties}
            party_id={@ward.previous_holder}
            empty={if @ward.new_ward, do: "new ward", else: "–"}
          />
          <div :if={@ward.previous_share} class="text-sm tabular-nums text-base-content/60">
            {format_percentage(@ward.previous_share)}
            <span :if={@ward.redrawn}>· old boundary</span>
          </div>
        </.fact>
        <.council_fact parties={@parties} control={@control} decided={@council_decided}>
          <div class="flex flex-wrap items-center gap-1.5 text-sm text-base-content/60">
            {@previous_year}: <.council_control parties={@parties} control={@previous_control} />
          </div>
        </.council_fact>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :redrawn, :boolean, required: true
  attr :shown, :integer, required: true
  attr :sorts, :map, required: true

  # Each party's share of the ward now and before, from the party files.
  defp ward_party_table(assigns) do
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
        <span :if={row.won} class="badge badge-success badge-sm ml-2">won</span>
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
        <span :if={row.previous_won} title={"Won the ward in #{@previous_year}"}>✓</span>
      </:column>
      <:column :let={row} label="Swing" field="swing" align="right" class={&delta_class(&1.swing)}>
        {format_delta(row.swing, :points)}
      </:column>
      <:column :let={row} label="Council" field="council_share" align="right" class="opacity-60">
        {format_percentage(row.council_share)}
      </:column>
      <.show_more table={@id} shown={@page.shown} total={@page.total} />
      <p class="mt-2 text-sm opacity-60">
        Shares are of all the ward's votes, from the party files of the parties the app
        follows; the seat goes to whoever wins the ward ballot. Council: the party's share
        across the whole municipality.
        <span :if={@redrawn}>
          The ward was redrawn since {@previous_year}: those figures are for its old boundary.
        </span>
      </p>
    </.sortable_table>
    """
  end
end
