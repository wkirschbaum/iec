defmodule IecWeb.NationalLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.Results
  alias Iec.Results.Change
  alias IecWeb.TableRows

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
    %{previous_year: previous_year, parties: parties} = socket.assigns
    national = Results.get_latest_snapshot(:national, 0)
    previous_national = Results.get_latest_snapshot(:national, 0, election: previous_year)

    previous_provinces =
      Results.list_latest_snapshots(election: previous_year, level: :province)
      |> Map.new(&{&1.area_id, &1})

    assign(socket,
      national: national,
      previous_national: previous_national,
      party_rows: TableRows.party_rows(national, previous_national, parties),
      province_rows:
        TableRows.area_rows(
          Results.list_latest_snapshots(level: :province),
          previous_provinces,
          parties
        ),
      changes: Results.list_changes(changed_only: true, limit: 15) |> Enum.map(&Change.compare/1)
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <h1 class="text-2xl font-semibold">{@live_year} Local Government Elections</h1>

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
          rows={@party_rows}
          parties={@parties}
          previous_year={@previous_year}
          sorts={@sorts}
          show_councils
        />
      </section>

      <section class="space-y-3">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-semibold">Who leads where</h2>
          <.link navigate={~p"/map"} class="link text-sm">Full map</.link>
        </div>
        <.live_component
          module={IecWeb.MapComponent}
          id="national-map"
          level={:municipality}
          parties={@parties}
          refreshed_at={@refreshed_at}
        />
      </section>

      <section :if={@province_rows != []} class="space-y-3">
        <h2 class="text-lg font-semibold">Provinces</h2>
        <.area_table
          id="provinces"
          rows={@province_rows}
          parties={@parties}
          previous_year={@previous_year}
          sorts={@sorts}
          area_label="Province"
          area_path={&~p"/provinces/#{&1}"}
        />
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
