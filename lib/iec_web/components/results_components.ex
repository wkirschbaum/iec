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

  @doc "How far along a count is, e.g. \"71.3%\", from counts or a percentage."
  def format_progress(complete, expected),
    do: format_progress(percentage_of(complete, expected))

  def format_progress(percentage), do: :erlang.float_to_binary(percentage / 1, decimals: 1) <> "%"

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
  attr :rows, :list, required: true, doc: "from IecWeb.TableRows.party_rows/3"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true
  attr :show_councils, :boolean, default: false

  @doc "Parties' votes, share and seats, against the previous election. Sortable."
  def party_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="party" sorts={@sorts} first="asc">Party</.sort_header>
            <.sort_header table={@id} column="votes" sorts={@sorts} align="right">Votes</.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
            <.sort_header table={@id} column="swing" sorts={@sorts} align="right">Swing</.sort_header>
            <.sort_header table={@id} column="seats" sorts={@sorts} align="right">Seats</.sort_header>
            <.sort_header table={@id} column="previous_seats" sorts={@sorts} align="right">
              {@previous_year}
            </.sort_header>
            <.sort_header
              :if={@show_councils}
              table={@id}
              column="councils"
              sorts={@sorts}
              align="right"
            >
              Councils won
            </.sort_header>
            <.sort_header
              :if={@show_councils}
              table={@id}
              column="previous_councils"
              sorts={@sorts}
              align="right"
            >
              {@previous_year}
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- sort_rows(@rows, @sorts[@id])} id={"#{@id}-party-#{row.party_id}"}>
            <td><.party_label parties={@parties} party_result={row} /></td>
            <td class="text-right tabular-nums">{format_number(row.votes)}</td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
            </td>
            <td class={["text-right tabular-nums", delta_class(row.swing)]}>
              {format_delta(row.swing, :points)}
            </td>
            <td class="text-right tabular-nums">{format_number(row.seats)}</td>
            <td class="text-right tabular-nums opacity-60">{format_number(row.previous_seats)}</td>
            <td :if={@show_councils} class="text-right tabular-nums">
              {format_number(row.councils)}
            </td>
            <td :if={@show_councils} class="text-right tabular-nums opacity-60">
              {format_number(row.previous_councils)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true, doc: "from IecWeb.TableRows.area_rows/4"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true
  attr :area_label, :string, required: true
  attr :area_path, :any, required: true, doc: "area id → path"
  attr :show_council, :boolean, default: false

  @doc "Areas with how far their count is, who leads now and who led before. Sortable."
  def area_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header table={@id} column="name" sorts={@sorts} first="asc">
              {@area_label}
            </.sort_header>
            <.sort_header table={@id} column="counted" sorts={@sorts} align="right">
              Districts counted
            </.sort_header>
            <.sort_header :if={@show_council} table={@id} column="council" sorts={@sorts} first="asc">
              Council
            </.sort_header>
            <.sort_header table={@id} column="leader" sorts={@sorts} first="asc">
              Leading
            </.sort_header>
            <.sort_header table={@id} column="share" sorts={@sorts} align="right">Share</.sort_header>
            <.sort_header table={@id} column="previous_leader" sorts={@sorts} first="asc">
              {@previous_year} leader
            </.sort_header>
            <.sort_header table={@id} column="previous_share" sorts={@sorts} align="right">
              {@previous_year} share
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- sort_rows(@rows, @sorts[@id])} id={"#{@id}-#{row.area_id}"}>
            <td><.link navigate={@area_path.(row.area_id)} class="link">{row.name}</.link></td>
            <td class="text-right tabular-nums">{format_progress(row.counted)}</td>
            <td :if={@show_council}>
              <.council_control :if={row.complete} parties={@parties} control={row.control} />
              <span :if={not row.complete} class="badge badge-ghost badge-sm">counting</span>
            </td>
            <td><.party_or_dash parties={@parties} party_id={row.leader_id} /></td>
            <td class="text-right tabular-nums">{format_percentage(row.share)}</td>
            <td class="opacity-60">
              <.party_or_dash parties={@parties} party_id={row.previous_leader_id} />
            </td>
            <td class="text-right tabular-nums opacity-60">
              {format_percentage(row.previous_share)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :parties, :map, required: true
  attr :party_id, :integer, default: nil
  attr :empty, :string, default: "–"

  @doc "A party's label, or a dash (or `empty`) when there is none."
  def party_or_dash(assigns) do
    ~H"""
    <.party_label :if={@party_id} parties={@parties} party_result={%{party_id: @party_id}} />
    <span :if={is_nil(@party_id)} class="opacity-60">{@empty}</span>
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
          lead: {leader_name(@parties, @change.leader.from)} → {leader_name(
            @parties,
            @change.leader.to
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
