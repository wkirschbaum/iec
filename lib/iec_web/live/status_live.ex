defmodule IecWeb.StatusLive do
  use IecWeb, :live_view

  import IecWeb.ResultsComponents
  import IecWeb.DesignComponents

  alias Iec.Status

  @behaviour IecWeb.LiveUpdates
  on_mount {IecWeb.LiveUpdates, [:results]}

  @tick :timer.seconds(10)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@tick, :tick)
    {:ok, socket |> assign(page_title: "Status") |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket), do: {:noreply, refresh(socket)}

  # Feed statuses arrive through IecWeb.LiveUpdates as @feed_statuses; the rest is read
  # here, after every update and every ten seconds.
  @impl IecWeb.LiveUpdates
  def refresh(socket) do
    assign(socket, system: Status.system(), imports: Status.imports())
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    {main_feeds, party_feeds} =
      assigns.feed_statuses
      |> Map.values()
      |> Enum.split_with(&(not String.starts_with?(&1.feed, "party-")))

    assigns =
      assign(assigns,
        main_feeds: Enum.sort_by(main_feeds, &feed_order/1),
        party_feeds: party_feeds,
        failing_parties: Enum.filter(party_feeds, &match?({:error, _}, &1.result)),
        waiting_parties: Enum.count(party_feeds, &(&1.result == :no_file))
      )

    ~H"""
    <Layouts.app flash={@flash} feed_status={@feed_status} count_progress={@count_progress}>
      <.page_header eyebrow="Status" title="What is up">
        <:lede>
          The feeds from the IEC, what has been imported, and the server. Updates by itself.
        </:lede>
      </.page_header>

      <section class="panel grid grid-cols-2 gap-6 p-5 sm:p-7 lg:grid-cols-4">
        <.kpi
          label="Feeds"
          value={"#{@feed_status.feeds - @feed_status.failing} / #{@feed_status.feeds}"}
        >
          healthy · {@feed_status.failing} failing
        </.kpi>
        <.kpi label="Last check" value={format_clock(@feed_status.checked_at)}>SAST</.kpi>
        <.kpi label="Memory" value={"#{@system.memory_mb} MB"}>{@system.processes} processes</.kpi>
        <.kpi label="Up for" value={duration(@system.uptime_seconds)}>
          Elixir {@system.elixir} · OTP {@system.otp}
        </.kpi>
      </section>

      <section class="space-y-4">
        <.section_heading title="Results feeds">
          <:subtitle>
            National and provincial files, checked as the IEC's cached copies expire
          </:subtitle>
        </.section_heading>
        <div class="panel p-2 sm:p-4">
          <table id="main-feeds" class="table table-sm">
            <thead>
              <tr>
                <th>Feed</th>
                <th>Last check</th>
                <th>Result</th>
                <th>Next check</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={feed <- @main_feeds} id={"feed-#{feed.feed}"}>
                <td class="font-medium">{feed.feed}</td>
                <td>{format_clock(feed.checked_at)}</td>
                <td><.result_badge result={feed.result} /></td>
                <td>{format_clock(feed.next_poll_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="space-y-4">
        <.section_heading title="Party files">
          <:subtitle>
            {length(@party_feeds)} followed · {@waiting_parties} not published yet · {length(
              @failing_parties
            )} failing
          </:subtitle>
        </.section_heading>
        <p :if={@failing_parties == []} class="text-sm text-base-content/60">
          No party file is failing.
        </p>
        <div :if={@failing_parties != []} class="panel p-2 sm:p-4">
          <table id="failing-parties" class="table table-sm">
            <thead>
              <tr>
                <th>Feed</th>
                <th>Last check</th>
                <th>Result</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={feed <- @failing_parties} id={"failing-#{feed.feed}"}>
                <td class="font-medium">{feed.feed}</td>
                <td>{format_clock(feed.checked_at)}</td>
                <td><.result_badge result={feed.result} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section class="grid gap-6 lg:grid-cols-2">
        <div class="space-y-4">
          <.section_heading title="Results stored">
            <:subtitle>Areas with results, per election</:subtitle>
          </.section_heading>
          <div class="panel p-2 sm:p-4">
            <table id="stored-snapshots" class="table table-sm">
              <thead>
                <tr>
                  <th>Election</th>
                  <th>Level</th>
                  <th class="text-right">Areas</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{election, level, count} <- @imports.snapshots}>
                  <td>{election}</td>
                  <td>{level}</td>
                  <td class="text-right">{format_number(count)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        <div class="space-y-4">
          <.section_heading title="Maps and wards">
            <:subtitle>
              {format_number(@imports.wards)} wards mapped · {@imports.followed_parties} parties followed
            </:subtitle>
          </.section_heading>
          <div class="panel p-2 sm:p-4">
            <table id="stored-boundaries" class="table table-sm">
              <thead>
                <tr>
                  <th>Election</th>
                  <th>Outlines</th>
                  <th class="text-right">Shapes</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{election, level, count} <- @imports.boundaries}>
                  <td>{election}</td>
                  <td>{level}</td>
                  <td class="text-right">{format_number(count)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>

      <p class="text-sm text-base-content/60">
        Machine-readable: <a href="/health" class="link">/health</a>
      </p>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true

  defp result_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      match?({:error, _}, @result) && "badge-error",
      @result == :no_file && "badge-ghost",
      match?({:updated, count} when count > 0, @result) && "badge-success",
      @result in [:not_modified, :pending, {:updated, 0}] && "badge-ghost"
    ]}>
      {result_label(@result)}
    </span>
    """
  end

  defp result_label(:pending), do: "waiting to start"
  defp result_label(:not_modified), do: "no change"
  defp result_label(:no_file), do: "not published yet"
  defp result_label({:updated, 0}), do: "new file, no change"
  defp result_label({:updated, count}), do: "#{count} changed"
  defp result_label({:error, {:http_status, status}}), do: "failed (HTTP #{status})"
  defp result_label({:error, _reason}), do: "failed"

  defp feed_order(%{feed: "national"}), do: {0, ""}
  defp feed_order(%{feed: name}), do: {1, name}

  defp duration(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min"

  defp duration(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3_600)} h #{rem(div(seconds, 60), 60)} min"

  defp duration(seconds), do: "#{div(seconds, 86_400)} d #{rem(div(seconds, 3_600), 24)} h"
end
