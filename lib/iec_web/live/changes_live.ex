defmodule IecWeb.ChangesLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents

  alias Iec.Results
  alias Iec.Results.Change

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results]}

  @levels %{"national" => :national, "province" => :province, "municipality" => :municipality}
  @filters [
    {"All", nil},
    {"National", "national"},
    {"Provinces", "province"},
    {"Municipalities", "municipality"}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Changes", filters: @filters)}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(level: Map.get(@levels, params["level"]), include_first: params["first"] == "1")
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    filters =
      [limit: 300, changed_only: not socket.assigns.include_first] ++
        if(socket.assigns.level, do: [level: socket.assigns.level], else: [])

    assign(socket, changes: Results.list_changes(filters) |> Enum.map(&Change.compare/1))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Changes</h1>
          <p class="text-sm opacity-60">
            Each entry is an area whose figures moved since its previous snapshot, at the time
            we fetched it (SAST).
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link
            :for={{label, level} <- @filters}
            patch={~p"/changes?#{filter_params(level, @include_first)}"}
            class={["btn btn-sm", level_param(@level) == level && "btn-primary"]}
          >
            {label}
          </.link>
          <.link
            patch={~p"/changes?#{filter_params(level_param(@level), not @include_first)}"}
            class={["btn btn-sm btn-ghost", @include_first && "btn-active"]}
          >
            Show first snapshots
          </.link>
        </div>
      </div>

      <p :if={@changes == []} class="opacity-60">No changes recorded yet.</p>

      <ul id="changes" class="divide-y divide-base-300">
        <.change_entry :for={change <- @changes} change={change} parties={@parties} />
      </ul>
    </Layouts.app>
    """
  end

  defp level_param(nil), do: nil
  defp level_param(level), do: Atom.to_string(level)

  defp filter_params(level, include_first) do
    Enum.reject([level: level, first: include_first && "1"], fn {_key, value} ->
      value in [nil, false]
    end)
  end
end
