defmodule IecWeb.ChangesLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.Results
  alias Iec.Results.Change
  alias IecWeb.ChangeDigest

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results]}

  @page_size 100
  @levels %{"national" => :national, "province" => :province, "municipality" => :municipality}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Changes", limit: @page_size, open_rounds: MapSet.new())}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       view: if(params["view"] == "all", do: :all, else: :highlights),
       level: Map.get(@levels, params["level"]),
       limit: @page_size
     )
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    %{view: view, level: level, limit: limit} = socket.assigns
    filters = [changed_only: true] ++ if(level, do: [level: level], else: [])

    # Highlights read further back: rounds are built from many areas' changes.
    changes =
      Results.list_changes(filters ++ [limit: if(view == :all, do: limit + 1, else: limit * 4)])
      |> Enum.map(&Change.compare/1)

    assign(socket,
      changes: Enum.take(changes, limit),
      more: view == :all and length(changes) > limit,
      rounds: if(view == :highlights, do: ChangeDigest.rounds(changes), else: [])
    )
  end

  @impl Phoenix.LiveView
  def handle_event("load_more", _params, socket) do
    {:noreply, socket |> update(:limit, &(&1 + @page_size)) |> refresh()}
  end

  def handle_event("toggle_round", %{"round" => round}, socket) do
    {:noreply,
     update(socket, :open_rounds, fn open ->
       if MapSet.member?(open, round),
         do: MapSet.delete(open, round),
         else: MapSet.put(open, round)
     end)}
  end

  defp areas(1), do: "1 area"
  defp areas(count), do: "#{count} areas"

  defp changes_path(assigns, changes) do
    params =
      %{
        view: assigns.view == :all && "all",
        level: assigns.level && Atom.to_string(assigns.level)
      }
      |> Map.merge(Map.new(changes))
      |> Enum.reject(fn {_key, value} -> value in [nil, false] end)

    ~p"/changes?#{params}"
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:changes}
    >
      <.page_header eyebrow="As the count moves" title="Changes">
        <:lede>
          What moved in each update from the IEC: leads changing hands and councils decided
          first, routine count updates folded away.
        </:lede>
      </.page_header>

      <div class="flex flex-wrap items-center gap-3">
        <.segmented>
          <:option patch={changes_path(assigns, view: false)} active={@view == :highlights}>
            Highlights
          </:option>
          <:option patch={changes_path(assigns, view: "all")} active={@view == :all}>
            Everything
          </:option>
        </.segmented>
        <.segmented>
          <:option patch={changes_path(assigns, level: false)} active={is_nil(@level)}>
            All areas
          </:option>
          <:option patch={changes_path(assigns, level: "national")} active={@level == :national}>
            National
          </:option>
          <:option patch={changes_path(assigns, level: "province")} active={@level == :province}>
            Provinces
          </:option>
          <:option
            patch={changes_path(assigns, level: "municipality")}
            active={@level == :municipality}
          >
            Municipalities
          </:option>
        </.segmented>
      </div>

      <p :if={@changes == []} class="text-base-content/60">Nothing has moved since start-up.</p>

      <ol :if={@view == :highlights} class="relative space-y-4 border-l border-base-300 pl-6">
        <li :for={round <- @rounds} id={round.id} class="relative">
          <span class="absolute -left-[1.85rem] top-5 size-3 rounded-full border-2 border-base-100 bg-primary" />
          <div class="panel overflow-hidden">
            <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-5 pt-4">
              <span class="font-serif text-xl tabular-nums">{format_clock(round.at)}</span>
              <span class="text-sm tabular-nums text-base-content/60">
                {areas(round.areas)} updated
                <span :if={round.voting_districts}>
                  · {format_delta(round.voting_districts, :count)} voting districts
                </span>
                <span :if={round.votes}>· {format_delta(round.votes, :count)} votes</span>
              </span>
            </div>
            <ul
              :if={round.events != []}
              class="mt-2 divide-y divide-base-300 border-t border-base-300"
            >
              <.highlight :for={event <- round.events} event={event} parties={@parties} />
            </ul>
            <p :if={round.events == []} class="px-5 pt-1 text-sm text-base-content/55">
              Routine count updates; no lead changed hands.
            </p>
            <button
              type="button"
              phx-click="toggle_round"
              phx-value-round={round.id}
              class="flex w-full items-center gap-2 px-5 py-3 text-left text-sm text-base-content/70 transition-colors hover:bg-base-200/60 hover:text-base-content"
            >
              <.icon
                name="hero-chevron-right-micro"
                class={[
                  "size-4 transition-transform",
                  MapSet.member?(@open_rounds, round.id) && "rotate-90"
                ]}
              />
              {if MapSet.member?(@open_rounds, round.id), do: "Hide", else: "Show"} the {areas(
                round.areas
              )}
            </button>
            <ul
              :if={MapSet.member?(@open_rounds, round.id)}
              class="divide-y divide-base-300 border-t border-base-300 px-5"
            >
              <.change_entry :for={change <- round.changes} change={change} parties={@parties} />
            </ul>
          </div>
        </li>
      </ol>

      <div :if={@view == :all} class="panel px-5">
        <ul id="changes" class="divide-y divide-base-300">
          <.change_entry :for={change <- @changes} change={change} parties={@parties} />
        </ul>
      </div>

      <button :if={@more} type="button" class="btn btn-ghost btn-sm" phx-click="load_more">
        Load more
      </button>
    </Layouts.app>
    """
  end
end
