defmodule IecWeb.ProvinceLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.{Parties, Results}
  alias Iec.Results.Change

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(
       province_id: String.to_integer(id),
       live_year: Results.live_year(),
       previous_year: Results.previous_year()
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    %{province_id: province_id, live_year: live_year, previous_year: previous_year} =
      socket.assigns

    province = Results.get_latest_snapshot(:province, province_id)
    municipalities = Results.list_latest_snapshots(level: :municipality, province_id: province_id)

    previous_municipalities =
      Results.list_latest_snapshots(
        election: previous_year,
        level: :municipality,
        province_id: province_id
      )
      |> Map.new(&{&1.area_id, &1})

    control = Parties.get_council_control(Enum.map(municipalities, & &1.area_id))

    assign(socket,
      page_title: (province && province.area_name) || "Province",
      province: province,
      previous_province:
        Results.get_latest_snapshot(:province, province_id, election: previous_year),
      municipalities: municipalities,
      previous_municipalities: previous_municipalities,
      control: Map.new(municipalities, &{&1.area_id, control[{live_year, &1.area_id}]}),
      changes:
        Results.list_changes(province_id: province_id, changed_only: true, limit: 40)
        |> Enum.map(&Change.compare/1)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div :if={is_nil(@province)} class="alert">No results for this province yet.</div>

      <div :if={@province} class="space-y-8">
        <div>
          <.link navigate={~p"/"} class="link text-sm">National</.link>
          <h1 class="text-2xl font-semibold">{@province.area_name}</h1>
        </div>

        <.progress_grid snapshot={@province} />
        <.turnout
          snapshot={@province}
          previous_election={@previous_province}
          previous_year={@previous_year}
        />
        <.party_table
          id="province-parties"
          parties={@parties}
          snapshot={@province}
          previous_election={@previous_province}
          previous_year={@previous_year}
          show_councils
        />

        <section class="space-y-3">
          <h2 class="text-lg font-semibold">Municipalities</h2>
          <div class="overflow-x-auto">
            <table id="municipalities" class="table table-sm">
              <thead>
                <tr>
                  <th>Municipality</th>
                  <th class="text-right">Districts counted</th>
                  <th>Council</th>
                  <th>Leading</th>
                  <th class="text-right">Share</th>
                  <th>{@previous_year} leader</th>
                  <th class="text-right">{@previous_year} share</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={municipality <- @municipalities}
                  id={"municipality-#{municipality.area_id}"}
                >
                  <td>
                    <.link navigate={~p"/municipalities/#{municipality.area_id}"} class="link">
                      {municipality.area_name}
                    </.link>
                  </td>
                  <td class="text-right tabular-nums">
                    {format_progress(
                      municipality.voting_districts_complete,
                      municipality.voting_districts_expected
                    )}
                  </td>
                  <td>
                    <.council_control
                      :if={municipality.municipalities_complete == 1}
                      parties={@parties}
                      control={@control[municipality.area_id]}
                    />
                    <span
                      :if={municipality.municipalities_complete != 1}
                      class="badge badge-ghost badge-sm"
                    >
                      counting
                    </span>
                  </td>
                  <.leader_cells parties={@parties} snapshot={municipality} />
                  <.leader_cells
                    parties={@parties}
                    snapshot={@previous_municipalities[municipality.area_id]}
                    muted
                  />
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-2">
          <h2 class="text-lg font-semibold">Changes in {@province.area_name}</h2>
          <p :if={@changes == []} class="text-sm opacity-60">Nothing has moved since start-up.</p>
          <ul id="province-changes" class="divide-y divide-base-300">
            <.change_entry :for={change <- @changes} change={change} parties={@parties} />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
