defmodule IecWeb.ContestsLive do
  @moduledoc """
  Close contests: the councils and wards where the first party leads the second by the
  least, live as the count goes on.
  """
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Contests, Results}
  alias IecWeb.{Narrative, TableRows}

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

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

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    parties = socket.assigns.parties
    councils = TableRows.council_contest_rows(Contests.list_council_contests(), parties)
    wards = TableRows.ward_contest_rows(Contests.list_ward_contests(), parties)
    settled = Enum.filter(councils, &(&1.complete or &1.counted >= @minimum_counted))
    counts = %{councils: count_within(councils), wards: count_within(wards)}
    closest_council = List.first(settled)
    closest_ward = List.first(wards)

    assign(socket,
      council_rows: councils,
      ward_rows: wards,
      knife_edge: Enum.take(settled, @cards),
      summary: Narrative.close_contests(closest_council, counts, @within),
      stats: %{
        councils_within: counts.councils,
        councils: length(councils),
        wards_within: counts.wards,
        wards: length(wards),
        closest_council_margin: format_points(closest_council && closest_council.margin),
        closest_council_name: closest_council && closest_council.name,
        closest_ward_margin: format_points(closest_ward && closest_ward.margin),
        closest_ward_name:
          closest_ward &&
            "#{closest_ward.municipality_name} · ward #{closest_ward.ward_number}"
      }
    )
  end

  defp count_within(rows), do: Enum.count(rows, &(&1.margin < @within))

  @impl Phoenix.LiveView
  def handle_event("show_more", %{"table" => table}, socket) when table in @tables do
    {:noreply, update(socket, :shown, &Map.update!(&1, table, fn shown -> shown + @more end))}
  end

  # A table's rows in the chosen order, as many as it shows.
  defp table_view(rows, sort, shown) do
    visible = rows |> sort_rows(sort) |> Enum.take(shown)
    %{rows: visible, shown: length(visible), total: length(rows)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    %{sorts: sorts, shown: shown} = assigns

    assigns =
      assign(assigns,
        council_table:
          table_view(assigns.council_rows, sorts["council-contests"], shown["council-contests"]),
        ward_table: table_view(assigns.ward_rows, sorts["ward-contests"], shown["ward-contests"])
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
        <.kpi label={"Councils within #{@within} pts"} value={format_number(@stats.councils_within)}>
          of {format_number(@stats.councils)} with two parties on the board
        </.kpi>
        <.kpi label={"Wards within #{@within} pts"} value={format_number(@stats.wards_within)}>
          of {format_number(@stats.wards)} contested
        </.kpi>
        <.kpi label="Closest council" value={@stats.closest_council_margin}>
          {@stats.closest_council_name}
        </.kpi>
        <.kpi label="Closest ward" value={@stats.closest_ward_margin}>
          {@stats.closest_ward_name}
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
        <p :if={@council_table.total == 0} class="text-sm opacity-60">No council results yet.</p>
        <div :if={@council_table.total > 0} class="panel overflow-x-auto p-2 sm:p-4">
          <table id="council-contests" class="table table-sm">
            <thead>
              <tr>
                <.sort_header table="council-contests" column="name" sorts={@sorts} first="asc">
                  Municipality
                </.sort_header>
                <.sort_header table="council-contests" column="leader" sorts={@sorts} first="asc">
                  Leader
                </.sort_header>
                <.sort_header table="council-contests" column="runner_up" sorts={@sorts} first="asc">
                  Runner-up
                </.sort_header>
                <.sort_header
                  table="council-contests"
                  column="margin"
                  sorts={@sorts}
                  first="asc"
                  align="right"
                >
                  Lead
                </.sort_header>
                <.sort_header
                  table="council-contests"
                  column="margin_votes"
                  sorts={@sorts}
                  first="asc"
                  align="right"
                >
                  Votes
                </.sort_header>
                <.sort_header
                  table="council-contests"
                  column="previous_margin"
                  sorts={@sorts}
                  first="asc"
                  align="right"
                >
                  {@previous_year}
                </.sort_header>
                <.sort_header
                  table="council-contests"
                  column="margin_change"
                  sorts={@sorts}
                  first="asc"
                  align="right"
                >
                  Change
                </.sort_header>
                <.sort_header table="council-contests" column="counted" sorts={@sorts} align="right">
                  Counted
                </.sort_header>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @council_table.rows} id={"council-contests-#{row.municipality_id}"}>
                <td>
                  <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
                    {row.name}
                  </.link>
                </td>
                <td>
                  <.party_label parties={@parties} party_result={%{party_id: row.leader_id}} />
                </td>
                <td>
                  <.party_label parties={@parties} party_result={%{party_id: row.runner_up_id}} />
                </td>
                <td class="text-right font-medium tabular-nums">{format_points(row.margin)}</td>
                <td class="text-right tabular-nums">{format_number(row.margin_votes)}</td>
                <td class="text-right tabular-nums opacity-60" title={row.previous_leader}>
                  {format_points(row.previous_margin)}
                </td>
                <td class="text-right tabular-nums opacity-80">
                  {format_delta(row.margin_change, :points)}
                </td>
                <td class="text-right tabular-nums opacity-75">{format_progress(row.counted)}</td>
              </tr>
            </tbody>
          </table>
          <.show_more table="council-contests" view={@council_table} />
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
        <p :if={@ward_table.total == 0} class="text-sm opacity-60">No ward results yet.</p>
        <div :if={@ward_table.total > 0} class="panel overflow-x-auto p-2 sm:p-4">
          <table id="ward-contests" class="table table-sm">
            <thead>
              <tr>
                <.sort_header table="ward-contests" column="ward" sorts={@sorts} first="asc">
                  Ward
                </.sort_header>
                <.sort_header table="ward-contests" column="leader" sorts={@sorts} first="asc">
                  Leader
                </.sort_header>
                <.sort_header table="ward-contests" column="leader_share" sorts={@sorts} align="right">
                  Share
                </.sort_header>
                <.sort_header table="ward-contests" column="runner_up" sorts={@sorts} first="asc">
                  Runner-up
                </.sort_header>
                <.sort_header
                  table="ward-contests"
                  column="runner_up_share"
                  sorts={@sorts}
                  align="right"
                >
                  Share
                </.sort_header>
                <.sort_header
                  table="ward-contests"
                  column="margin"
                  sorts={@sorts}
                  first="asc"
                  align="right"
                >
                  Lead
                </.sort_header>
                <.sort_header table="ward-contests" column="status" sorts={@sorts} first="asc">
                  Status
                </.sort_header>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @ward_table.rows} id={"ward-contests-#{row.ward_id}"}>
                <td>
                  <.link
                    :if={row.municipality_id}
                    navigate={~p"/municipalities/#{row.municipality_id}" <> "#ward-#{row.ward_id}"}
                    class="link"
                  >
                    {row.municipality_name} · ward {row.ward_number}
                  </.link>
                  <span :if={is_nil(row.municipality_id)}>ward {row.ward_number}</span>
                  <span :if={row.redrawn} class="badge badge-ghost badge-xs">redrawn</span>
                </td>
                <td>
                  <.party_label parties={@parties} party_result={%{party_id: row.leader_id}} />
                </td>
                <td class="text-right tabular-nums">{format_percentage(row.leader_share)}</td>
                <td>
                  <.party_label parties={@parties} party_result={%{party_id: row.runner_up_id}} />
                </td>
                <td class="text-right tabular-nums">{format_percentage(row.runner_up_share)}</td>
                <td class="text-right font-medium tabular-nums">{format_points(row.margin)}</td>
                <td class="opacity-75">{row.status}</td>
              </tr>
            </tbody>
          </table>
          <.show_more table="ward-contests" view={@ward_table} />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :contest, :map, required: true, doc: "a council contest row"
  attr :parties, :map, required: true

  # One close council: the two leading parties as a tug-of-war bar, and the gap.
  defp contest_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/municipalities/#{@contest.municipality_id}"}
      id={"knife-edge-#{@contest.municipality_id}"}
      class="panel group block space-y-3 p-4 transition hover:-translate-y-0.5"
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
    </.link>
    """
  end

  attr :table, :string, required: true
  attr :view, :map, required: true

  defp show_more(assigns) do
    ~H"""
    <button
      :if={@view.shown < @view.total}
      type="button"
      class="btn btn-ghost btn-sm mt-2"
      phx-click="show_more"
      phx-value-table={@table}
    >
      Show more <span class="opacity-60">({@view.shown} of {@view.total})</span>
    </button>
    """
  end

  defp format_points(nil), do: "–"
  defp format_points(points), do: :erlang.float_to_binary(points / 1, decimals: 2) <> " pts"
end
