defmodule IecWeb.LiveUpdates do
  @moduledoc """
  Keeps every page live. Mount it with the topics the page depends on:

      on_mount {IecWeb.LiveUpdates, [:results]}
      on_mount {IecWeb.LiveUpdates, [:results, :parties]}

  It assigns `@parties` (names and colours), `@feed_status` (the header) and
  `@count_progress` (the sticky footer), `@refreshed_at` (changes on every refresh, for
  live components such as maps to pick up),
  keeps both current, and calls the view's `refresh/1` when results or party files
  change. A poll round lands as several messages within seconds, so refreshes are
  coalesced: at most one per second.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Iec.{Parties, Results}
  alias Iec.Results.Poller

  # Configurable so tests need not wait.
  @refresh_delay Application.compile_env(:iec, [IecWeb.LiveUpdates, :refresh_delay], 1_000)

  @callback refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()

  def on_mount(topics, _params, _session, socket) do
    if connected?(socket) do
      Results.subscribe_feed_status()
      if :results in topics, do: Results.subscribe()
      if :parties in topics, do: Parties.subscribe()
    end

    {:cont,
     socket
     |> assign(
       parties: Results.parties_by_id(),
       feed_statuses: Poller.statuses(),
       count_progress: Results.get_count_progress(),
       refresh_scheduled: false,
       refreshed_at: System.monotonic_time()
     )
     |> assign_feed_status()
     |> attach_hook(:live_updates, :handle_info, &handle_info/2)}
  end

  defp handle_info({:feed_status, status}, socket) do
    {:halt,
     socket
     |> update(:feed_statuses, &Map.put(&1, status.feed, status))
     |> assign_feed_status()}
  end

  defp handle_info(:parties_refreshed, socket) do
    {:halt, assign(socket, :parties, Results.parties_by_id())}
  end

  defp handle_info(:refresh, socket) do
    {:halt,
     socket
     |> assign(
       refresh_scheduled: false,
       refreshed_at: System.monotonic_time(),
       count_progress: Results.get_count_progress()
     )
     |> socket.view.refresh()}
  end

  defp handle_info({event, _id}, socket)
       when event in [:results_changed, :party_results_changed] do
    {:halt, schedule_refresh(socket)}
  end

  defp handle_info(:wards_mapped, socket), do: {:halt, schedule_refresh(socket)}

  defp handle_info(_message, socket), do: {:cont, socket}

  defp schedule_refresh(%{assigns: %{refresh_scheduled: true}} = socket), do: socket

  defp schedule_refresh(socket) do
    Process.send_after(self(), :refresh, @refresh_delay)
    assign(socket, :refresh_scheduled, true)
  end

  # What the header shows: when any feed was last checked and how many are failing.
  defp assign_feed_status(socket) do
    statuses = Map.values(socket.assigns.feed_statuses)

    assign(socket, :feed_status, %{
      feeds: length(statuses),
      failing: Enum.count(statuses, &match?({:error, _}, &1.result)),
      checked_at:
        statuses
        |> Enum.map(& &1.checked_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)
    })
  end
end
