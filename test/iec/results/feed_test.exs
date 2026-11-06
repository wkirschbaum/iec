defmodule Iec.Results.FeedTest do
  use ExUnit.Case, async: true

  alias Iec.Results.Feed

  @url "https://results.example/feed.js"

  describe "get/2" do
    test "returns the decoded body and the validators to send next time" do
      Req.Test.stub(Feed, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == []

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("abc:0"))
        |> Plug.Conn.put_resp_header("last-modified", "Fri, 06 Nov 2026 05:39:15 GMT")
        |> Plug.Conn.put_resp_header("cache-control", "max-age=60, stale-while-revalidate=60")
        |> Plug.Conn.put_resp_header("age", "20")
        |> Plug.Conn.put_resp_content_type("application/javascript")
        |> Plug.Conn.send_resp(
          200,
          <<0xEF, 0xBB, 0xBF>> <> ~s({"ReportDate":"2026-11-06T07:39:13.86+02:00"})
        )
      end)

      assert {:ok, data, body, cache} = Feed.get(@url)
      assert data == %{"ReportDate" => "2026-11-06T07:39:13.86+02:00"}
      assert String.starts_with?(body, "{")

      assert cache.validators == %{
               etag: ~s("abc:0"),
               last_modified: "Fri, 06 Nov 2026 05:39:15 GMT"
             }

      assert cache.next_poll_in == :timer.seconds(40)
    end

    test "sends the validators and keeps them on 304 Not Modified" do
      validators = %{etag: ~s("abc:0"), last_modified: "Fri, 06 Nov 2026 05:39:15 GMT"}

      Req.Test.stub(Feed, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("abc:0")]
        assert Plug.Conn.get_req_header(conn, "if-modified-since") == [validators.last_modified]

        conn
        |> Plug.Conn.put_resp_header("cache-control", "max-age=60")
        |> Plug.Conn.send_resp(304, "")
      end)

      assert {:not_modified, cache} = Feed.get(@url, validators)
      assert cache.validators == validators
      assert cache.next_poll_in == :timer.seconds(60)
    end

    test "never schedules sooner than 15 seconds" do
      Req.Test.stub(Feed, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("cache-control", "max-age=60")
        |> Plug.Conn.put_resp_header("age", "59")
        |> Plug.Conn.send_resp(304, "")
      end)

      assert {:not_modified, %{next_poll_in: 15_000}} = Feed.get(@url)
    end

    test "returns an error for other statuses" do
      Req.Test.stub(Feed, &Plug.Conn.send_resp(&1, 503, "busy"))

      assert {:error, {:http_status, 503}} = Feed.get(@url)
    end
  end
end
