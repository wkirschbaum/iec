defmodule IecWeb.HealthController do
  use IecWeb, :controller

  @doc """
  A small JSON summary for uptime checks. Always 200 while the app runs, so one failing
  IEC file never takes the site out of rotation; `degraded` says if anything is failing.
  """
  def show(conn, _params), do: json(conn, Iec.Status.health())
end
