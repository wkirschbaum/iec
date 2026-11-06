defmodule Iec.Results.Feed do
  @moduledoc """
  Downloads the JSON files behind the IEC's public results dashboard.

  The files sit behind Cloudflare with `Cache-Control: max-age=60` and send both `ETag`
  and `Last-Modified`. Each request carries the validators from the previous response,
  so an unchanged file costs a `304 Not Modified` with no body. The response's `max-age`
  minus its `Age` is the delay before the next request, so we ask again when the edge
  copy expires and not before.
  """

  @minimum_delay :timer.seconds(15)
  @default_max_age 60

  @type validators :: %{etag: String.t() | nil, last_modified: String.t() | nil}
  @type cache :: %{validators: validators(), next_poll_in: non_neg_integer()}

  @doc "The live election (polled) and the previous one (imported once), from config."
  def live_election, do: config()[:live_election]
  def previous_election, do: config()[:previous_election]

  @doc "Every election, oldest first: the earlier ones, the previous one and the live one."
  def all_elections,
    do: (config()[:history_elections] || []) ++ [previous_election(), live_election()]

  @doc "The national file and each province file of an election (default: the live one)."
  def feeds(election \\ live_election()) do
    base_url = "#{config()[:base_url]}/#{election.year}"
    event = election.electoral_event

    national = %{
      election: election.year,
      name: "national",
      kind: :national,
      url: "#{base_url}/#{event}LiteMapsNational.js"
    }

    provinces =
      for province_id <- config()[:province_ids] do
        %{
          election: election.year,
          name: "province-#{province_id}",
          kind: :province,
          url: "#{base_url}/#{event}Province#{province_id}.js"
        }
      end

    [national | provinces]
  end

  @doc "One party's file: its share and seats in every municipality and ward it contested."
  def party_feed(election, party_id) do
    %{
      election: election.year,
      name: "party-#{party_id}",
      kind: :party,
      party_id: party_id,
      url:
        "#{config()[:base_url]}/#{election.year}/#{election.electoral_event}Party#{party_id}.js"
    }
  end

  @doc "One municipality's file, with every ward and voting district (up to ~3 MB)."
  def municipality_url(election, municipality_id) do
    "#{config()[:base_url]}/#{election.year}/#{election.electoral_event}Munic#{municipality_id}.js"
  end

  @doc "A boundary file of the IEC's election map (GeoJSON), e.g. `nationalMunic`."
  def map_url(election, name), do: "#{config()[:map_url]}/#{election.year}/#{name}.js"

  @doc "The dashboard's party list (id, abbreviation, full name, colour) for an election."
  def party_list_url(election), do: "#{config()[:base_url]}/#{election.year}/PartyList.js"

  defp config, do: Application.fetch_env!(:iec, Iec.Results)

  @doc """
  Fetches `url`, sending the validators from the previous response.

  Returns `{:ok, data, body, cache}` with the decoded JSON and the raw body,
  `{:not_modified, cache}` when the file has not changed, or `{:error, reason}`.
  """
  @spec get(String.t(), validators(), keyword()) ::
          {:ok, map(), binary(), cache()} | {:not_modified, cache()} | {:error, term()}
  def get(url, validators \\ %{etag: nil, last_modified: nil}, request_options \\ []) do
    options =
      Keyword.merge(
        [
          headers: conditional_headers(validators),
          decode_body: false,
          receive_timeout: :timer.seconds(30),
          retry: &retry?/2,
          max_retries: 3
        ],
        Keyword.merge(request_options, config()[:req_options] || [])
      )

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 304} = response} ->
        {:not_modified, cache(response, validators)}

      {:ok, %Req.Response{status: 200, body: body} = response} ->
        body = strip_byte_order_mark(body)

        with {:ok, data} <- Jason.decode(body) do
          {:ok, data, body, cache(response, %{etag: nil, last_modified: nil})}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # The IEC's server now and then answers 406 for a file that is there a moment later, so
  # that is retried along with the usual temporary failures (1s, 2s, 4s apart).
  defp retry?(_request, %Req.Response{status: status}),
    do: status in [406, 408, 429, 500, 502, 503, 504]

  defp retry?(_request, %Req.TransportError{reason: reason}),
    do: reason in [:timeout, :econnrefused, :closed]

  defp retry?(_request, _other), do: false

  defp conditional_headers(validators) do
    [
      {"if-none-match", validators[:etag]},
      {"if-modified-since", validators[:last_modified]}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  # A 304 may leave out the validators; keep the ones we sent in that case.
  defp cache(response, fallback_validators) do
    %{
      validators: %{
        etag: header(response, "etag") || fallback_validators[:etag],
        last_modified: header(response, "last-modified") || fallback_validators[:last_modified]
      },
      next_poll_in: next_poll_in(response)
    }
  end

  # Milliseconds until the edge copy of this response goes stale.
  defp next_poll_in(response) do
    max_age =
      with value when is_binary(value) <- header(response, "cache-control"),
           [_, seconds] <- Regex.run(~r/(?:^|[,\s])max-age=(\d+)/, value) do
        String.to_integer(seconds)
      else
        _ -> @default_max_age
      end

    age =
      case Integer.parse(header(response, "age") || "0") do
        {seconds, _} -> seconds
        :error -> 0
      end

    max(:timer.seconds(max_age - age), @minimum_delay)
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp strip_byte_order_mark(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_byte_order_mark(body), do: body
end
