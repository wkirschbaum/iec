defmodule IecWeb.WardLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.{Contests, Maps, Parties, Places, Results, Wards}
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
       ward_id: IecWeb.Params.id(id),
       parties_shown: @page_size,
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    assign(socket, Iec.Cache.fetch(cache_key(socket.assigns), fn -> load(socket.assigns) end))
  end

  # Computed once per data change and shared by everyone viewing the same page.
  defp cache_key(assigns), do: {__MODULE__, assigns.ward_id}

  @impl Phoenix.LiveView
  def handle_event("show_more", %{"table" => "ward-parties"}, socket),
    do: {:noreply, update(socket, :parties_shown, &(&1 + @more))}

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(%{ward_id: nil}), do: %{page_title: "Ward", ward: nil}

  defp load(assigns) do
    %{ward_id: ward_id, live_year: live_year, previous_year: previous_year, parties: parties} =
      assigns

    case Parties.get_ward_overview(ward_id) do
      nil ->
        %{page_title: "Ward", ward: nil}

      ward ->
        municipality = Results.get_latest_snapshot(:municipality, ward.municipality_id)
        control = Parties.get_council_control([ward.municipality_id])
        lead = Contests.list_ward_leads(live_year, [ward_id])[ward_id]

        # A new or redrawn ward has no like-for-like lead to compare with.
        previous_lead =
          if not ward.new_ward and not ward.redrawn,
            do: Contests.list_ward_leads(previous_year, [ward_id])[ward_id]

        nearby_ids = Maps.list_nearby_ward_ids(ward_id)
        # The search's index, shared with it.
        index = Iec.Cache.fetch(:ward_index, &Wards.build_index/0)

        nearby_by_id =
          index.wards |> Enum.filter(&(&1.ward_id in nearby_ids)) |> Map.new(&{&1.ward_id, &1})

        nearby_rows =
          nearby_ids
          |> Enum.flat_map(&List.wrap(nearby_by_id[&1]))
          |> TableRows.ward_result_rows(Maps.list_area_results(:ward, nearby_ids), parties)

        municipality_name = municipality && municipality.area_name
        party_rows = TableRows.with_party_name(ward.parties, parties, :party_id, :party)

        council_trend =
          Results.list_snapshots_by_election(:municipality, ward.municipality_id)
          |> Trends.series(:vote_percentage, parties, limit: 4)

        %{
          page_title:
            IecWeb.WardNames.label(ward.ward_id, ward.ward_number) <>
              if(municipality_name, do: " · #{municipality_name}", else: ""),
          ward_label: IecWeb.WardNames.label(ward.ward_id, ward.ward_number),
          ward: ward,
          municipality: municipality,
          province_name:
            municipality && Results.get_area_name(:province, municipality.province_id),
          summary: Narrative.ward(ward, lead, parties, previous_year),
          lead: lead,
          previous_lead: previous_lead,
          # Towns and suburbs whose point lies in the ward, the biggest first.
          places: ward_id |> Places.list_ward_places() |> Enum.take(8),
          party_rows: party_rows,
          trend: Trends.from_shares(party_rows, parties, {previous_year, live_year}),
          council_trend: council_trend,
          counting: lead == nil or not lead.declared,
          council_counting: municipality == nil or municipality.municipalities_complete != 1,
          nearby_ids: nearby_ids,
          nearby_rows: nearby_rows,
          control: control[{live_year, ward.municipality_id}],
          previous_control: control[{previous_year, ward.municipality_id}],
          council_complete: municipality != nil and municipality.municipalities_complete == 1
        }
    end
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
      <.page_header :if={is_nil(@ward)} eyebrow="Ward" title="Not found">
        <:breadcrumb><.link navigate={~p"/"} class="link-hover link">Overview</.link> /</:breadcrumb>
        <:lede>
          There is no such ward in the {@live_year} ward directory.
          <.link navigate={~p"/wards"} class="link">Find your ward</.link>
        </:lede>
      </.page_header>

      <div :if={@ward} class="space-y-12">
        <.page_header
          eyebrow={(@summary && @summary.eyebrow) || "No results yet"}
          live={@summary != nil and @summary.live}
          title={@ward_label}
        >
          <:breadcrumb>
            <.link navigate={~p"/"} class="link-hover link">Overview</.link>
            /
            <span :if={@municipality}>
              <.link
                navigate={~p"/provinces/#{@municipality.province_id}"}
                class="link-hover link"
              >
                {@province_name}
              </.link>
              /
              <.link
                navigate={~p"/municipalities/#{@ward.municipality_id}"}
                class="link-hover link"
              >
                {@municipality.area_name}
              </.link>
              /
            </span>
          </:breadcrumb>
          <:lede :if={@summary}>{@summary.headline}. {@summary.lede}</:lede>
          <:lede :if={@places != []}>
            <span id="ward-places" class="block text-base text-base-content/60">
              Takes in {join_names(@places)}.
            </span>
          </:lede>
          <:lede :if={is_nil(@summary)}>
            No party has votes in this ward yet. It fills in as the party files report.
          </:lede>
        </.page_header>

        <section class="panel space-y-8 p-5 sm:p-7">
          <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
          <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-4">
            <div class="min-w-0">
              <div class="eyebrow">
                {if @lead && @lead.declared, do: "Winner", else: "Leading"}
              </div>
              <div class="mt-2 space-y-1">
                <.party_or_dash
                  parties={@parties}
                  party_id={@lead && @lead.leader_id}
                  empty="no results yet"
                />
                <div :if={@lead} class="text-sm tabular-nums text-base-content/60">
                  {format_percentage(@lead.leader_share)}
                  <span :if={@ward.declared_at}>
                    · declared <.declared_at ward={@ward} />
                  </span>
                </div>
              </div>
            </div>
            <.kpi
              label="Lead"
              value={format_points(@lead && @lead.margin)}
            >
              <span :if={@previous_lead && @previous_lead.margin}>
                {format_points(@previous_lead.margin)} in {@previous_year}
              </span>
              <span :if={@ward.new_ward}>new ward</span>
              <span :if={@ward.redrawn}>redrawn since {@previous_year}</span>
            </.kpi>
            <div class="min-w-0">
              <div class="eyebrow">Won in {@previous_year}</div>
              <div class="mt-2 space-y-1">
                <.party_or_dash
                  parties={@parties}
                  party_id={@ward.previous_holder}
                  empty={if @ward.new_ward, do: "new ward", else: "–"}
                />
                <div :if={@ward.previous_share} class="text-sm tabular-nums text-base-content/60">
                  {format_percentage(@ward.previous_share)}
                  <span :if={@ward.redrawn}>· old boundary</span>
                </div>
              </div>
            </div>
            <div class="min-w-0">
              <div class="eyebrow">Council {if @council_complete, do: "now", else: "so far"}</div>
              <div class="mt-2 space-y-1">
                <.council_control
                  parties={@parties}
                  control={@control}
                  counting={not @council_complete}
                />
                <div class="flex flex-wrap items-center gap-1.5 text-sm text-base-content/60">
                  {@previous_year}:
                  <.council_control parties={@parties} control={@previous_control} />
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="grid gap-6 lg:grid-cols-2">
          <div :if={@trend.series != []} class="space-y-3">
            <.section_heading title={"This ward since #{@previous_year}"}>
              <:subtitle>
                {cond do
                  @ward.new_ward -> "A new ward: #{@live_year} only"
                  @ward.redrawn -> "Redrawn since #{@previous_year}: that line is its old boundary"
                  true -> "Share of the ward's votes, the biggest parties"
                end}
              </:subtitle>
            </.section_heading>
            <div class="panel p-5 sm:p-6">
              <.line_chart
                id="ward-trend"
                trend={@trend}
                live_year={@live_year}
                counting={@counting}
              />
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
                counting={@council_counting}
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
      </div>
    </Layouts.app>
    """
  end

  # "A, B and C".
  defp join_names([only]), do: only

  defp join_names(names),
    do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :redrawn, :boolean, required: true
  attr :shown, :integer, required: true
  attr :sorts, :map, required: true

  # Each party's share of the ward now and before, from the party files.
  defp ward_party_table(assigns) do
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
            <.sort_header table={@id} column="council_share" sorts={@sorts} align="right">
              Council
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @visible} id={"#{@id}-#{row.party_id}"}>
            <td>
              <.party_label parties={@parties} party_result={row} />
              <span :if={row.won} class="badge badge-success badge-sm ml-2">won</span>
            </td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
              <span :if={row.previous_won} title={"Won the ward in #{@previous_year}"}>✓</span>
            </td>
            <td class={["text-right tabular-nums", delta_class(row.swing)]}>
              {format_delta(row.swing, :points)}
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.council_share)}
            </td>
          </tr>
        </tbody>
      </table>
      <.show_more table={@id} shown={length(@visible)} total={@total} />
      <p class="mt-2 text-sm opacity-60">
        Shares are of all the ward's votes, from the party files of the parties the app
        follows; the seat goes to whoever wins the ward ballot. Council: the party's share
        across the whole municipality.
        <span :if={@redrawn}>
          The ward was redrawn since {@previous_year}: those figures are for its old boundary.
        </span>
      </p>
    </div>
    """
  end
end
