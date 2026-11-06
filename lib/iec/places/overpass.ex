defmodule Iec.Places.Overpass do
  @moduledoc """
  Asks OpenStreetMap's Overpass API for named places, politely.

  Overpass gives each client a few query slots and asks clients to wait for one; its
  public instances are often at capacity. So, for every query:

    * one query at a time, never in parallel
    * first ask the instance's `/api/status` for a free slot, and wait as long as it says
      (it reports "in N seconds" when none is free)
    * on a busy answer (429, 502, 503, 504, or a runtime error in the reply) wait and try
      again, doubling the wait each time, then move on to the next instance
    * a User-Agent that says who is asking

  Places are only read in a one-off background import (`Iec.Places`), never while
  someone searches.
  """

  require Logger

  # The kinds of OpenStreetMap place people live in and search by.
  @kinds ~w(city town village hamlet suburb neighbourhood quarter)

  # South Africa in four tiles (south, west, north, east), each a modest query; the
  # country's own area keeps Lesotho and eSwatini out.
  @tiles [
    {-35.0, 16.0, -28.5, 24.5},
    {-35.0, 24.5, -28.5, 33.0},
    {-28.5, 16.0, -22.0, 24.5},
    {-28.5, 24.5, -22.0, 33.0}
  ]

  @doc """
  Every named place in South Africa: `{:ok, [element]}` with Overpass' elements (`type`,
  `id`, `lat`/`lon` or `center`, `tags`), or `{:error, reason}` when no instance gave
  every tile.
  """
  def fetch_places do
    Enum.reduce_while(@tiles, {:ok, []}, fn tile, {:ok, elements} ->
      case query(tile_query(tile)) do
        {:ok, tile_elements} -> {:cont, {:ok, elements ++ tile_elements}}
        {:error, reason} -> {:halt, {:error, {tile, reason}}}
      end
    end)
  end

  defp tile_query({south, west, north, east}) do
    """
    [out:json][timeout:180];
    area["ISO3166-1"="ZA"][admin_level=2]->.country;
    nwr(area.country)(#{south},#{west},#{north},#{east})[place~"^(#{Enum.join(@kinds, "|")})$"][name];
    out center tags;
    """
  end

  @doc "Runs one query, trying each instance in turn. `{:ok, elements}` or `{:error, reason}`."
  def query(query) do
    Enum.reduce_while(config(:endpoints), {:error, :no_endpoints}, fn endpoint, _failure ->
      case query_endpoint(endpoint, query, config(:attempts)) do
        {:ok, elements} ->
          {:halt, {:ok, elements}}

        {:error, reason} ->
          Logger.warning("Overpass: #{endpoint} gave up (#{inspect(reason)})")
          {:cont, {:error, reason}}
      end
    end)
  end

  defp query_endpoint(endpoint, query, attempts_left, wait \\ nil) do
    wait = wait || config(:first_backoff)
    wait_for_slot(endpoint)

    case request(:post, endpoint <> "/interpreter", form: [data: query]) do
      {:ok, %Req.Response{status: 200, body: %{"elements" => elements} = body}} ->
        # A query that ran out of time or memory still answers 200, with a remark.
        case body["remark"] do
          nil -> {:ok, elements}
          remark -> retry(endpoint, query, attempts_left, wait, {:remark, remark})
        end

      {:ok, %Req.Response{status: status}} when status in [429, 502, 503, 504] ->
        retry(endpoint, query, attempts_left, wait, {:busy, status})

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        retry(endpoint, query, attempts_left, wait, exception)
    end
  end

  defp retry(_endpoint, _query, attempts_left, _wait, reason) when attempts_left <= 1,
    do: {:error, reason}

  defp retry(endpoint, query, attempts_left, wait, reason) do
    Logger.info(
      "Overpass: #{endpoint} busy (#{inspect(reason)}), trying again in #{div(wait, 1000)}s"
    )

    Process.sleep(wait)
    query_endpoint(endpoint, query, attempts_left - 1, min(wait * 2, config(:max_backoff)))
  end

  # Waits until the instance has a query slot free for us, as its status page says.
  defp wait_for_slot(endpoint) do
    case request(:get, endpoint <> "/status") do
      {:ok, %Req.Response{status: 200, body: status}} when is_binary(status) ->
        case seconds_until_slot(status) do
          0 ->
            :ok

          seconds ->
            Logger.info("Overpass: #{endpoint} has no free slot, waiting #{seconds}s")
            Process.sleep(min(seconds + 1, config(:max_slot_wait_seconds)) * config(:second))
        end

      # A status page that does not answer is a busy instance; the query itself will
      # tell, and back off.
      _other ->
        :ok
    end
  end

  @doc """
  Seconds until a query slot is free, from an Overpass status page: 0 when a slot is
  available now (or the instance sets no limit), else the shortest wait it reports.
  """
  def seconds_until_slot(status) do
    cond do
      status =~ ~r/Rate limit: 0\b/ ->
        0

      status =~ ~r/[1-9]\d* slots? available now/ ->
        0

      true ->
        ~r/in (\d+) seconds/ |> Regex.scan(status, capture: :all_but_first) |> shortest_wait()
    end
  end

  defp shortest_wait([]), do: 0

  defp shortest_wait(waits),
    do: waits |> List.flatten() |> Enum.map(&String.to_integer/1) |> Enum.min()

  defp request(method, url, options \\ []) do
    [
      method: method,
      url: url,
      headers: [user_agent: config(:user_agent)],
      receive_timeout: :timer.minutes(4),
      retry: false
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(config(:req_options) || [])
    |> Req.request()
  end

  defp config(key), do: Application.fetch_env!(:iec, __MODULE__)[key]
end
