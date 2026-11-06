defmodule Iec.Status do
  @moduledoc """
  What is up: the pollers, what has been imported, and the server itself. Shown on the
  status page and, briefly, at /health.
  """

  import Ecto.Query

  alias Iec.Repo
  alias Iec.Maps.Boundary
  alias Iec.Results.{FollowedParty, Poller, Snapshot, Ward}

  @doc """
  `%{ok, degraded, pollers, failing, last_checked_at}`. `ok` while the app answers;
  `degraded` when some feed is failing (the IEC hiccups now and then).
  """
  def health do
    statuses = Map.values(Poller.statuses())
    failing = Enum.count(statuses, &match?({:error, _}, &1.result))

    %{
      ok: true,
      degraded: failing > 0,
      pollers: length(statuses),
      failing: failing,
      last_checked_at:
        statuses
        |> Enum.map(& &1.checked_at)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(DateTime, fn -> nil end)
    }
  end

  @doc "The server: memory in MB, process count, uptime in seconds, versions."
  def system do
    {uptime_milliseconds, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      processes: :erlang.system_info(:process_count),
      uptime_seconds: div(uptime_milliseconds, 1_000),
      elixir: System.version(),
      otp: System.otp_release()
    }
  end

  @doc """
  What is stored: snapshots per election and level, map outlines per election and level,
  and the ward directory and followed parties.
  """
  def imports do
    %{
      snapshots:
        Repo.all(
          from snapshot in Snapshot,
            group_by: [snapshot.election, snapshot.level],
            order_by: [desc: snapshot.election],
            select: {snapshot.election, snapshot.level, count(snapshot.area_id, :distinct)}
        ),
      boundaries:
        Repo.all(
          from boundary in Boundary,
            group_by: [boundary.election, boundary.level],
            order_by: [desc: boundary.election],
            select: {boundary.election, boundary.level, count()}
        ),
      wards: Repo.aggregate(Ward, :count),
      followed_parties: Repo.aggregate(FollowedParty, :count)
    }
  end
end
