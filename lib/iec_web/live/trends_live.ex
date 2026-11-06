defmodule IecWeb.TrendsLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents
  import IecWeb.ChartComponents

  alias Iec.Results
  alias IecWeb.{LiveUpdates, Trends}

  @behaviour LiveUpdates
  on_mount {LiveUpdates, [:results]}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Trends", live_year: Results.live_year()) |> refresh()}
  end

  @impl LiveUpdates
  def refresh(socket), do: LiveUpdates.assign_cached(socket, {__MODULE__}, &load/1)

  defp load(%{parties: parties, live_year: live_year}) do
    national = Results.list_snapshots_by_election(:national, 0)
    share = Trends.series(national, :vote_percentage, parties, threshold: 2.5)
    {_year, live_national} = List.keyfind(national, live_year, 0, {live_year, nil})
    counting = counting?(live_national)
    province_names = Results.list_area_names(:province)

    provinces =
      for {province_id, snapshots} <- Results.list_snapshots_by_election(:province),
          province_names[province_id] do
        %{
          id: province_id,
          name: province_names[province_id],
          trend: Trends.series(snapshots, :vote_percentage, parties, threshold: 5, limit: 4)
        }
      end
      |> Enum.sort_by(& &1.name)

    %{
      counting: counting,
      share: share,
      seats: Trends.series(national, :total_seats_won, parties, threshold: 100, limit: 6),
      majorities: Trends.series(national, :majority_won, parties, threshold: 1, limit: 5),
      # The live election's figures are running totals while it is counted.
      totals:
        Enum.map(
          Trends.totals(national),
          &Map.put(&1, :running, counting and &1.year == live_year)
        ),
      provinces: provinces,
      first_year: List.first(share.years),
      summary: Trends.summary(share, live_year, not counting)
    }
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:trends}
    >
      <.page_header
        eyebrow={if @first_year, do: "Local elections since #{@first_year}", else: "Local elections"}
        title="Trends"
      >
        <:lede :if={@summary}>{@summary}</:lede>
      </.page_header>

      <section class="space-y-4">
        <.section_heading title="Share of the vote">
          <:subtitle :if={@counting}>{@live_year} is dashed while its count runs</:subtitle>
        </.section_heading>
        <div class="panel p-5 sm:p-7">
          <.line_chart id="share-trend" trend={@share} live_year={@live_year} counting={@counting} />
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-4">
          <.section_heading title="Seats won">
            <:subtitle>Council seats across the country</:subtitle>
          </.section_heading>
          <div class="panel p-5 sm:p-6">
            <.line_chart
              id="seats-trend"
              trend={@seats}
              unit={:count}
              live_year={@live_year}
              counting={@counting}
            />
          </div>
        </div>
        <div class="space-y-4">
          <.section_heading title="Councils with a majority">
            <:subtitle>Councils where one party holds over half the seats</:subtitle>
          </.section_heading>
          <div class="panel p-5 sm:p-6">
            <.line_chart
              id="majorities-trend"
              trend={@majorities}
              unit={:count}
              live_year={@live_year}
              counting={@counting}
            />
          </div>
        </div>
      </section>

      <section class="space-y-4">
        <.section_heading title="Voters and ballots">
          <:subtitle>
            Registered voters, and ballots cast (each voter casts a ward and a PR ballot, so
            ballots run ahead of voters)
          </:subtitle>
        </.section_heading>
        <div class="panel space-y-4 p-5 sm:p-7">
          <div :for={row <- @totals} class="grid grid-cols-[3rem_1fr] items-center gap-3">
            <span class={[
              "text-sm tabular-nums",
              row.running && "font-medium text-primary"
            ]}>
              {row.year}
            </span>
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <div
                  class="h-2.5 rounded-full bg-base-content/25 transition-[width] duration-1000"
                  style={"width: #{row.registered_width}%"}
                />
                <span class="text-xs tabular-nums text-base-content/60">
                  {format_compact(row.registered)} registered
                </span>
              </div>
              <div class="flex items-center gap-2">
                <div
                  class="h-2.5 rounded-full bg-primary transition-[width] duration-1000"
                  style={"width: #{row.votes_cast_width}%"}
                />
                <span class="text-xs tabular-nums text-base-content/60">
                  {format_compact(row.votes_cast)} ballots{if row.running, do: " so far"}
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="space-y-4">
        <.section_heading title="By province">
          <:subtitle>Share of the vote of each province's biggest parties</:subtitle>
        </.section_heading>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.link_card :for={province <- @provinces} navigate={~p"/provinces/#{province.id}"}>
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-medium">{province.name}</h3>
              <.icon
                name="hero-arrow-right-micro"
                class="size-4 text-base-content/40 transition-transform group-hover:translate-x-0.5"
              />
            </div>
            <.line_chart
              id={"province-trend-#{province.id}"}
              trend={province.trend}
              live_year={@live_year}
              counting={@counting}
              compact
            />
            <div class="flex flex-wrap gap-x-3 gap-y-1 text-xs">
              <span :for={line <- province.trend.series} class="inline-flex items-center gap-1.5">
                <span class="h-0.5 w-3 rounded-full" style={"background-color: #{line.colour}"} />
                {line.label}
              </span>
            </div>
          </.link_card>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
