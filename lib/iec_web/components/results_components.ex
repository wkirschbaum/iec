defmodule IecWeb.ResultsComponents do
  @moduledoc "Tables, progress bars and change entries shared by the results pages."
  use IecWeb, :html

  alias Iec.Results.{Change, Snapshot}

  # South Africa has no daylight saving: SAST is always UTC+2.
  @sast_offset_seconds 2 * 60 * 60

  ## Formatting

  def format_number(nil), do: "–"

  def format_number(number) when is_integer(number) do
    sign = if number < 0, do: "-", else: ""

    digits =
      number
      |> abs()
      |> Integer.to_string()
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.join(" ")
      |> String.reverse()

    sign <> digits
  end

  def format_percentage(nil), do: "–"
  def format_percentage(value), do: :erlang.float_to_binary(value / 1, decimals: 2) <> "%"

  @doc "A signed delta: votes and seats as integers, percentages as points."
  def format_delta(nil, _kind), do: "–"
  def format_delta(delta, _kind) when delta == 0, do: "0"

  def format_delta(delta, :points) do
    sign = if delta > 0, do: "+", else: "−"
    sign <> :erlang.float_to_binary(abs(delta) / 1, decimals: 2)
  end

  def format_delta(delta, :count) do
    sign = if delta > 0, do: "+", else: "−"
    sign <> format_number(abs(delta))
  end

  def delta_class(delta) when is_number(delta) and delta > 0, do: "text-success"
  def delta_class(delta) when is_number(delta) and delta < 0, do: "text-error"
  def delta_class(_delta), do: "opacity-60"

  @doc "A UTC time shown in SAST."
  def format_time(nil), do: "–"

  def format_time(%DateTime{} = date_time) do
    date_time
    |> DateTime.add(@sast_offset_seconds)
    |> Calendar.strftime("%d %b %H:%M:%S")
  end

  @doc "A UTC time shown as a SAST clock time."
  def format_clock(nil), do: "–"

  def format_clock(%DateTime{} = date_time) do
    date_time |> DateTime.add(@sast_offset_seconds) |> Calendar.strftime("%H:%M:%S")
  end

  def percentage_of(_complete, expected) when expected in [nil, 0], do: 0.0
  def percentage_of(complete, expected), do: (complete || 0) / expected * 100

  @doc "How far along a count is, e.g. \"71.3%\"."
  def format_progress(complete, expected),
    do: :erlang.float_to_binary(percentage_of(complete, expected), decimals: 1) <> "%"

  def party_abbreviation(parties, party_result) do
    case party_result.party_id do
      -2 ->
        "Other"

      0 ->
        "Independents"

      id ->
        (parties[id] && parties[id].abbreviation) || Map.get(party_result, :party_name) ||
          "Party #{id}"
    end
  end

  def party_colour(parties, party_result) do
    (parties[party_result.party_id] && parties[party_result.party_id].colour) || "#9ca3af"
  end

  @doc "The party with the most valid votes in a snapshot, or nil."
  def leader(nil), do: nil

  def leader(%Snapshot{party_results: party_results}) do
    Enum.max_by(party_results, &(&1.total_valid_votes || 0), fn -> nil end)
  end

  def area_path(%{level: :national}), do: ~p"/"
  def area_path(%{level: :province, area_id: id}), do: ~p"/provinces/#{id}"
  def area_path(%{level: :municipality, area_id: id}), do: ~p"/municipalities/#{id}"

  ## Components

  attr :parties, :map, required: true
  attr :party_result, :map, required: true

  def party_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2" title={Map.get(@party_result, :party_name)}>
      <span
        class="inline-block size-3 rounded-full shrink-0"
        style={"background-color: #{party_colour(@parties, @party_result)}"}
      />
      <.link
        :if={@party_result.party_id >= 0}
        navigate={~p"/parties/#{@party_result.party_id}"}
        class="font-medium hover:underline"
      >
        {party_abbreviation(@parties, @party_result)}
      </.link>
      <span :if={@party_result.party_id < 0} class="font-medium">
        {party_abbreviation(@parties, @party_result)}
      </span>
    </span>
    """
  end

  attr :parties, :map, required: true

  attr :control, :map,
    default: nil,
    doc: "`%{majority, largest}` from Parties.get_council_control/1"

  attr :party_id, :integer, default: nil, doc: "the party whose page this is, if any"

  attr :counting, :boolean,
    default: false,
    doc: "count unfinished: no majority means leading, not hung"

  @doc "Who runs a council: a majority party, or hung with its largest party."
  def council_control(assigns) do
    ~H"""
    <span :if={@control && @control.majority} class="inline-flex items-center gap-2">
      <.party_label parties={@parties} party_result={%{party_id: @control.majority}} />
      <span class="opacity-60">majority</span>
    </span>
    <span
      :if={@control && is_nil(@control.majority) && @control.largest}
      class="inline-flex items-center gap-2"
    >
      <span :if={not @counting} class="badge badge-warning badge-sm">hung</span>
      <span :if={@control.largest == @party_id} class="opacity-75">
        {if @counting, do: "leading: this party", else: "largest: this party"}
      </span>
      <span :if={@control.largest != @party_id} class="opacity-60">
        {if @counting, do: "leading", else: "largest"}
      </span>
      <.party_label
        :if={@control.largest != @party_id}
        parties={@parties}
        party_result={%{party_id: @control.largest}}
      />
    </span>
    <span
      :if={is_nil(@control) || (is_nil(@control.majority) && is_nil(@control.largest))}
      class="opacity-60"
    >
      –
    </span>
    """
  end

  attr :ward, :map, required: true

  @doc "When a ward was declared, or \"before <time>\" if it was declared before tracking."
  def declared_at(assigns) do
    ~H"""
    <span :if={@ward.declared_before_tracking}>before {format_time(@ward.declared_at)}</span>
    <span :if={not @ward.declared_before_tracking}>{format_time(@ward.declared_at)}</span>
    """
  end

  attr :label, :string, required: true
  attr :complete, :integer
  attr :expected, :integer

  def progress(assigns) do
    assigns = assign(assigns, :percentage, percentage_of(assigns.complete, assigns.expected))

    ~H"""
    <div class="space-y-1">
      <div class="flex justify-between text-sm">
        <span class="opacity-75">{@label}</span>
        <span class="tabular-nums">
          {format_number(@complete)} / {format_number(@expected)}
          <span class="opacity-60">({format_progress(@complete, @expected)})</span>
        </span>
      </div>
      <progress class="progress progress-primary w-full" value={@percentage} max="100" />
    </div>
    """
  end

  attr :snapshot, Snapshot, required: true

  def progress_grid(assigns) do
    ~H"""
    <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      <.progress
        label="Voting districts"
        complete={@snapshot.voting_districts_complete}
        expected={@snapshot.voting_districts_expected}
      />
      <.progress
        label="Wards"
        complete={@snapshot.wards_complete}
        expected={@snapshot.wards_expected}
      />
      <.progress
        label="Councils"
        complete={@snapshot.municipalities_complete}
        expected={@snapshot.municipalities_expected}
      />
      <.progress
        label="Seats"
        complete={@snapshot.seats_complete}
        expected={@snapshot.seats_expected}
      />
    </div>
    """
  end

  attr :snapshot, Snapshot, required: true
  attr :previous_election, Snapshot, default: nil
  attr :previous_year, :integer, required: true
  attr :show_councils, :boolean, default: true

  def turnout(assigns) do
    ~H"""
    <dl class="grid grid-cols-2 sm:grid-cols-4 gap-4 text-sm">
      <div>
        <dt class="opacity-60">Registered</dt>
        <dd class="text-lg tabular-nums">{format_number(@snapshot.registered_voters)}</dd>
      </div>
      <div>
        <dt class="opacity-60">Votes cast</dt>
        <dd class="text-lg tabular-nums">{format_number(@snapshot.total_votes_cast)}</dd>
        <dd :if={@previous_election} class="opacity-60 tabular-nums">
          {@previous_year}: {format_number(@previous_election.total_votes_cast)}
        </dd>
      </div>
      <div>
        <dt class="opacity-60">Spoilt</dt>
        <dd class="text-lg tabular-nums">{format_number(@snapshot.spoilt_votes)}</dd>
      </div>
      <div :if={@show_councils}>
        <dt class="opacity-60">Hung / majority councils</dt>
        <dd class="text-lg tabular-nums">
          {format_number(@snapshot.hung_councils)} / {format_number(@snapshot.majority_councils)}
        </dd>
      </div>
    </dl>
    """
  end

  attr :id, :string, required: true
  attr :parties, :map, required: true
  attr :snapshot, Snapshot, required: true
  attr :previous_election, Snapshot, default: nil
  attr :previous_year, :integer, required: true
  attr :show_councils, :boolean, default: false

  def party_table(assigns) do
    previous_by_party =
      case assigns.previous_election do
        nil -> %{}
        snapshot -> Map.new(snapshot.party_results, &{&1.party_id, &1})
      end

    rows =
      for party_result <-
            Enum.sort_by(assigns.snapshot.party_results, &(-(&1.total_valid_votes || 0))) do
        {party_result, Map.get(previous_by_party, party_result.party_id)}
      end

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <th>Party</th>
            <th class="text-right">Votes</th>
            <th class="text-right">Share</th>
            <th class="text-right">{@previous_year}</th>
            <th class="text-right">Swing</th>
            <th class="text-right">Seats</th>
            <th class="text-right">{@previous_year}</th>
            <th :if={@show_councils} class="text-right">Councils won</th>
            <th :if={@show_councils} class="text-right">{@previous_year}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={{party_result, previous} <- @rows} id={"#{@id}-party-#{party_result.party_id}"}>
            <td><.party_label parties={@parties} party_result={party_result} /></td>
            <td class="text-right tabular-nums">{format_number(party_result.total_valid_votes)}</td>
            <td class="text-right tabular-nums">
              {format_percentage(party_result.vote_percentage)}
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(previous && previous.vote_percentage)}
            </td>
            <td class={["text-right tabular-nums", delta_class(swing(party_result, previous))]}>
              {format_delta(swing(party_result, previous), :points)}
            </td>
            <td class="text-right tabular-nums">{format_number(party_result.total_seats_won)}</td>
            <td class="text-right tabular-nums opacity-60">
              {format_number(previous && previous.total_seats_won)}
            </td>
            <td :if={@show_councils} class="text-right tabular-nums">
              {format_number(party_result.councils_won)}
            </td>
            <td :if={@show_councils} class="text-right tabular-nums opacity-60">
              {format_number(previous && previous.councils_won)}
            </td>
          </tr>
        </tbody>
      </table>
      <p :if={is_nil(@previous_election)} class="text-sm opacity-60 mt-2">
        No {@previous_year} results for this area.
      </p>
    </div>
    """
  end

  defp swing(_party_result, nil), do: nil

  defp swing(party_result, previous),
    do: Float.round(party_result.vote_percentage - previous.vote_percentage, 2)

  attr :parties, :map, required: true
  attr :snapshot, :any, required: true
  attr :muted, :boolean, default: false

  @doc "Two table cells: the leading party of a snapshot and its share."
  def leader_cells(assigns) do
    assigns = assign(assigns, :leader, leader(assigns.snapshot))

    ~H"""
    <td class={@muted && "opacity-60"}>
      <.party_label :if={@leader} parties={@parties} party_result={@leader} />
      <span :if={is_nil(@leader)}>–</span>
    </td>
    <td class={["text-right tabular-nums", @muted && "opacity-60"]}>
      {format_percentage(@leader && @leader.vote_percentage)}
    </td>
    """
  end

  attr :change, Change, required: true
  attr :parties, :map, required: true
  attr :show_area, :boolean, default: true

  def change_entry(assigns) do
    ~H"""
    <li class="py-3 space-y-1">
      <div class="flex flex-wrap items-baseline gap-x-3 text-sm">
        <span class="tabular-nums opacity-60">{format_time(@change.snapshot.inserted_at)}</span>
        <.link :if={@show_area} navigate={area_path(@change.snapshot)} class="font-medium link">
          {@change.snapshot.area_name}
        </.link>
        <span :if={Change.first?(@change)} class="badge badge-ghost badge-sm">first seen</span>
        <span :if={@change.leader} class="badge badge-warning badge-sm">
          lead: {leader_name(@parties, elem(@change.leader, 0))} → {leader_name(
            @parties,
            elem(@change.leader, 1)
          )}
        </span>
      </div>
      <div :if={@change.progress != []} class="flex flex-wrap gap-x-4 text-sm">
        <span :for={{label, delta, now} <- @change.progress} class="tabular-nums">
          {label} <span class={delta_class(delta)}>{format_delta(delta, :count)}</span>
          <span class="opacity-60">→ {format_number(now)}</span>
        </span>
      </div>
      <div :if={@change.parties != []} class="flex flex-wrap gap-x-4 text-sm">
        <span :for={party <- Enum.take(@change.parties, 6)} class="tabular-nums">
          {party_abbreviation(@parties, party)}
          <span class={delta_class(party.votes)}>{format_delta(party.votes, :count)}</span>
          <span :if={party.seats != 0} class={delta_class(party.seats)}>
            ({format_delta(party.seats, :count)} seats)
          </span>
          <span class="opacity-60">{format_delta(party.percentage, :points)} pp</span>
        </span>
      </div>
    </li>
    """
  end

  defp leader_name(_parties, nil), do: "none"
  defp leader_name(parties, party), do: party_abbreviation(parties, party)
end
