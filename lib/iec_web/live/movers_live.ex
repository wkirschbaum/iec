defmodule IecWeb.MoversLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.{Parties, Results}
  alias IecWeb.TableRows

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Winners & losers", previous_year: Results.previous_year())
     |> refresh()}
  end

  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    movers = Parties.get_movers()
    by_swing = Enum.sort_by(movers.parties, & &1.swing, :desc)

    net = fn gained, lost ->
      movers.parties
      |> Enum.map(&Map.put(&1, :net, Map.fetch!(&1, gained) - Map.fetch!(&1, lost)))
      |> Enum.reject(&(Map.fetch!(&1, gained) == 0 and Map.fetch!(&1, lost) == 0))
      |> Enum.sort_by(& &1.net, :desc)
    end

    assign(socket,
      winners: Enum.filter(by_swing, &(&1.swing > 0)),
      losers: by_swing |> Enum.filter(&(&1.swing < 0)) |> Enum.reverse(),
      ward_net: net.(:wards_gained, :wards_lost),
      council_net: net.(:councils_gained, :councils_lost),
      local_rises:
        TableRows.with_party_name(
          movers.local_swings.rises,
          socket.assigns.parties,
          :party_id,
          :party
        ),
      local_falls:
        TableRows.with_party_name(
          movers.local_swings.falls,
          socket.assigns.parties,
          :party_id,
          :party
        )
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      feed_status={@feed_status}
      count_progress={@count_progress}
      active={:movers}
    >
      <.page_header eyebrow={"Since #{@previous_year}"} title="Winners & losers">
        <:lede>
          Vote share swing since {@previous_year}, and the wards and council majorities that
          changed hands. Updates as the count goes on.
        </:lede>
      </.page_header>

      <section class="grid gap-4 lg:grid-cols-2">
        <.leaderboard
          id="winners"
          title="Biggest winners"
          tone="success"
          rows={@winners}
          parties={@parties}
          previous_year={@previous_year}
        />
        <.leaderboard
          id="losers"
          title="Biggest losers"
          tone="error"
          rows={@losers}
          parties={@parties}
          previous_year={@previous_year}
        />
      </section>

      <section class="grid gap-4 lg:grid-cols-2">
        <.net_chart
          id="ward-net"
          title="Wards changing hands"
          caption="Declared wards won from, or lost to, another party"
          rows={@ward_net}
          gained={:wards_gained}
          lost={:wards_lost}
          parties={@parties}
        />
        <.net_chart
          id="council-net"
          title="Council majorities changing hands"
          caption="Councils with a finished count; a majority lost to a hung council counts as lost"
          rows={@council_net}
          gained={:councils_gained}
          lost={:councils_lost}
          parties={@parties}
        />
      </section>

      <section class="grid gap-4 lg:grid-cols-2">
        <.local_swings
          id="local-rises"
          title="Biggest local surges"
          rows={@local_rises}
          parties={@parties}
          previous_year={@previous_year}
          sorts={@sorts}
        />
        <.local_swings
          id="local-falls"
          title="Biggest local collapses"
          rows={@local_falls}
          parties={@parties}
          previous_year={@previous_year}
          sorts={@sorts}
        />
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :tone, :string, required: true, values: ["success", "error"]
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true

  # Parties ranked by vote share swing, with a bar scaled to the biggest swing on the
  # board, and their ward and council turnover underneath.
  defp leaderboard(assigns) do
    assigns =
      assign(assigns, :largest, assigns.rows |> Enum.map(&abs(&1.swing)) |> Enum.max(fn -> 1 end))

    ~H"""
    <div id={@id} class="panel space-y-4 p-5">
      <h2 class={[
        "text-lg font-semibold",
        @tone == "success" && "text-success",
        @tone == "error" && "text-error"
      ]}>
        {@title}
      </h2>
      <p :if={@rows == []} class="text-sm opacity-60">None so far.</p>
      <ol class="space-y-3">
        <li :for={{row, rank} <- Enum.with_index(@rows, 1)} id={"#{@id}-#{row.party_id}"}>
          <div class="flex items-baseline gap-3">
            <span class="w-5 text-right text-sm tabular-nums opacity-50">{rank}</span>
            <.party_label parties={@parties} party_result={row} />
            <span
              :if={row.new_party}
              class="badge badge-ghost badge-sm"
              title="Swing measured from zero"
            >
              no 2021 figure
            </span>
            <span class={[
              "ml-auto text-lg font-semibold tabular-nums",
              @tone == "success" && "text-success",
              @tone == "error" && "text-error"
            ]}>
              {format_delta(row.swing, :points)} pp
            </span>
          </div>
          <div class="ml-8 mt-1 h-1.5 rounded-full bg-base-200">
            <div
              class={[
                "h-full rounded-full transition-[width] duration-700",
                @tone == "success" && "bg-success",
                @tone == "error" && "bg-error"
              ]}
              style={"width: #{abs(row.swing) / @largest * 100}%"}
            />
          </div>
          <div class="ml-8 mt-1 flex flex-wrap gap-x-4 text-xs tabular-nums opacity-70">
            <span>
              {format_percentage(row.share)}
              <span class="opacity-70">from {format_percentage(row.previous_share)}</span>
            </span>
            <span :if={row.wards_gained + row.wards_lost > 0}>
              wards +{row.wards_gained} / −{row.wards_lost}
            </span>
            <span :if={row.councils_gained + row.councils_lost > 0}>
              councils +{row.councils_gained} / −{row.councils_lost}
            </span>
          </div>
        </li>
      </ol>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :caption, :string, required: true
  attr :rows, :list, required: true
  attr :gained, :atom, required: true
  attr :lost, :atom, required: true
  attr :parties, :map, required: true

  # A diverging bar chart: losses to the left of the centre line, gains to the right,
  # with the net change on the end.
  defp net_chart(assigns) do
    largest =
      assigns.rows
      |> Enum.flat_map(&[Map.fetch!(&1, assigns.gained), Map.fetch!(&1, assigns.lost)])
      |> Enum.max(fn -> 1 end)

    assigns = assign(assigns, :largest, max(largest, 1))

    ~H"""
    <div id={@id} class="panel space-y-4 p-5">
      <div>
        <h2 class="text-lg font-semibold">{@title}</h2>
        <p class="text-xs opacity-60">{@caption}</p>
      </div>
      <p :if={@rows == []} class="text-sm opacity-60">None so far.</p>
      <div class="space-y-2">
        <div
          :for={row <- @rows}
          id={"#{@id}-#{row.party_id}"}
          class="grid grid-cols-[6rem_1fr_1fr_3.5rem] items-center gap-2 text-sm"
        >
          <.party_label parties={@parties} party_result={row} />
          <div class="flex h-4 justify-end border-r border-base-content/30">
            <div
              :if={Map.fetch!(row, @lost) > 0}
              class="h-full rounded-l bg-error/80 transition-[width] duration-700"
              style={"width: #{Map.fetch!(row, @lost) / @largest * 100}%"}
              title={"lost #{Map.fetch!(row, @lost)}"}
            />
          </div>
          <div class="flex h-4">
            <div
              :if={Map.fetch!(row, @gained) > 0}
              class="h-full rounded-r bg-success/80 transition-[width] duration-700"
              style={"width: #{Map.fetch!(row, @gained) / @largest * 100}%"}
              title={"gained #{Map.fetch!(row, @gained)}"}
            />
          </div>
          <span class={["text-right font-semibold tabular-nums", delta_class(row.net)]}>
            {format_delta(row.net, :count)}
          </span>
        </div>
      </div>
      <div :if={@rows != []} class="grid grid-cols-[6rem_1fr_1fr_3.5rem] gap-2 text-xs opacity-60">
        <span />
        <span class="text-right">lost</span>
        <span>gained</span>
        <span class="text-right">net</span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :parties, :map, required: true
  attr :sorts, :map, required: true
  attr :previous_year, :integer, required: true

  defp local_swings(assigns) do
    ~H"""
    <div id={@id} class="panel space-y-4 p-5">
      <h2 class="text-lg font-semibold">{@title}</h2>
      <p :if={@rows == []} class="text-sm opacity-60">None so far.</p>
      <table :if={@rows != []} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="party" sorts={@sorts} first="asc">Party</.sort_header>
            <.sort_header table={@id} column="municipality_name" sorts={@sorts} first="asc">
              Municipality
            </.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Now</.sort_header>
            <.sort_header table={@id} column="swing" sorts={@sorts} align="right">Swing</.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={row <- sort_rows(@rows, @sorts[@id])}
            id={"#{@id}-#{row.party_id}-#{row.municipality_id}"}
          >
            <td><.party_label parties={@parties} party_result={row} /></td>
            <td>
              <.link navigate={~p"/municipalities/#{row.municipality_id}"} class="link">
                {row.municipality_name}
              </.link>
              <span :if={not row.complete} class="badge badge-ghost badge-xs">counting</span>
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
            </td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class={["text-right font-semibold tabular-nums", delta_class(row.swing)]}>
              {format_delta(row.swing, :points)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
