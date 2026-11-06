defmodule IecWeb.DesignComponents do
  @moduledoc """
  The building blocks of every page's look: page headers, section headings, key figures,
  the vote-share bar and swing chips. See docs/design.md.
  """
  use IecWeb, :html

  import IecWeb.ResultsComponents,
    only: [format_percentage: 1, party_abbreviation: 2, party_colour: 2]

  attr :eyebrow, :string, default: nil
  attr :live, :boolean, default: false, doc: "a pulsing dot before the eyebrow while counting"
  attr :accent, :string, default: nil, doc: "a colour shown as a bar beside the title"
  attr :title, :string, required: true
  slot :breadcrumb
  slot :lede
  slot :actions

  @doc "A page's opening: a small label, a serif title, a one-line summary, and actions."
  def page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
      <div class="max-w-3xl space-y-2">
        <div :if={@breadcrumb != []} class="text-sm text-base-content/60">
          {render_slot(@breadcrumb)}
        </div>
        <p :if={@eyebrow} class="eyebrow flex items-center gap-2">
          <span :if={@live} class="relative flex size-2">
            <span class="absolute inline-flex size-full motion-safe:animate-ping rounded-full bg-primary/50" />
            <span class="relative inline-flex size-2 rounded-full bg-primary" />
          </span>
          {@eyebrow}
        </p>
        <h1 class="flex items-center gap-3 text-3xl font-medium leading-tight sm:text-[2.6rem]">
          <span
            :if={@accent}
            class="inline-block h-[0.85em] w-2 shrink-0 rounded-full"
            style={"background-color: #{@accent}"}
          />
          {@title}
        </h1>
        <p :if={@lede != []} class="text-base leading-relaxed text-base-content/70 sm:text-lg">
          {render_slot(@lede)}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :title, :string, required: true
  attr :id, :string, default: nil
  slot :subtitle
  slot :actions

  @doc "A section's heading over a hairline rule."
  def section_heading(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300 pb-2">
      <div>
        <h2 class="text-xl font-medium">{@title}</h2>
        <p :if={@subtitle != []} class="text-sm text-base-content/60">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="text-sm">{render_slot(@actions)}</div>
    </div>
    """
  end

  slot :option, required: true do
    attr :patch, :string, required: true
    attr :active, :boolean
  end

  @doc "A segmented control of patch links: one pill per option, the active one raised."
  def segmented(assigns) do
    ~H"""
    <div class="inline-flex max-w-full overflow-x-auto rounded-full border border-base-300 bg-base-200/70 p-1 text-sm">
      <.link
        :for={option <- @option}
        patch={option.patch}
        class={[
          "inline-flex min-h-10 items-center whitespace-nowrap rounded-full px-3.5 transition-all active:scale-95",
          option[:active] && "bg-base-100 font-medium text-base-content shadow-sm",
          !option[:active] && "text-base-content/65 hover:text-base-content"
        ]}
      >
        {render_slot(option)}
      </.link>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block

  @doc "A key figure: a small label, a big serif number, an optional note."
  def kpi(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <div class="eyebrow">{@label}</div>
      <div class="mt-1 font-serif text-3xl font-medium tabular-nums leading-none tracking-tight">
        {@value}
      </div>
      <div :if={@inner_block != []} class="mt-1.5 text-sm text-base-content/60 tabular-nums">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :value, :any, required: true, doc: "a swing in percentage points, or nil"
  attr :class, :string, default: nil

  @doc "A swing as a small coloured chip: ▲ 2.8 or ▼ 13.7, or \"new\" without a value."
  def swing_chip(assigns) do
    # Rounded first, so the arrow agrees with the figure: +0.04 is level, not "▲ 0.0".
    assigns = update(assigns, :value, &if(is_number(&1), do: Float.round(&1 / 1, 1)))

    ~H"""
    <span
      :if={is_number(@value)}
      class={[
        "inline-flex items-center gap-0.5 rounded-full px-1.5 py-0.5 text-xs font-medium tabular-nums",
        @value > 0 && "bg-success/12 text-success",
        @value < 0 && "bg-error/12 text-error",
        @value == 0 && "bg-base-200 text-base-content/60",
        @class
      ]}
    >
      {cond do
        @value > 0 -> "▲"
        @value < 0 -> "▼"
        true -> "■"
      end}
      {:erlang.float_to_binary(abs(@value) / 1, decimals: 1)}
    </span>
    <span
      :if={is_nil(@value)}
      class={["rounded-full bg-base-200 px-1.5 py-0.5 text-xs text-base-content/60", @class]}
    >
      new
    </span>
    """
  end

  attr :rows, :list, required: true, doc: "party rows with :party_id, :share, :previous_share"
  attr :parties, :map, required: true
  attr :previous_year, :integer, required: true
  attr :limit, :integer, default: 6

  @doc """
  Vote share as one stacked bar, biggest parties first and the rest as "Others", with the
  previous election as a thin bar underneath and a legend of shares and swings.
  """
  def vote_share_bar(assigns) do
    {shown, rest} =
      assigns.rows
      |> Enum.filter(&(&1.party_id >= 0 and (&1.share || 0) > 0))
      |> Enum.sort_by(&(-&1.share))
      |> Enum.split(assigns.limit)

    others = rest |> Enum.map(& &1.share) |> Enum.sum()

    previous =
      assigns.rows
      |> Enum.filter(&(&1.party_id >= 0 and (&1.previous_share || 0) > 0))
      |> Enum.sort_by(&(-&1.previous_share))

    assigns = assign(assigns, shown: shown, others: others, previous: previous)

    ~H"""
    <div class="space-y-3">
      <div class="flex h-9 w-full overflow-hidden rounded-md bg-base-200">
        <div
          :for={row <- @shown}
          class="relative h-full overflow-hidden border-r-2 border-base-100 transition-[width] duration-1000 last:border-r-0"
          style={"width: #{row.share}%; background-color: #{party_colour(@parties, row)}"}
          title={"#{party_abbreviation(@parties, row)}: #{format_percentage(row.share)}"}
        >
          <span
            :if={row.share >= 10}
            class={[
              "absolute inset-y-0 left-2 right-1 flex items-center truncate text-xs font-semibold",
              label_colour(party_colour(@parties, row))
            ]}
          >
            {party_abbreviation(@parties, row)}
          </span>
        </div>
        <div
          :if={@others > 0}
          class="h-full bg-base-300 transition-[width] duration-1000"
          style={"width: #{@others}%"}
          title={"Others: #{format_percentage(@others)}"}
        />
      </div>
      <div class="flex items-center gap-3">
        <span class="w-9 shrink-0 text-[0.65rem] tabular-nums text-base-content/50">
          {@previous_year}
        </span>
        <div class="flex h-1.5 w-full overflow-hidden rounded-full bg-base-200 opacity-70">
          <div
            :for={row <- @previous}
            class="h-full"
            style={"width: #{row.previous_share}%; background-color: #{party_colour(@parties, row)}"}
          />
        </div>
      </div>
      <ul class="flex flex-wrap gap-x-5 gap-y-2 pt-1 text-sm">
        <li :for={row <- @shown} class="inline-flex items-center gap-2">
          <span
            class="inline-block size-2.5 rounded-full"
            style={"background-color: #{party_colour(@parties, row)}"}
          />
          <.link navigate={~p"/parties/#{row.party_id}"} class="font-medium hover:underline">
            {party_abbreviation(@parties, row)}
          </.link>
          <span class="tabular-nums">{format_percentage(row.share)}</span>
          <.swing_chip value={row.swing} />
        </li>
      </ul>
    </div>
    """
  end

  # Dark text on a light party colour, light text on a dark one.
  defp label_colour("#" <> hex) when byte_size(hex) in [3, 6] do
    hex =
      if byte_size(hex) == 3,
        do: hex |> String.graphemes() |> Enum.map_join(&(&1 <> &1)),
        else: hex

    case Integer.parse(hex, 16) do
      {value, ""} ->
        <<red, green, blue>> = <<value::24>>

        if 0.299 * red + 0.587 * green + 0.114 * blue > 150,
          do: "text-black/75",
          else: "text-white/90"

      _not_hex ->
        "text-black/75"
    end
  end

  defp label_colour(_colour), do: "text-black/75"

  attr :segments, :list, required: true, doc: "`{party_id, share}`, biggest first"
  attr :parties, :map, required: true

  @doc "A thin stacked bar of the top parties' shares, for cards."
  def mini_share_bar(assigns) do
    ~H"""
    <div class="flex h-1.5 w-full overflow-hidden rounded-full bg-base-200">
      <div
        :for={{party_id, share} <- @segments}
        class="h-full transition-[width] duration-1000"
        style={"width: #{share}%; background-color: #{party_colour(@parties, %{party_id: party_id})}"}
      />
    </div>
    """
  end

  attr :points, :list, required: true, doc: "`[{year, value}]`, oldest first"
  attr :colour, :string, required: true
  attr :label, :string, default: nil, doc: "who the line is for, in its tooltip"
  attr :class, :string, default: "h-6 w-16"

  @doc """
  A small trend line across elections, for cards: scaled to its own range, the latest
  election as a dot. Nothing with fewer than two elections.
  """
  def sparkline(assigns) do
    assigns = assign(assigns, :shape, sparkline_shape(assigns.points))

    ~H"""
    <svg
      :if={@shape}
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      class={["shrink-0 overflow-visible", @class]}
      role="img"
      aria-label={sparkline_title(@label, @points)}
    >
      <title>{sparkline_title(@label, @points)}</title>
      <path
        d={@shape.path}
        fill="none"
        stroke={@colour}
        stroke-width="1.75"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
        opacity="0.8"
      />
      <path
        d={"M#{@shape.last_x} #{@shape.last_y}h0"}
        stroke={@colour}
        stroke-width="5"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp sparkline_shape(points) when length(points) < 2, do: nil

  defp sparkline_shape(points) do
    {first_year, _value} = List.first(points)
    {last_year, _value} = List.last(points)
    values = Enum.map(points, &elem(&1, 1))
    {low, high} = {Enum.min(values), Enum.max(values)}
    span = max(high - low, 1.0)
    x = fn year -> (year - first_year) / max(last_year - first_year, 1) * 100 end
    y = fn value -> 27 - (value - low) / span * 24 end

    coordinates =
      Enum.map(points, fn {year, value} ->
        "#{:erlang.float_to_binary(x.(year) / 1, decimals: 1)} #{:erlang.float_to_binary(y.(value) / 1, decimals: 1)}"
      end)

    {_year, last_value} = List.last(points)

    %{
      path: "M" <> Enum.join(coordinates, "L"),
      last_x: :erlang.float_to_binary(x.(last_year) / 1, decimals: 1),
      last_y: :erlang.float_to_binary(y.(last_value) / 1, decimals: 1)
    }
  end

  defp sparkline_title(label, [{first_year, first} | _rest] = points) do
    {last_year, last} = List.last(points)

    "#{if label, do: "#{label}: "}#{format_percentage(first)} in #{first_year}, " <>
      "#{format_percentage(last)} in #{last_year}"
  end

  defp sparkline_title(_label, []), do: nil
end
