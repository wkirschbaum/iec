defmodule IecWeb.MapLive do
  use IecWeb, :live_view

  import IecWeb.DesignComponents

  alias Iec.Results
  alias IecWeb.MapComponent

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
       provinces: Results.list_area_names(:province) |> Enum.sort_by(&elem(&1, 1))
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    level =
      if params["level"] in Map.keys(@level_atoms), do: params["level"], else: "municipalities"

    # A mode the level cannot show (spoilt ballots for wards) falls back to the leader.
    mode_atoms = level |> level_atom() |> MapComponent.modes()
    modes = Enum.map(mode_atoms, &Atom.to_string/1)
    mode = if params["mode"] in modes, do: params["mode"], else: "leader"
    mode_atom = Enum.find(mode_atoms, &(Atom.to_string(&1) == mode))

    province_id =
      case Integer.parse(params["province"] || "") do
        {id, ""} -> id
        _not_a_province -> nil
      end

    {:noreply,
     assign(socket,
       level: level,
       mode: mode,
       mode_atom: mode_atom,
       modes: Enum.map(modes, &{mode_label(&1), &1}),
       province_id: province_id
     )}
  end

  # The map component refreshes itself from @refreshed_at.
  @impl IecWeb.LiveUpdates
  def refresh(socket), do: socket

  defp level_atom(level), do: Map.fetch!(@level_atoms, level)

  defp mode_label("leader"), do: "Leading party"
  defp mode_label("flips"), do: "Changed since #{Results.previous_year()}"
  defp mode_label("margin"), do: "Close contests"
  defp mode_label("spoilt"), do: "Spoilt ballots"

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
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:map}
    >
      <.page_header eyebrow="Explore the results" title="Map">
        <:lede>
          Coloured as the IEC releases results. Hover or tap an area for its details; open it
          for the full picture.
        </:lede>
      </.page_header>

      <div class="space-y-3">
        <div class="flex flex-wrap items-center gap-3">
          <.segmented>
            <:option
              :for={{label, level} <- @levels}
              patch={map_path(assigns, level: level)}
              active={@level == level}
            >
              {label}
            </:option>
          </.segmented>
          <.segmented>
            <:option
              :for={{label, mode} <- @modes}
              patch={map_path(assigns, mode: mode)}
              active={@mode == mode}
            >
              {label}
            </:option>
          </.segmented>
        </div>
        <.segmented>
          <:option patch={map_path(assigns, province: nil)} active={is_nil(@province_id)}>
            South Africa
          </:option>
          <:option
            :for={{province_id, name} <- @provinces}
            patch={map_path(assigns, province: province_id)}
            active={@province_id == province_id}
          >
            {name}
          </:option>
        </.segmented>
      </div>

      <.live_component
        module={MapComponent}
        id="map"
        level={level_atom(@level)}
        mode={@mode_atom}
        province_id={@province_id}
        parties={@parties}
        refreshed_at={@refreshed_at}
      />
    </Layouts.app>
    """
  end
end
