defmodule IecWeb.PartyLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Parties, Results}
  alias IecWeb.{Narrative, PartySummary}

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  # Long lists open collapsed, and show this many rows until "Show all".
  @collapsed_by_default ["municipalities-kept", "wards-won-new", "wards-pending", "wards-held"]
  @row_limit 25

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    party_id = String.to_integer(id)
    previous_year = Results.previous_year()

    {:ok,
     socket
     |> assign(
       party_id: party_id,
       previous_year: previous_year,
       sections: PartySummary.sections(Results.live_year(), previous_year),
       closed_sections: MapSet.new(@collapsed_by_default),
       expanded_sections: MapSet.new()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    assign(socket, Iec.Cache.fetch(cache_key(socket.assigns), fn -> load(socket.assigns) end))
  end

  # Computed once per data change and shared by everyone viewing the same page.
  defp cache_key(assigns), do: {__MODULE__, assigns.party_id}

  defp load(assigns) do
    %{party_id: party_id, parties: parties} = assigns
    overview = Parties.get_party_overview(party_id)

    summary =
      PartySummary.build(
        overview,
        parties,
        Results.list_area_names(:province),
        assigns.sections
      )

    Map.new(
      page_title: party_abbreviation(parties, %{party_id: party_id}),
      stats: summary.stats,
      lede:
        Narrative.party(
          summary.stats,
          party_abbreviation(parties, %{party_id: party_id}),
          assigns.previous_year
        ),
      breakdowns: summary.breakdowns,
      province_rows: summary.provinces,
      section_rows: summary.section_rows,
      has_wards: overview.wards != []
    )
  end

  @impl Phoenix.LiveView
  def handle_event("toggle_section", %{"section" => section}, socket) do
    {:noreply, update(socket, :closed_sections, &toggle(&1, section))}
  end

  def handle_event("show_all", %{"section" => section}, socket) do
    {:noreply, update(socket, :expanded_sections, &MapSet.put(&1, section))}
  end

  defp toggle(set, member) do
    if MapSet.member?(set, member), do: MapSet.delete(set, member), else: MapSet.put(set, member)
  end

  @impl Phoenix.LiveView
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
        title={party_abbreviation(@parties, %{party_id: @party_id})}
      >
        <:breadcrumb><.link navigate={~p"/"} class="link-hover link">Overview</.link> /</:breadcrumb>
        <:lede :if={@lede}>{@lede}</:lede>
      </.page_header>

      <.stats stats={@stats} previous_year={@previous_year} />

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
          section={view.section}
          rows={view.rows}
          total={view.total}
          open={view.open}
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
        <p :if={not @has_wards} class="opacity-60">
          No ward results yet. The party file is fetched when the page opens.
        </p>
        <.ward_section
          :for={view <- @ward_sections}
          section={view.section}
          rows={view.rows}
          total={view.total}
          open={view.open}
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
    rows = sort_rows(assigns.section_rows[section.id] || [], assigns.sorts[section.id])
    expanded = MapSet.member?(assigns.expanded_sections, section.id)

    %{
      section: section,
      rows: if(expanded, do: rows, else: Enum.take(rows, @row_limit)),
      total: length(rows),
      open: not MapSet.member?(assigns.closed_sections, section.id)
    }
  end

  attr :stats, :map, required: true
  attr :previous_year, :integer, required: true

  defp stats(assigns) do
    ~H"""
    <section id="party-stats" class="panel grid grid-cols-2 gap-x-6 gap-y-7 p-5 sm:p-7 lg:grid-cols-4">
      <.kpi label="Votes" value={format_number(@stats.votes)}>
        {@previous_year}: {format_number(@stats.previous_votes)}
      </.kpi>
      <.kpi label="Share" value={format_percentage(@stats.share)}>
        <span class={delta_class(@stats.swing)}>{format_delta(@stats.swing, :points)} pp</span>
        vs {format_percentage(@stats.previous_share)}
      </.kpi>
      <.kpi label="Seats" value={format_number(@stats.seats)}>
        {@previous_year}: {format_number(@stats.previous_seats)}
      </.kpi>
      <.kpi label="Ward seats" value={format_number(@stats.ward_seats)}>
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
    <div class="overflow-x-auto">
      <table id="province-summary" class="table table-sm">
        <thead>
          <tr>
            <.sort_header table="province-summary" column="name" sorts={@sorts} first="asc">
              Province
            </.sort_header>
            <.sort_header table="province-summary" column="wards_gained" sorts={@sorts} align="right">
              Wards gained
            </.sort_header>
            <.sort_header table="province-summary" column="wards_lost" sorts={@sorts} align="right">
              Wards lost
            </.sort_header>
            <.sort_header table="province-summary" column="net" sorts={@sorts} align="right">
              Net
            </.sort_header>
            <.sort_header
              table="province-summary"
              column="councils_gained"
              sorts={@sorts}
              align="right"
            >
              Councils gained
            </.sort_header>
            <.sort_header table="province-summary" column="councils_lost" sorts={@sorts} align="right">
              Councils lost
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={province <- sort_rows(@rows, @sorts["province-summary"])}
            id={"province-summary-#{province.province_id}"}
          >
            <td>
              <.link
                :if={province.province_id}
                navigate={~p"/provinces/#{province.province_id}"}
                class="link"
              >
                {province.name}
              </.link>
              <span :if={is_nil(province.province_id)}>{province.name}</span>
            </td>
            <td class="text-right tabular-nums">{province.wards_gained}</td>
            <td class="text-right tabular-nums">{province.wards_lost}</td>
            <td class={["text-right tabular-nums font-medium", delta_class(province.net)]}>
              {format_delta(province.net, :count)}
            </td>
            <td class="text-right tabular-nums">{province.councils_gained}</td>
            <td class="text-right tabular-nums">{province.councils_lost}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :rows, :list, required: true
  attr :total, :integer, required: true
  attr :open, :boolean, required: true
  attr :parties, :map, required: true
  attr :party_id, :integer, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  defp council_section(assigns) do
    ~H"""
    <section id={@section.id} class="panel px-4 py-3">
      <.section_toggle id={@section.id} title={@section.title} count={@total} open={@open} />
      <div :if={@open and @total > 0} class="overflow-x-auto mt-2">
        <table class="table table-sm">
          <thead>
            <tr>
              <.sort_header table={@section.id} column="name" sorts={@sorts} first="asc">
                Municipality
              </.sort_header>
              <.sort_header table={@section.id} column="share" sorts={@sorts} align="right">
                Share
              </.sort_header>
              <.sort_header table={@section.id} column="previous_share" sorts={@sorts} align="right">
                {@previous_year}
              </.sort_header>
              <.sort_header table={@section.id} column="swing" sorts={@sorts} align="right">
                Swing
              </.sort_header>
              <.sort_header table={@section.id} column="seats" sorts={@sorts} align="right">
                Seats
              </.sort_header>
              <.sort_header table={@section.id} column="previous_seats" sorts={@sorts} align="right">
                {@previous_year}
              </.sort_header>
              <.sort_header
                :if={@section.other}
                table={@section.id}
                column="other_label"
                sorts={@sorts}
                first="asc"
              >
                {@section.other}
              </.sort_header>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@section.id}-#{row.municipality_id}"}>
              <td>
                <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
                  {row.name}
                </.link>
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
              <td :if={@section.other}>
                <.council_control
                  parties={@parties}
                  party_id={@party_id}
                  control={row.other}
                  counting={@section.counting}
                />
              </td>
            </tr>
          </tbody>
        </table>
        <.show_all id={@section.id} shown={length(@rows)} total={@total} />
      </div>
    </section>
    """
  end

  attr :section, :map, required: true
  attr :rows, :list, required: true
  attr :total, :integer, required: true
  attr :open, :boolean, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  defp ward_section(assigns) do
    ~H"""
    <section id={@section.id} class="panel px-4 py-3">
      <.section_toggle id={@section.id} title={@section.title} count={@total} open={@open} />
      <div :if={@open and @total > 0} class="overflow-x-auto mt-2">
        <table class="table table-sm">
          <thead>
            <tr>
              <.sort_header table={@section.id} column="ward" sorts={@sorts} first="asc">
                Ward
              </.sort_header>
              <.sort_header table={@section.id} column="share" sorts={@sorts} align="right">
                Share
              </.sort_header>
              <.sort_header table={@section.id} column="previous_share" sorts={@sorts} align="right">
                {@previous_year}
              </.sort_header>
              <.sort_header table={@section.id} column="swing" sorts={@sorts} align="right">
                Swing
              </.sort_header>
              <.sort_header
                :if={@section.other}
                table={@section.id}
                column="other_label"
                sorts={@sorts}
                first="asc"
              >
                {@section.other}
              </.sort_header>
              <.sort_header table={@section.id} column="declared_at" sorts={@sorts}>
                Declared
              </.sort_header>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"#{@section.id}-#{row.ward_id}"}>
              <td>
                <.link
                  :if={row.municipality_id}
                  navigate={~p"/municipalities/#{row.municipality_id}"}
                  class="link"
                >
                  {row.municipality_name}
                </.link>
                <span :if={is_nil(row.municipality_id)}>{row.municipality_name}</span>
                · ward {row.ward_number}
                <span :if={row.new_ward} class="badge badge-ghost badge-sm">
                  {if row.redrawn, do: "redrawn", else: "new ward"}
                </span>
              </td>
              <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
              <td class="text-right tabular-nums opacity-60">
                {format_percentage(row.previous_share)}
              </td>
              <td class={["text-right tabular-nums", delta_class(row.swing)]}>
                {format_delta(row.swing, :points)}
              </td>
              <td :if={@section.other}>
                <.party_or_dash
                  parties={@parties}
                  party_id={row.other}
                  empty="another party"
                />
              </td>
              <td class="tabular-nums opacity-75"><.declared_at ward={row} /></td>
            </tr>
          </tbody>
        </table>
        <.show_all id={@section.id} shown={length(@rows)} total={@total} />
      </div>
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
      class="flex cursor-pointer items-center gap-2 font-medium"
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
      class="btn btn-ghost btn-sm mt-2"
      phx-click="show_all"
      phx-value-section={@id}
    >
      Show all {@total} <span class="opacity-60">(showing {@shown})</span>
    </button>
    """
  end
end
