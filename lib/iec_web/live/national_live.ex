defmodule IecWeb.NationalLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.Results
  alias Iec.Results.Change

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results]}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "National",
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    previous_year = socket.assigns.previous_year

    previous_provinces =
      Results.list_latest_snapshots(election: previous_year, level: :province)
      |> Map.new(&{&1.area_id, &1})

    assign(socket,
      national: Results.get_latest_snapshot(:national, 0),
      previous_national: Results.get_latest_snapshot(:national, 0, election: previous_year),
      provinces: Results.list_latest_snapshots(level: :province),
      previous_provinces: previous_provinces,
      changes: Results.list_changes(changed_only: true, limit: 15) |> Enum.map(&Change.compare/1)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div>
        <h1 class="text-2xl font-semibold">{@live_year} Local Government Elections</h1>
      </div>

      <div :if={is_nil(@national)} class="alert">
        No results yet. The first poll runs a few seconds after start-up.
      </div>

      <section :if={@national} class="space-y-6">
        <.progress_grid snapshot={@national} />
        <.turnout
          snapshot={@national}
          previous_election={@previous_national}
          previous_year={@previous_year}
        />
        <.party_table
          id="national-parties"
          parties={@parties}
          snapshot={@national}
          previous_election={@previous_national}
          previous_year={@previous_year}
          show_councils
        />
      </section>

      <section :if={@provinces != []} class="space-y-3">
        <h2 class="text-lg font-semibold">Provinces</h2>
        <div class="overflow-x-auto">
          <table id="provinces" class="table table-sm">
            <thead>
              <tr>
                <th>Province</th>
                <th class="text-right">Districts counted</th>
                <th>Leading</th>
                <th class="text-right">Share</th>
                <th>{@previous_year} leader</th>
                <th class="text-right">{@previous_year} share</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={province <- @provinces} id={"province-#{province.area_id}"}>
                <td>
                  <.link navigate={~p"/provinces/#{province.area_id}"} class="link">
                    {province.area_name}
                  </.link>
                </td>
                <td class="text-right tabular-nums">
                  {format_progress(
                    province.voting_districts_complete,
                    province.voting_districts_expected
                  )}
                </td>
                <.leader_cells parties={@parties} snapshot={province} />
                <.leader_cells
                  parties={@parties}
                  snapshot={@previous_provinces[province.area_id]}
                  muted
                />
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-2">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-semibold">Latest changes</h2>
          <.link navigate={~p"/changes"} class="link text-sm">All changes</.link>
        </div>
        <p :if={@changes == []} class="text-sm opacity-60">Nothing has moved since start-up.</p>
        <ul id="latest-changes" class="divide-y divide-base-300">
          <.change_entry :for={change <- @changes} change={change} parties={@parties} />
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
