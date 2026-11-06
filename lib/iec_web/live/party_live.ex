defmodule IecWeb.PartyLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Parties, Results}
  alias IecWeb.{LiveUpdates, Narrative, PartySummary}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results, :parties]}

  # Long lists open collapsed, and show this many rows until "Show all".
  @collapsed_by_default ["municipalities-kept", "wards-won-new", "wards-pending", "wards-held"]
  @row_limit 25

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    previous_year = Results.previous_year()

    {:ok,
     socket
     |> assign(
       party_id: IecWeb.Params.id(id),
       previous_year: previous_year,
       sections: PartySummary.sections(Results.live_year(), previous_year),
       closed_sections: MapSet.new(@collapsed_by_default),
       expanded_sections: MapSet.new()
     )
     |> refresh()}
  end

  @impl LiveUpdates
  def refresh(%{assigns: %{party_id: nil}} = socket),
    do: assign(socket, page_title: "Party", found: false)

  def refresh(socket),
    do: LiveUpdates.assign_cached(socket, {__MODULE__, socket.assigns.party_id}, &load/1)

  defp load(assigns) do
    %{party_id: party_id, parties: parties, previous_year: previous_year} = assigns
    overview = Parties.get_party_overview(party_id)
    name = party_abbreviation(parties, %{party_id: party_id})

    summary =
      PartySummary.build(
        overview,
        parties,
        Results.list_area_names(:province),
        assigns.sections
      )

    %{
      # A party is known from the IEC's party lists, or from results before those load.
      found:
        Map.has_key?(parties, party_id) or overview.wards != [] or overview.municipalities != [],
      page_title: name,
      stats: summary.stats,
      lede: Narrative.party(summary.stats, name, previous_year),
      breakdowns: summary.breakdowns,
      province_rows: summary.provinces,
      section_rows: summary.section_rows,
      has_wards: overview.wards != []
    }
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_section", %{"section" => section}, socket) do
    {:noreply, update(socket, :closed_sections, &toggle(&1, section))}
  end

  def handle_event("show_all", %{"section" => section}, socket) do
    {:noreply, update(socket, :expanded_sections, &MapSet.put(&1, section))}
  end

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp toggle(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  @impl Phoenix.LiveView
  def render(%{found: false} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.not_found eyebrow="Party">
        No party on the IEC's lists has this id. Every party name on the site links to its page.
      </.not_found>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        council_sections: Enum.map(assigns.sections.councils, &section_view(assigns, &1)),
        ward_sections: Enum.map(assigns.sections.wards, &section_view(assigns, &1))
      )

    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header
        accent={party_colour(@parties, %{party_id: @party_id})}
        eyebrow={(@parties[@party_id] && @parties[@party_id].name) || "Party"}
        title={@page_title}
        crumbs={[{"Overview", ~p"/"}]}
      >
        <:lede :if={@lede}>{@lede}</:lede>
      </.page_header>

      <.stats stats={@stats} previous_year={@previous_year} counting={counting?(@count_progress)} />

      <section id="at-a-glance" class="space-y-4">
        <.section_heading title="At a glance">
          <:subtitle>Who it lost to, who it gained from, and where</:subtitle>
        </.section_heading>
        <div class="grid gap-4 lg:grid-cols-2">
          <.breakdown_card
            id="wards-lost-to"
            title="Wards lost to"
            total={@stats.wards_lost}
            items={@breakdowns.wards_lost_to}
            parties={@parties}
          />
          <.breakdown_card
            id="wards-gained-from"
            title="Wards gained from"
            total={@stats.wards_gained}
            items={@breakdowns.wards_gained_from}
            parties={@parties}
            footnote={"plus #{@breakdowns.new_wards} new or redrawn wards won, not compared"}
          />
          <.breakdown_card
            id="councils-lost-to"
            title="Council majorities lost to"
            total={@stats.councils_lost}
            items={@breakdowns.councils_lost_to}
            parties={@parties}
          />
          <.breakdown_card
            id="councils-gained-from"
            title="Council majorities gained from"
            total={@stats.councils_gained}
            items={@breakdowns.councils_gained_from}
            parties={@parties}
          />
        </div>

        <div :if={@province_rows != []} class="panel p-2 sm:p-4">
          <.province_table rows={@province_rows} sorts={@sorts} />
        </div>
      </section>

      <section class="space-y-6">
        <.section_heading title="Councils">
          <:subtitle>Council majorities against {@previous_year}</:subtitle>
        </.section_heading>
        <.council_section
          :for={view <- @council_sections}
          view={view}
          parties={@parties}
          party_id={@party_id}
          previous_year={@previous_year}
          sorts={@sorts}
        />
      </section>

      <section class="space-y-6">
        <.section_heading title="Wards">
          <:subtitle>Ward seats against {@previous_year}</:subtitle>
        </.section_heading>
        <.empty :if={not @has_wards}>
          No ward results yet; they fill in as the party files report.
        </.empty>
        <.ward_section
          :for={view <- @ward_sections}
          view={view}
          parties={@parties}
          previous_year={@previous_year}
          sorts={@sorts}
        />
      </section>
    </Layouts.app>
    """
  end

  # A section's rows in the chosen order: the first 25, or all after "Show all".
  defp section_view(assigns, section) do
    rows = assigns.section_rows[section.id] || []

    limit =
      if MapSet.member?(assigns.expanded_sections, section.id), do: length(rows), else: @row_limit

    %{
      section: section,
      page: sorted_page(rows, assigns.sorts[section.id], limit),
      open: not MapSet.member?(assigns.closed_sections, section.id)
    }
  end

  attr :stats, :map, required: true
  attr :previous_year, :integer, required: true
  attr :counting, :boolean, default: false, doc: "running totals, set against final ones"

  defp stats(assigns) do
    assigns = assign(assigns, :so_far, if(assigns.counting, do: " so far", else: ""))

    ~H"""
    <section id="party-stats" class="panel grid grid-cols-2 gap-x-6 gap-y-7 p-5 sm:p-7 lg:grid-cols-4">
      <.kpi label={"Votes#{@so_far}"} value={format_number(@stats.votes)}>
        {@previous_year}: {format_number(@stats.previous_votes)}
      </.kpi>
      <.kpi label="Share" value={format_percentage(@stats.share)}>
        <span class={delta_class(@stats.swing)}>{format_delta(@stats.swing, :points)} pts</span>
        vs {format_percentage(@stats.previous_share)}
      </.kpi>
      <.kpi label={"Seats#{@so_far}"} value={format_number(@stats.seats)}>
        {@previous_year}: {format_number(@stats.previous_seats)}
      </.kpi>
      <.kpi label={"Ward seats#{@so_far}"} value={format_number(@stats.ward_seats)}>
        {@previous_year}: {format_number(@stats.previous_ward_seats)}
      </.kpi>
      <.kpi label="Majority councils" value={format_number(@stats.majorities)}>
        {@previous_year}: {format_number(@stats.previous_majorities)}
      </.kpi>
      <.kpi
        label="Councils gained / lost"
        value={"#{@stats.councils_gained} / #{@stats.councils_lost}"}
      >
        {@stats.councils_kept} kept · {@stats.councils_pending} counting
      </.kpi>
      <.kpi label="Wards gained / lost" value={"#{@stats.wards_gained} / #{@stats.wards_lost}"}>
        {@stats.wards_held} held · {@stats.wards_won_new} new or redrawn · {@stats.wards_pending} not declared
      </.kpi>
      <.kpi label="Wards contested" value={format_number(@stats.wards_contested)}>
        in {@stats.municipalities_contested} municipalities
      </.kpi>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :total, :integer, required: true
  attr :items, :list, required: true, doc: "`{party_id | :hung | nil, count}`, most first"
  attr :parties, :map, required: true
  attr :footnote, :string, default: nil

  # A stacked bar of where the wards or councils went (or came from), with a legend.
  defp breakdown_card(assigns) do
    ~H"""
    <div id={@id} class="panel space-y-3 p-5">
      <div class="flex items-baseline justify-between">
        <h3 class="font-medium">{@title}</h3>
        <span class="text-2xl tabular-nums">{@total}</span>
      </div>
      <div :if={@items != []} class="flex h-3 w-full overflow-hidden rounded-full bg-base-200">
        <div
          :for={{key, count} <- @items}
          style={"width: #{count / max(@total, 1) * 100}%; background-color: #{breakdown_colour(@parties, key)}"}
          title={"#{breakdown_label(@parties, key)}: #{count}"}
        />
      </div>
      <ul class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
        <li :for={{key, count} <- @items} class="inline-flex items-center gap-2">
          <.party_label :if={is_integer(key)} parties={@parties} party_result={%{party_id: key}} />
          <span :if={key == :hung} class="badge badge-warning badge-sm">hung</span>
          <span :if={is_nil(key)} class="opacity-60">another party</span>
          <span class="tabular-nums">{count}</span>
        </li>
      </ul>
      <p :if={@items == []} class="text-sm opacity-60">None so far.</p>
      <p :if={@footnote} class="text-sm opacity-60">{@footnote}</p>
    </div>
    """
  end

  defp breakdown_colour(parties, party_id) when is_integer(party_id),
    do: party_colour(parties, %{party_id: party_id})

  defp breakdown_colour(_parties, :hung), do: "var(--color-warning)"
  defp breakdown_colour(_parties, nil), do: "var(--color-base-300)"

  defp breakdown_label(parties, party_id) when is_integer(party_id),
    do: party_abbreviation(parties, %{party_id: party_id})

  defp breakdown_label(_parties, :hung), do: "hung"
  defp breakdown_label(_parties, nil), do: "another party"

  attr :rows, :list, required: true
  attr :sorts, :map, required: true

  defp province_table(assigns) do
    ~H"""
    <.sortable_table
      id="province-summary"
      rows={@rows}
      sorts={@sorts}
      row_id={&"province-summary-#{&1.province_id}"}
    >
      <:column :let={province} label="Province" field="name" first="asc">
        <.link
          :if={province.province_id}
          navigate={~p"/provinces/#{province.province_id}"}
          class="link"
        >
          {province.name}
        </.link>
        <span :if={is_nil(province.province_id)}>{province.name}</span>
      </:column>
      <:column :let={province} label="Wards gained" field="wards_gained" align="right">
        {province.wards_gained}
      </:column>
      <:column :let={province} label="Wards lost" field="wards_lost" align="right">
        {province.wards_lost}
      </:column>
      <:column
        :let={province}
        label="Net"
        field="net"
        align="right"
        class={&["font-medium", delta_class(&1.net)]}
      >
        {format_delta(province.net, :count)}
      </:column>
      <:column :let={province} label="Councils gained" field="councils_gained" align="right">
        {province.councils_gained}
      </:column>
      <:column :let={province} label="Councils lost" field="councils_lost" align="right">
        {province.councils_lost}
      </:column>
    </.sortable_table>
    """
  end

  attr :view, :map, required: true, doc: "`%{section, page, open}`"
  attr :parties, :map, required: true
  attr :party_id, :integer, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  defp council_section(assigns) do
    assigns = assign(assigns, section: assigns.view.section, page: assigns.view.page)

    ~H"""
    <section id={@section.id} class="panel px-4 py-3">
      <.section_toggle id={@section.id} title={@section.title} count={@page.total} open={@view.open} />
      <.sortable_table
        :if={@view.open and @page.total > 0}
        sort_key={@section.id}
        rows={@page.rows}
        sorts={@sorts}
        sorted
        row_id={&"#{@section.id}-#{&1.municipality_id}"}
        class="mt-2"
      >
        <:column :let={row} label="Municipality" field="name" first="asc">
          <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
            {row.name}
          </.link>
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
        <:column
          :let={row}
          :if={@section.other}
          label={@section.other}
          field="other_label"
          first="asc"
        >
          <.council_control
            parties={@parties}
            party_id={@party_id}
            control={row.other}
            counting={@section.counting}
          />
        </:column>
        <.show_all id={@section.id} shown={@page.shown} total={@page.total} />
      </.sortable_table>
    </section>
    """
  end

  attr :view, :map, required: true, doc: "`%{section, page, open}`"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  defp ward_section(assigns) do
    assigns = assign(assigns, section: assigns.view.section, page: assigns.view.page)

    ~H"""
    <section id={@section.id} class="panel px-4 py-3">
      <.section_toggle id={@section.id} title={@section.title} count={@page.total} open={@view.open} />
      <.sortable_table
        :if={@view.open and @page.total > 0}
        sort_key={@section.id}
        rows={@page.rows}
        sorts={@sorts}
        sorted
        row_id={&"#{@section.id}-#{&1.ward_id}"}
        class="mt-2"
      >
        <:column :let={row} label="Ward" field="ward" first="asc">
          <.link
            :if={row.municipality_id}
            navigate={~p"/municipalities/#{row.municipality_id}"}
            class="link"
          >
            {row.municipality_name}
          </.link>
          <span :if={is_nil(row.municipality_id)}>{row.municipality_name}</span>
          ·
          <.link navigate={~p"/wards/#{row.ward_id}"} class="link">
            <.ward_label number={row.ward_number} name={row.ward_name} />
          </.link>
          <span :if={row.new_ward} class="badge badge-ghost badge-sm">
            {if row.redrawn, do: "redrawn", else: "new ward"}
          </span>
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
        <:column
          :let={row}
          :if={@section.other}
          label={@section.other}
          field="other_label"
          first="asc"
        >
          <.party_or_dash parties={@parties} party_id={row.other} empty="another party" />
        </:column>
        <:column :let={row} label="Declared" field="declared_at" class="tabular-nums opacity-75">
          <.declared_at ward={row} />
        </:column>
        <.show_all id={@section.id} shown={@page.shown} total={@page.total} />
      </.sortable_table>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :open, :boolean, required: true

  defp section_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="flex min-h-10 w-full cursor-pointer items-center gap-2 font-medium"
      phx-click="toggle_section"
      phx-value-section={@id}
      aria-expanded={to_string(@open)}
    >
      <.icon
        name="hero-chevron-right-micro"
        class={["size-4 transition-transform", @open && @count > 0 && "rotate-90"]}
      />
      {@title} <span class="badge badge-sm">{@count}</span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :shown, :integer, required: true
  attr :total, :integer, required: true

  defp show_all(assigns) do
    ~H"""
    <button
      :if={@shown < @total}
      type="button"
      class="btn btn-ghost mt-2 min-h-10"
      phx-click="show_all"
      phx-value-section={@id}
    >
      Show all {@total} <span class="opacity-60">(showing {@shown})</span>
    </button>
    """
  end
end
