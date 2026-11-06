defmodule Iec.Results.PollerTest do
  use Iec.DataCase, async: false

  alias Iec.Results.{Feed, Poller}

  defp start_poller(feed) do
    Req.Test.set_req_test_to_shared()
    pid = start_supervised!({Poller, feed: feed})
    Req.Test.allow(Feed, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Iec.Repo, self(), pid)
    send(pid, :poll)
    pid
  end

  defp wait_for_status(feed_name, attempts \\ 50) do
    case Poller.statuses()[feed_name] do
      %{result: :pending} when attempts > 0 ->
        Process.sleep(20)
        wait_for_status(feed_name, attempts - 1)

      status ->
        status
    end
  end

  test "a party file the IEC has not published yet is waited for, not a failure" do
    Req.Test.stub(Feed, &Plug.Conn.send_resp(&1, 406, ""))

    start_poller(%{
      election: 2026,
      name: "party-18",
      kind: :party,
      party_id: 18,
      url: "https://x/p18.js"
    })

    assert %{result: :no_file} = wait_for_status("party-18")
  end

  test "other failures are failures" do
    Req.Test.stub(Feed, &Plug.Conn.send_resp(&1, 500, ""))
    start_poller(%{election: 2026, name: "national", kind: :national, url: "https://x/n.js"})

    assert %{result: {:error, {:http_status, 500}}} = wait_for_status("national")
  end
end
