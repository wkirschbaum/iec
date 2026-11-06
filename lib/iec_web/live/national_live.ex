defmodule IecWeb.NationalLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.Results
  alias Iec.Results.Change
  alias IecWeb.{ChangeDigest, LiveUpdates, Narrative, TableRows, Trends}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results]}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Overview",
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl LiveUpdates
  def refresh(socket), do: LiveUpdates.assign_cached(socket, {__MODULE__}, &load/1)

  defp load(assigns) do
    %{previous_year: previous_year, parties: parties} = assigns
    national = Results.get_latest_snapshot(:national, 0)
    previous_national = Results.get_latest_snapshot(:national, 0, election: previous_year)
    party_rows = TableRows.party_rows(national, previous_national, parties)

    previous_provinces =
      Results.list_latest_snapshots(election: previous_year, level: :province)
      |> Map.new(&{&1.area_id, &1})

    national_history = Results.list_snapshots_by_election(:national, 0)

    %{
      national: national,
      share_points: Trends.points_by_party(national_history),
      # Each province's parties across elections, for the cards' sparklines.
      province_points: Trends.points_by_area(Results.list_snapshots_by_election(:province)),
      summary: Narrative.summary(national, party_rows, parties, previous_year),
      trend: Trends.series(national_history, :vote_percentage, parties, threshold: 4, limit: 5),
      counting: counting?(national),
      party_rows: party_rows,
      standings: party_rows |> Enum.filter(&(&1.party_id >= 0)) |> Enum.take(8),
      province_rows:
        Results.list_latest_snapshots(level: :province)
        |> TableRows.area_rows(previous_provinces, parties)
        |> Enum.sort_by(& &1.name),
      highlights:
        Results.list_changes(changed_only: true, limit: 300)
        |> Enum.map(&Change.compare/1)
        |> ChangeDigest.highlights()
        |> Enum.take(6)
    }
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:national}
    >
      <.page_header
        eyebrow={(@summary && @summary.eyebrow) || "Local Government Elections #{@live_year}"}
        live={@summary != nil and @summary.live}
        title={(@summary && @summary.headline) || "Waiting for the first results"}
      >
        <:lede :if={@summary}>{@summary.lede}</:lede>
        <:lede :if={is_nil(@summary)}>
          The first poll of the IEC's results runs a few seconds after start-up.
        </:lede>
      </.page_header>

      <section :if={@national} class="panel space-y-8 p-5 sm:p-7">
        <.vote_share_bar rows={@party_rows} parties={@parties} previous_year={@previous_year} />
        <div class="grid grid-cols-2 gap-6 border-t border-base-300 pt-6 lg:grid-cols-5">
          <.count_kpis snapshot={@national}>
            <:votes_note>of {format_compact(@national.registered_voters)} registered</:votes_note>
          </.count_kpis>
          <.kpi
            label="Wards declared"
            value={format_number(@national.wards_complete)}
            class="col-span-2 lg:col-span-1"
          >
            of {format_number(@national.wards_expected)}
          </.kpi>
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-5">
        <div class="space-y-4 lg:col-span-3">
          <.section_heading title="Who leads where">
            <:subtitle>Each municipality in its leading party's colour</:subtitle>
            <:actions>
              <.link navigate={~p"/map"} class="link-hover link">Open the map →</.link>
            </:actions>
          </.section_heading>
          <.live_component
            module={IecWeb.MapComponent}
            id="national-map"
            level={:municipality}
            parties={@parties}
            refreshed_at={@refreshed_at}
          />
        </div>

        <div class="space-y-4 lg:col-span-2">
          <.section_heading title="Standings">
            <:subtitle>Share of the vote, change since {@previous_year}</:subtitle>
          </.section_heading>
          <ol class="panel divide-y divide-base-300 overflow-hidden">
            <li :for={{row, rank} <- Enum.with_index(@standings, 1)}>
              <.standing
                row={row}
                rank={rank}
                points={@share_points[row.party_id] || []}
                parties={@parties}
              />
            </li>
          </ol>
        </div>
      </section>

      <section :if={length(@trend.years) > 1} class="space-y-4">
        <.section_heading title={"Since #{List.first(@trend.years)}"}>
          <:subtitle>Share of the vote in every local election</:subtitle>
          <:actions>
            <.link navigate={~p"/trends"} class="link-hover link">All trends →</.link>
          </:actions>
        </.section_heading>
        <div class="panel p-5 sm:p-7">
          <.line_chart
            id="national-trend"
            trend={@trend}
            live_year={@live_year}
            counting={@counting}
          />
        </div>
      </section>

      <section :if={@province_rows != []} class="space-y-4">
        <.section_heading title="Provinces">
          <:subtitle>Leading party, share and how far each count is</:subtitle>
        </.section_heading>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.province_card
            :for={province <- @province_rows}
            province={province}
            points={get_in(@province_points, [province.area_id, province.leader_id]) || []}
            parties={@parties}
            previous_year={@previous_year}
          />
        </div>
      </section>

      <.highlights highlights={@highlights} parties={@parties} />

      <section :if={@national} class="space-y-4">
        <.section_heading title="All parties">
          <:subtitle>Click a heading to sort</:subtitle>
        </.section_heading>
        <div class="panel p-2 sm:p-4">
          <.party_table
            id="national-parties"
            rows={@party_rows}
            parties={@parties}
            previous_year={@previous_year}
            sorts={@sorts}
            show_councils
          />
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true, doc: "a party row"
  attr :rank, :integer, required: true
  attr :points, :list, required: true, doc: "its share in each election"
  attr :parties, :map, required: true

  # A party in the standings: its share, seats, swing and the long run as a sparkline.
  defp standing(assigns) do
    assigns = assign(assigns, :colour, party_colour(assigns.parties, assigns.row))

    ~H"""
    <.link_row navigate={~p"/parties/#{@row.party_id}"} class="py-3">
      <span class="w-4 text-right text-xs tabular-nums text-base-content/40">{@rank}</span>
      <span class="h-8 w-1 rounded-full" style={"background-color: #{@colour}"} />
      <span class="min-w-0 flex-1">
        <span class="block truncate font-medium">{@row.party}</span>
        <span class="block text-xs tabular-nums text-base-content/55">
          {format_number(@row.seats)} seats
        </span>
      </span>
      <.sparkline
        points={@points}
        colour={@colour}
        label={@row.party}
        class="hidden h-7 w-16 sm:block"
      />
      <span class="text-right">
        <span class="block font-serif text-xl tabular-nums leading-none">
          {format_percentage(@row.share)}
        </span>
        <.swing_chip value={@row.swing} class="mt-1" />
      </span>
    </.link_row>
    """
  end

  attr :province, :map, required: true
  attr :points, :list, default: [], doc: "the leader's share in each election"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true

  defp province_card(assigns) do
    assigns =
      assign(
        assigns,
        :colour,
        assigns.province.leader_id &&
          party_colour(assigns.parties, %{party_id: assigns.province.leader_id})
      )

    ~H"""
    <.link_card
      navigate={~p"/provinces/#{@province.area_id}"}
      id={"province-card-#{@province.area_id}"}
      class="block space-y-4 p-5"
    >
      <div class="flex items-start justify-between gap-3">
        <h3 class="text-lg font-medium leading-tight">{@province.name}</h3>
        <span class="text-xs tabular-nums text-base-content/55">
          {format_progress(@province.counted)} counted
        </span>
      </div>
      <div class="flex items-end justify-between gap-3">
        <div>
          <div class="eyebrow">Leading</div>
          <div class="mt-1 flex items-center gap-2">
            <span :if={@colour} class="size-3 rounded-full" style={"background-color: #{@colour}"} />
            <span class="font-medium">{@province.leader || "–"}</span>
          </div>
        </div>
        <div class="flex items-end gap-3">
          <.sparkline
            :if={@colour}
            points={@points}
            colour={@colour}
            label={@province.leader}
            class="mb-0.5 h-7 w-16"
          />
          <div class="font-serif text-3xl tabular-nums leading-none">
            {format_percentage(@province.share)}
          </div>
        </div>
      </div>
      <.mini_share_bar segments={@province.segments} parties={@parties} />
      <div class="flex items-center justify-between text-xs text-base-content/55">
        <span>
          {@previous_year}: {@province.previous_leader || "–"}
          {format_percentage(@province.previous_share)}
        </span>
        <.icon
          name="hero-arrow-right-micro"
          class="size-4 transition-transform group-hover:translate-x-0.5"
        />
      </div>
    </.link_card>
    """
  end
end
