defmodule IecWeb.MapLive do
  use IecWeb, :live_view

  alias Iec.Results

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @levels [{"Provinces", "provinces"}, {"Municipalities", "municipalities"}, {"Wards", "wards"}]
  @level_atoms %{"provinces" => :province, "municipalities" => :municipality, "wards" => :ward}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Map",
       levels: @levels,
       modes: [{"Leading party", "leader"}, {"Changed since #{Results.previous_year()}", "flips"}],
       provinces: Results.list_area_names(:province) |> Enum.sort_by(&elem(&1, 1))
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    level =
      if params["level"] in Map.keys(@level_atoms), do: params["level"], else: "municipalities"

    mode = if params["mode"] == "flips", do: "flips", else: "leader"

    province_id =
      case Integer.parse(params["province"] || "") do
        {id, ""} -> id
        _not_a_province -> nil
      end

    {:noreply, assign(socket, level: level, mode: mode, province_id: province_id)}
  end

  # The map component refreshes itself from @refreshed_at.
  @impl IecWeb.LiveUpdates
  def refresh(socket), do: socket

  defp level_atom(level), do: Map.fetch!(@level_atoms, level)
  defp mode_atom("flips"), do: :flips
  defp mode_atom(_leader), do: :leader

  defp map_path(socket_assigns, changes) do
    params =
      %{
        level: socket_assigns.level,
        mode: socket_assigns.mode,
        province: socket_assigns.province_id
      }
      |> Map.merge(Map.new(changes))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/map?#{params}"
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Map</h1>
          <p class="text-sm opacity-60">
            Coloured as the IEC releases results. Hover for details, click to open an area.
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <div class="join">
            <.link
              :for={{label, level} <- @levels}
              patch={map_path(assigns, level: level)}
              class={["btn btn-sm join-item", @level == level && "btn-primary"]}
            >
              {label}
            </.link>
          </div>
          <div class="join">
            <.link
              :for={{label, mode} <- @modes}
              patch={map_path(assigns, mode: mode)}
              class={["btn btn-sm join-item", @mode == mode && "btn-primary"]}
            >
              {label}
            </.link>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap gap-1">
        <.link
          patch={map_path(assigns, province: nil)}
          class={["btn btn-xs", is_nil(@province_id) && "btn-neutral"]}
        >
          South Africa
        </.link>
        <.link
          :for={{province_id, name} <- @provinces}
          patch={map_path(assigns, province: province_id)}
          class={["btn btn-xs", @province_id == province_id && "btn-neutral"]}
        >
          {name}
        </.link>
      </div>

      <.live_component
        module={IecWeb.MapComponent}
        id="map"
        level={level_atom(@level)}
        mode={mode_atom(@mode)}
        province_id={@province_id}
        parties={@parties}
        refreshed_at={@refreshed_at}
      />
    </Layouts.app>
    """
  end
end
