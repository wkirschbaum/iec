defmodule IecWeb.ResultsComponents do
  @moduledoc "Formatters, and the tables, labels and change entries shared by the results pages."
  use IecWeb, :html

  alias Iec.Results.Change

  # South Africa has no daylight saving: SAST is always UTC+2.
  @sast_offset_seconds 2 * 60 * 60

  ## Formatting

  @doc "A number to a fixed count of decimals: 31.9."
  def format_decimal(value, decimals \\ 1),
    do: :erlang.float_to_binary(value / 1, decimals: decimals)

  @doc "A big number in short form: 20.7M, 412k, 980."
  def format_compact(nil), do: "–"

  def format_compact(number) when number >= 1_000_000,
    do: "#{format_decimal(number / 1_000_000)}M"

  def format_compact(number) when number >= 10_000, do: "#{round(number / 1_000)}k"
  def format_compact(number), do: format_number(number)

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

  @doc "A percentage, to two decimals in tables (31.94%) or fewer in sentences (31.9%)."
  def format_percentage(value, decimals \\ 2)
  def format_percentage(nil, _decimals), do: "–"
  def format_percentage(value, decimals), do: format_decimal(value, decimals) <> "%"

  @doc "A part of a whole as a percentage, rounded down like a count: 1.4%."
  def format_share_of(part, whole) when is_integer(part) and is_integer(whole) and whole > 0,
    do: format_progress(part / whole * 100)

  def format_share_of(_part, _whole), do: "–"

  @doc "A lead in percentage points: 2.00 pts."
  def format_points(nil), do: "–"
  def format_points(points), do: format_decimal(points, 2) <> " pts"

  @doc "A signed delta: votes and seats as integers, percentages as points."
  def format_delta(nil, _kind), do: "–"
  def format_delta(delta, _kind) when delta == 0, do: "0"
  def format_delta(delta, :points), do: sign(delta) <> format_decimal(abs(delta), 2)
  def format_delta(delta, :count), do: sign(delta) <> format_number(abs(delta))

  defp sign(delta) when delta > 0, do: "+"
  defp sign(_delta), do: "−"

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

  @doc "Whether a count is still running: fewer voting districts in than expected."
  def counting?(%{voting_districts_complete: complete, voting_districts_expected: expected})
      when is_integer(complete) and is_integer(expected),
      do: complete < expected

  def counting?(_snapshot_or_nil), do: false

  @doc "Whether a council's count is finished, from its municipality snapshot (or nil)."
  def council_decided?(%{municipalities_complete: 1}), do: true
  def council_decided?(_snapshot_or_nil), do: false

  @doc "How far along a count is, e.g. \"71.3%\", from counts or a percentage."
  def format_progress(complete, expected),
    do: format_progress(percentage_of(complete, expected))

  # Rounded down, so a count still running never reads 100.0%.
  def format_progress(percentage),
    do: format_decimal(Float.floor(percentage / 1, 1)) <> "%"

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
  def area_path(%{level: :ward, area_id: id}), do: ~p"/wards/#{id}"

  ## Components

  attr :parties, :map, required: true
  attr :party_result, :map, required: true

  attr :link, :boolean,
    default: true,
    doc: "false inside something that is itself a link: links must not nest"

  def party_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-2" title={Map.get(@party_result, :party_name)}>
      <span
        class="inline-block size-3 rounded-full shrink-0"
        style={"background-color: #{party_colour(@parties, @party_result)}"}
      />
      <.link
        :if={@link and @party_result.party_id >= 0}
        navigate={~p"/parties/#{@party_result.party_id}"}
        class="font-medium hover:underline"
      >
        {party_abbreviation(@parties, @party_result)}
      </.link>
      <span :if={not @link or @party_result.party_id < 0} class="font-medium">
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
    <span
      :if={@control && @control.majority}
      class="inline-flex flex-wrap items-center gap-x-2 gap-y-1"
    >
      <.party_label parties={@parties} party_result={%{party_id: @control.majority}} />
      <span class="opacity-60">majority</span>
    </span>
    <span
      :if={@control && is_nil(@control.majority) && @control.largest}
      class="inline-flex flex-wrap items-center gap-x-2 gap-y-1"
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

  attr :id, :string, required: true
  attr :rows, :list, required: true, doc: "from IecWeb.TableRows.party_rows/3"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true
  attr :show_councils, :boolean, default: false

  @doc "Parties' votes, share and seats, against the previous election. Sortable."
  def party_table(assigns) do
    ~H"""
    <.sortable_table
      id={@id}
      rows={@rows}
      sorts={@sorts}
      row_id={&"#{@id}-party-#{&1.party_id}"}
    >
      <:column :let={row} label="Party" field="party" first="asc">
        <.party_label parties={@parties} party_result={row} />
      </:column>
      <:column :let={row} label="Votes" field="votes" align="right">
        {format_number(row.votes)}
      </:column>
      <:column :let={row} label="Share" field="share" align="right">
        {format_percentage(row.share)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_share"
        align="right"
        class="opacity-60"
      >
        {format_percentage(row.previous_share)}
      </:column>
      <:column :let={row} label="Swing" field="swing" align="right" class={&delta_class(&1.swing)}>
        {format_delta(row.swing, :points)}
      </:column>
      <:column :let={row} label="Seats" field="seats" align="right">
        {format_number(row.seats)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_seats"
        align="right"
        class="opacity-60"
      >
        {format_number(row.previous_seats)}
      </:column>
      <:column :let={row} :if={@show_councils} label="Councils won" field="councils" align="right">
        {format_number(row.councils)}
      </:column>
      <:column
        :let={row}
        :if={@show_councils}
        label={"#{@previous_year}"}
        field="previous_councils"
        align="right"
        class="opacity-60"
      >
        {format_number(row.previous_councils)}
      </:column>
    </.sortable_table>
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
    <.sortable_table id={@id} rows={@rows} sorts={@sorts} row_id={&"#{@id}-#{&1.area_id}"}>
      <:column :let={row} label={@area_label} field="name" first="asc">
        <.link navigate={@area_path.(row.area_id)} class="link">{row.name}</.link>
      </:column>
      <:column :let={row} label="Districts counted" field="counted" align="right">
        {format_progress(row.counted)}
      </:column>
      <:column :let={row} :if={@show_council} label="Council" field="council" first="asc">
        <.council_control :if={row.complete} parties={@parties} control={row.control} />
        <span :if={not row.complete} class="badge badge-ghost badge-sm">counting</span>
      </:column>
      <:column :let={row} label="Leading" field="leader" first="asc">
        <.party_or_dash parties={@parties} party_id={row.leader_id} />
      </:column>
      <:column :let={row} label="Share" field="share" align="right">
        {format_percentage(row.share)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year} leader"}
        field="previous_leader"
        first="asc"
        class="opacity-60"
      >
        <.party_or_dash parties={@parties} party_id={row.previous_leader_id} />
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year} share"}
        field="previous_share"
        align="right"
        class="opacity-60"
      >
        {format_percentage(row.previous_share)}
      </:column>
    </.sortable_table>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true, doc: "from IecWeb.TableRows.ward_result_rows/3"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :sorts, :map, required: true

  @doc "Wards with who leads them, by how much, and who led before; each opens its page."
  def ward_results_table(assigns) do
    ~H"""
    <.sortable_table id={@id} rows={@rows} sorts={@sorts} row_id={&"#{@id}-#{&1.ward_id}"}>
      <:column :let={row} label="Ward" field="ward" first="asc" class="whitespace-nowrap">
        <.link navigate={~p"/wards/#{row.ward_id}"} class="link font-medium">
          <.ward_label number={row.ward_number} name={row[:ward_name]} />
        </.link>
        <span class="block text-xs opacity-60">{row.municipality_name}</span>
      </:column>
      <:column :let={row} label="Leading" field="leader" first="asc">
        <.party_or_dash parties={@parties} party_id={row.leader_id} empty="no results" />
      </:column>
      <:column :let={row} label="Share" field="share" align="right">
        {format_percentage(row.share)}
      </:column>
      <:column :let={row} label="Lead" field="margin" align="right" first="asc">
        {format_points(row.margin)}
      </:column>
      <:column
        :let={row}
        label={"#{@previous_year}"}
        field="previous_leader"
        first="asc"
        class="opacity-75"
      >
        <.party_or_dash parties={@parties} party_id={row.previous_leader_id} />
      </:column>
      <:column :let={row} label="Status" field="status" first="asc" class="opacity-75">
        {row.status}
      </:column>
    </.sortable_table>
    """
  end

  attr :number, :integer, required: true
  attr :name, :string, default: nil, doc: "from IecWeb.WardNames: the places in the ward"
  attr :class, :string, default: nil

  @doc "A ward by number and name: \"Ward 73 · Bergvliet, Meadowridge\"."
  def ward_label(assigns) do
    ~H"""
    <span class={@class}>
      Ward {@number}<span :if={@name} class="font-normal text-base-content/60"> · {@name}</span>
    </span>
    """
  end

  attr :ward_id, :integer, required: true
  attr :ward_number, :integer, required: true
  attr :result, :map, default: nil, doc: "from Iec.Maps.list_area_results/2"

  attr :name, :string,
    default: nil,
    doc: "the places in the ward, for its tooltip"

  attr :parties, :map, required: true
  attr :dimmed, :boolean, default: false, doc: "not what is being looked for"
  attr :current, :boolean, default: false, doc: "the ward being looked at, or the exact match"

  @doc """
  A ward's number on a button that opens it: a dot in its leader's colour, hollow while
  counting, grey before results.
  """
  def ward_chip(assigns) do
    assigns = assign(assigns, :title, ward_chip_title(assigns))

    ~H"""
    <.link
      navigate={~p"/wards/#{@ward_id}"}
      id={"ward-chip-#{@ward_id}"}
      class={[
        "flex min-h-10 items-center justify-center gap-1.5 rounded-lg border px-2 text-sm tabular-nums transition-all active:scale-95",
        @current && "border-base-content bg-base-content font-semibold text-base-100",
        !@current &&
          "border-base-300 bg-base-100 hover:-translate-y-px hover:border-base-content/30 hover:shadow-sm",
        @dimmed && "opacity-30 hover:opacity-100"
      ]}
      title={@title}
      aria-label={@title}
    >
      <span
        class={[
          "inline-block size-2.5 shrink-0 rounded-full",
          is_nil(@result) && "bg-base-300",
          @result && @result.status == :counting && "border-2 bg-transparent"
        ]}
        style={ward_chip_dot(@result, @parties)}
      />
      {@ward_number}
    </.link>
    """
  end

  defp ward_chip_title(%{ward_number: number, name: name, result: result, parties: parties}) do
    ward = if name, do: "Ward #{number} (#{name})", else: "Ward #{number}"
    ward_chip_result(ward, result, parties)
  end

  defp ward_chip_result(ward, nil, _parties), do: "#{ward}: no results yet"

  defp ward_chip_result(ward, result, parties) do
    verb = if result.status == :complete, do: "won by", else: "led by"

    "#{ward}: #{verb} #{party_abbreviation(parties, %{party_id: result.leader})} " <>
      "(#{format_percentage(result.share)})"
  end

  # The leader's colour: filled once declared, a ring while counting.
  defp ward_chip_dot(nil, _parties), do: nil

  defp ward_chip_dot(result, parties) do
    property = if result.status == :counting, do: "border-color", else: "background-color"
    "#{property}: #{party_colour(parties, %{party_id: result.leader})}"
  end

  attr :segments, :list, required: true, doc: "`[{text, matched?}]`"

  @doc "A name with the parts that matched a search marked."
  def highlighted(assigns) do
    ~H"""
    <span><span
      :for={{text, matched} <- @segments}
      class={matched && "rounded-sm bg-primary/15 text-primary"}
    >{text}</span></span>
    """
  end

  attr :event, :string, default: "show_more"
  attr :table, :string, required: true, doc: "the table it belongs to, sent with the event"
  attr :shown, :integer, required: true
  attr :total, :integer, required: true

  @doc "Shows more rows of a long table: \"Show more (25 of 120)\", until all are shown."
  def show_more(assigns) do
    ~H"""
    <button
      :if={@shown < @total}
      type="button"
      class="btn btn-ghost mt-2 min-h-10"
      phx-click={@event}
      phx-value-table={@table}
    >
      Show more <span class="opacity-60">({@shown} of {@total})</span>
    </button>
    """
  end

  attr :parties, :map, required: true
  attr :party_id, :integer, default: nil
  attr :empty, :string, default: "–"
  attr :link, :boolean, default: true, doc: "false inside a link"

  @doc "A party's label, or a dash (or `empty`) when there is none."
  def party_or_dash(assigns) do
    ~H"""
    <.party_label
      :if={@party_id}
      parties={@parties}
      party_result={%{party_id: @party_id}}
      link={@link}
    />
    <span :if={is_nil(@party_id)} class="opacity-60">{@empty}</span>
    """
  end

  attr :event, :map, required: true, doc: "from IecWeb.ChangeDigest"
  attr :parties, :map, required: true

  @doc "A notable event: a lead changing hands, or a council's count finishing."
  def highlight(assigns) do
    ~H"""
    <li class="flex items-start gap-4 px-4 py-3.5">
      <span class={[
        "mt-0.5 grid size-8 shrink-0 place-items-center rounded-full",
        @event.kind == :lead && "bg-warning/15 text-warning",
        @event.kind == :decided && "bg-success/15 text-success"
      ]}>
        <.icon name={highlight_icon(@event.kind)} class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-baseline justify-between gap-x-3">
          <.link navigate={area_path(@event.snapshot)} class="font-medium hover:underline">
            {@event.snapshot.area_name}
          </.link>
          <span class="text-xs tabular-nums text-base-content/50">{format_clock(@event.at)}</span>
        </div>
        <p
          :if={@event.kind == :lead}
          class="mt-0.5 flex flex-wrap items-center gap-1.5 text-sm text-base-content/70"
        >
          Lead passes from
          <.party_or_dash parties={@parties} party_id={@event.from && @event.from.party_id} /> to
          <.party_or_dash parties={@parties} party_id={@event.to && @event.to.party_id} />
        </p>
        <p
          :if={@event.kind == :decided}
          class="mt-0.5 flex flex-wrap items-center gap-1.5 text-sm text-base-content/70"
        >
          Count complete, largest party
          <.party_or_dash parties={@parties} party_id={@event.to && @event.to.party_id} />
        </p>
      </div>
    </li>
    """
  end

  defp highlight_icon(:lead), do: "hero-arrows-right-left-micro"
  defp highlight_icon(:decided), do: "hero-check-badge-micro"

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
          <span class="opacity-60">{format_delta(party.percentage, :points)} pts</span>
        </span>
      </div>
    </li>
    """
  end

  defp leader_name(_parties, nil), do: "none"
  defp leader_name(parties, party), do: party_abbreviation(parties, party)
end
