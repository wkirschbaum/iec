defmodule IecWeb.DesignComponents do
  @moduledoc """
  The building blocks of every page's look: page headers, section headings, linked rows
  and cards, key figures, the vote-share bar and swing chips. See docs/design.md.
  """
  use IecWeb, :html

  import IecWeb.ResultsComponents

  attr :eyebrow, :string, default: nil
  attr :live, :boolean, default: false, doc: "a pulsing dot before the eyebrow while counting"
  attr :accent, :string, default: nil, doc: "a colour shown as a bar beside the title"
  attr :title, :string, required: true
  attr :crumbs, :list, default: [], doc: "the pages above this one, `[{label, path}]`"
  slot :lede
  slot :actions

  @doc "A page's opening: a small label, a serif title, a one-line summary, and actions."
  def page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-x-8 gap-y-4">
      <div class="max-w-3xl space-y-2">
        <nav :if={@crumbs != []} class="text-sm text-base-content/60" aria-label="Breadcrumb">
          <span :for={{label, path} <- @crumbs}>
            <.link navigate={path} class="link-hover link">{label}</.link> /
          </span>
        </nav>
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

  attr :eyebrow, :string, required: true
  attr :title, :string, default: "Not found"
  slot :inner_block, required: true, doc: "why, and where to look instead"

  @doc "The opening of a page for something with no results yet, or that does not exist."
  def not_found(assigns) do
    ~H"""
    <.page_header eyebrow={@eyebrow} title={@title} crumbs={[{"Overview", ~p"/"}]}>
      <:lede>{render_slot(@inner_block)}</:lede>
    </.page_header>
    """
  end

  attr :rest, :global
  slot :inner_block, required: true

  @doc "A quiet note where a section has nothing to show yet."
  def empty(assigns) do
    ~H"""
    <p class="text-sm text-base-content/60" {@rest}>{render_slot(@inner_block)}</p>
    """
  end

  attr :navigate, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: "min-h-12 py-2.5", doc: "height and padding, and any more"
  attr :chevron, :boolean, default: true
  attr :rest, :global
  slot :inner_block, required: true

  @doc """
  A row of a linked list (inside `<ul class="panel divide-y …">`): the whole row is one
  link, with a chevron that nudges on hover.
  """
  def link_row(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      id={@id}
      class={[
        "group flex items-center gap-3 px-4 transition-colors hover:bg-base-200/70 focus-visible:bg-base-200 focus-visible:outline-none",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
      <.icon
        :if={@chevron}
        name="hero-chevron-right-micro"
        class="size-4 text-base-content/30 transition-transform group-hover:translate-x-0.5"
      />
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: "block space-y-3 p-5", doc: "layout and padding"
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A card that is one link, raised slightly on hover."
  def link_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      id={@id}
      class={[
        "panel group transition-all hover:-translate-y-0.5 hover:border-base-content/20 hover:shadow-lg focus-visible:outline-2 focus-visible:outline-primary",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
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

  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc "A key figure that is not a number, such as a party: a small label over it."
  def fact(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <div class="eyebrow">{@label}</div>
      <div class="mt-2 space-y-1">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :parties, :map, required: true
  attr :control, :map, default: nil, doc: "from Iec.Parties.get_council_control/1"
  attr :decided, :boolean, required: true, doc: "whether the council's count is finished"
  slot :inner_block, doc: "more under it, such as who ran it before"

  @doc "Who runs a council now, or who leads it while its count runs."
  def council_fact(assigns) do
    ~H"""
    <.fact label={if @decided, do: "Council now", else: "Council so far"}>
      <.council_control parties={@parties} control={@control} counting={not @decided} />
      {render_slot(@inner_block)}
    </.fact>
    """
  end

  attr :snapshot, :map, required: true

  @doc "How many voting districts are counted: the share, and how many of how many."
  def districts_kpi(assigns) do
    ~H"""
    <.kpi
      label="Districts counted"
      value={
        format_progress(@snapshot.voting_districts_complete, @snapshot.voting_districts_expected)
      }
    >
      {format_number(@snapshot.voting_districts_complete)} of {format_number(
        @snapshot.voting_districts_expected
      )}
    </.kpi>
    """
  end

  attr :snapshot, :map, required: true, doc: "the national or a province's snapshot"
  slot :votes_note, required: true, doc: "under the votes counted"

  @doc "The count's key figures for an area of many councils: districts, votes, councils."
  def count_kpis(assigns) do
    ~H"""
    <.districts_kpi snapshot={@snapshot} />
    <.kpi label="Votes counted" value={format_compact(@snapshot.total_votes_cast)}>
      {render_slot(@votes_note)}
    </.kpi>
    <.kpi
      label="Councils decided"
      value={"#{@snapshot.municipalities_complete} / #{@snapshot.municipalities_expected}"}
    >
      {@snapshot.majority_councils} with a majority
    </.kpi>
    <.kpi label="Hung councils" value={format_number(@snapshot.hung_councils)}>
      no party over half the seats
    </.kpi>
    """
  end

  attr :highlights, :list, required: true, doc: "from IecWeb.ChangeDigest.highlights/1"
  attr :parties, :map, required: true
  attr :area, :string, default: nil, doc: "the area they are in, when not the whole country"

  @doc "Leads changing hands and councils decided, newest first."
  def highlights(assigns) do
    ~H"""
    <section class="space-y-4">
      <.section_heading title="Highlights">
        <:subtitle>
          Leads changing hands and councils decided{if @area, do: " in #{@area}"}
        </:subtitle>
        <:actions :if={is_nil(@area)}>
          <.link navigate={~p"/changes"} class="link-hover link">All changes →</.link>
        </:actions>
      </.section_heading>
      <.empty :if={@highlights == []}>
        No lead has changed hands{if @area, do: " here"} since start-up.
      </.empty>
      <ul :if={@highlights != []} class="panel divide-y divide-base-300">
        <.highlight :for={event <- @highlights} event={event} parties={@parties} />
      </ul>
    </section>
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
      {format_decimal(abs(@value))}
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
        "#{format_decimal(x.(year))} #{format_decimal(y.(value))}"
      end)

    {_year, last_value} = List.last(points)

    %{
      path: "M" <> Enum.join(coordinates, "L"),
      last_x: format_decimal(x.(last_year)),
      last_y: format_decimal(y.(last_value))
    }
  end

  defp sparkline_title(label, [{first_year, first} | _rest] = points) do
    {last_year, last} = List.last(points)

    "#{if label, do: "#{label}: "}#{format_percentage(first)} in #{first_year}, " <>
      "#{format_percentage(last)} in #{last_year}"
  end

  defp sparkline_title(_label, []), do: nil
end
