defmodule IecWeb.StatusTest do
  use IecWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "/health answers with the pollers' state", %{conn: conn} do
    body = conn |> get(~p"/health") |> json_response(200)
    assert %{"ok" => true, "degraded" => false, "pollers" => _, "failing" => 0} = body
  end

  test "the status page shows the feeds, what is stored and the server", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/status")

    assert html =~ "What is up"
    assert html =~ "Results stored"
    assert html =~ " MB"
  end
end
