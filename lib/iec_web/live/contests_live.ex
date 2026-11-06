defmodule IecWeb.ContestsLive do
  @moduledoc """
  Close contests: the councils and wards where the first party leads the second by the
  least, live as the count goes on.
  """
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Contests, Results}
  alias IecWeb.{LiveUpdates, Narrative, TableRows, WardNames}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results, :parties]}

  # A contest this close (in points) counts as close.
  @within 5
  # The knife-edge cards wait for a tenth of a council's count, so a handful of early
  # districts does not crowd out the real contests.
  @minimum_counted 10
  @cards 6
  # Long tables show this many rows, and this many more on each "Show more".
  @page_size 25
  @more 100

  @tables ["council-contests", "ward-contests"]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Close contests",
       previous_year: Results.previous_year(),
       within: @within,
       shown: Map.new(@tables, &{&1, @page_size})
     )
     |> refresh()}
  end

  @impl LiveUpdates
  def refresh(socket), do: LiveUpdates.assign_cached(socket, {__MODULE__}, &load/1)

  defp load(%{parties: parties}) do
    councils = TableRows.council_contest_rows(Contests.list_council_contests(), parties)
    wards = TableRows.ward_contest_rows(Contests.list_ward_contests(), parties)
    settled = Enum.filter(councils, &(&1.complete or &1.counted >= @minimum_counted))
    counts = %{councils: count_within(councils), wards: count_within(wards)}

    %{
      council_rows: councils,
      ward_rows: wards,
      knife_edge: Enum.take(settled, @cards),
      summary: Narrative.close_contests(List.first(settled), counts, @within),
      counts: counts,
      closest_council: List.first(settled),
      closest_ward: List.first(wards)
    }
  end

  defp count_within(rows), do: Enum.count(rows, &(&1.margin < @within))

  @impl Phoenix.LiveView
  def handle_event("show_more", %{"table" => table}, socket) when table in @tables do
    {:noreply, update(socket, :shown, &Map.update!(&1, table, fn shown -> shown + @more end))}
  end

  # Anything else (a stale or crafted event) changes nothing.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    %{sorts: sorts, shown: shown} = assigns

    assigns =
      assign(assigns,
        council_page:
          sorted_page(assigns.council_rows, sorts["council-contests"], shown["council-contests"]),
        ward_page: sorted_page(assigns.ward_rows, sorts["ward-contests"], shown["ward-contests"])
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:contests}
    >
      <.page_header eyebrow="Margins" title="Close contests">
        <:lede :if={@summary}>{@summary}</:lede>
        <:lede :if={is_nil(@summary)}>
          The councils and wards with the narrowest leads appear here once two parties have
          votes.
        </:lede>
      </.page_header>

      <section
        id="contest-stats"
        class="panel grid grid-cols-2 gap-x-6 gap-y-7 p-5 sm:p-7 lg:grid-cols-4"
      >
        <.kpi label={"Councils within #{@within} pts"} value={format_number(@counts.councils)}>
          of {format_number(length(@council_rows))} with two parties on the board
        </.kpi>
        <.kpi label={"Wards within #{@within} pts"} value={format_number(@counts.wards)}>
          of {format_number(length(@ward_rows))} contested
        </.kpi>
        <.kpi
          label="Closest council"
          value={format_points(@closest_council && @closest_council.margin)}
        >
          <.link
            :if={@closest_council}
            navigate={~p"/municipalities/#{@closest_council.municipality_id}"}
            class="link"
          >
            {@closest_council.name}
          </.link>
        </.kpi>
        <.kpi label="Closest ward" value={format_points(@closest_ward && @closest_ward.margin)}>
          <.link :if={@closest_ward} navigate={~p"/wards/#{@closest_ward.ward_id}"} class="link">
            {@closest_ward.municipality_name} · {WardNames.label(
              @closest_ward.ward_id,
              @closest_ward.ward_number
            )}
          </.link>
        </.kpi>
      </section>

      <section :if={@knife_edge != []} class="space-y-4">
        <.section_heading title="On a knife edge">
          <:subtitle>
            The narrowest council contests with at least a tenth of the count in
          </:subtitle>
          <:actions>
            <.link navigate={~p"/map?mode=margin"} class="link-hover link">
              See them on the map →
            </.link>
          </:actions>
        </.section_heading>
        <div id="knife-edge" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.contest_card :for={contest <- @knife_edge} contest={contest} parties={@parties} />
        </div>
      </section>

      <section class="space-y-4">
        <.section_heading title="Every council, closest first">
          <:subtitle>
            Lead of the first party over the second in votes for the council, and how it
            compares with {@previous_year}
          </:subtitle>
        </.section_heading>
        <.empty :if={@council_page.total == 0}>No council results yet.</.empty>
        <div :if={@council_page.total > 0} class="panel p-2 sm:p-4">
          <.council_table
            page={@council_page}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
          />
        </div>
      </section>

      <section class="space-y-4">
        <.section_heading title="Every ward, closest first">
          <:subtitle>
            Shares of all the ward's votes, from the party files (no vote counts). Wards
            whose winner trails on these shares, such as some won by independents, are
            left out
          </:subtitle>
        </.section_heading>
        <.empty :if={@ward_page.total == 0}>No ward results yet.</.empty>
        <div :if={@ward_page.total > 0} class="panel p-2 sm:p-4">
          <.ward_table page={@ward_page} parties={@parties} sorts={@sorts} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :page, :map, required: true, doc: "from IecWeb.Sorting.sorted_page/3"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  defp council_table(assigns) do
    ~H"""
    <.sortable_table
      id="council-contests"
      rows={@page.rows}
      sorts={@sorts}
      sorted
      row_id={&"council-contests-#{&1.municipality_id}"}
    >
      <:column :let={row} label="Municipality" field="name" first="asc">
        <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
          {row.name}
        </.link>
      </:column>
      <:column :let={row} label="Leader" field="leader" first="asc">
        <.party_label parties={@parties} party_result={%{party_id: row.leader_id}} />
      </:column>
      <:column :let={row} label="Runner-up" field="runner_up" first="asc">
        <.party_label parties={@parties} party_result={%{party_id: row.runner_up_id}} />
      </:column>
      <:column :let={row} label="Lead" field="margin" first="asc" align="right" class="font-medium">
        {format_points(row.margin)}
      </:column>
      <:column :let={row} label="Votes apart" field="margin_votes" first="asc" align="right">
        {format_number(row.margin_votes)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_margin"
        first="asc"
        align="right"
        class="opacity-60"
      >
        <span title={row.previous_leader}>{format_points(row.previous_margin)}</span>
      </:column>
      <:column
        :let={row}
        label="Change"
        field="margin_change"
        first="asc"
        align="right"
        class="opacity-80"
      >
        {format_delta(row.margin_change, :points)}
      </:column>
      <:column :let={row} label="Counted" field="counted" align="right" class="opacity-75">
        {format_progress(row.counted)}
      </:column>
      <.show_more table="council-contests" shown={@page.shown} total={@page.total} />
    </.sortable_table>
    """
  end

  attr :page, :map, required: true, doc: "from IecWeb.Sorting.sorted_page/3"
  attr :parties, :map, required: true
  attr :sorts, :map, required: true

  defp ward_table(assigns) do
    ~H"""
    <.sortable_table
      id="ward-contests"
      rows={@page.rows}
      sorts={@sorts}
      sorted
      row_id={&"ward-contests-#{&1.ward_id}"}
    >
      <:column :let={row} label="Ward" field="ward" first="asc">
        <.link navigate={~p"/wards/#{row.ward_id}"} class="link">
          {if row.municipality_name, do: "#{row.municipality_name} · "}<.ward_label
            number={row.ward_number}
            name={row.ward_name}
          />
        </.link>
        <span :if={row.redrawn} class="badge badge-ghost badge-xs">redrawn</span>
      </:column>
      <:column :let={row} label="Leader" field="leader" first="asc">
        <.party_label parties={@parties} party_result={%{party_id: row.leader_id}} />
      </:column>
      <:column :let={row} label="Leader share" field="leader_share" align="right">
        {format_percentage(row.leader_share)}
      </:column>
      <:column :let={row} label="Runner-up" field="runner_up" first="asc">
        <.party_label parties={@parties} party_result={%{party_id: row.runner_up_id}} />
      </:column>
      <:column :let={row} label="Runner-up share" field="runner_up_share" align="right">
        {format_percentage(row.runner_up_share)}
      </:column>
      <:column :let={row} label="Lead" field="margin" first="asc" align="right" class="font-medium">
        {format_points(row.margin)}
      </:column>
      <:column :let={row} label="Status" field="status" first="asc" class="opacity-75">
        {row.status}
      </:column>
      <.show_more table="ward-contests" shown={@page.shown} total={@page.total} />
    </.sortable_table>
    """
  end

  attr :contest, :map, required: true, doc: "a council contest row"
  attr :parties, :map, required: true

  # One close council: the two leading parties as a tug-of-war bar, and the gap.
  defp contest_card(assigns) do
    ~H"""
    <.link_card
      navigate={~p"/municipalities/#{@contest.municipality_id}"}
      id={"knife-edge-#{@contest.municipality_id}"}
      class="block space-y-3 p-4"
    >
      <div class="flex items-baseline justify-between gap-3">
        <h3 class="truncate font-medium group-hover:underline">{@contest.name}</h3>
        <span class="shrink-0 font-serif text-2xl tabular-nums">{format_points(@contest.margin)}</span>
      </div>
      <div class="flex h-2.5 overflow-hidden rounded-full bg-base-200">
        <div
          class="h-full border-r-2 border-base-100 transition-[width] duration-1000"
          style={"width: #{@contest.leader_width}%; background-color: #{party_colour(@parties, %{party_id: @contest.leader_id})}"}
        />
        <div
          class="h-full flex-1"
          style={"background-color: #{party_colour(@parties, %{party_id: @contest.runner_up_id})}"}
        />
      </div>
      <div class="flex justify-between gap-3 text-sm tabular-nums">
        <span>{@contest.leader} {format_percentage(@contest.leader_share)}</span>
        <span>{@contest.runner_up} {format_percentage(@contest.runner_up_share)}</span>
      </div>
      <p class="text-xs tabular-nums text-base-content/60">
        {format_number(@contest.margin_votes)} votes apart · {format_progress(@contest.counted)} counted
      </p>
    </.link_card>
    """
  end
end
