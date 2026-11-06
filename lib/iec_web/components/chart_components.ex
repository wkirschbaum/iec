defmodule IecWeb.ChartComponents do
  @moduledoc """
  Line charts of trends across elections (data from `IecWeb.Trends`).

  The lines are an SVG stretched to the chart's box (strokes keep their width, dots stay
  round), while the axis labels are HTML laid over it, so text stays crisp and readable
  at any width, phones included.
  """
  use IecWeb, :html

  import IecWeb.ResultsComponents, only: [format_compact: 1]

  attr :id, :string, required: true
  attr :trend, :map, required: true, doc: "`%{years, series, max, step}`"
  attr :unit, :atom, default: :percent, values: [:percent, :count]
  attr :live_year, :integer, default: nil, doc: "drawn dashed while its count is running"
  attr :counting, :boolean, default: false
  attr :compact, :boolean, default: false, doc: "small multiples: no legend, fewer labels"

  def line_chart(assigns) do
    %{years: years, max: max, step: step} = assigns.trend
    first = List.first(years) || 0
    last = List.last(years) || 1
    span = max(last - first, 1)
    x = fn year -> 3 + (year - first) / span * 94 end
    y = fn value -> 100 - value / max * 100 end

    lines =
      for line <- assigns.trend.series do
        {settled, running} =
          if assigns.counting and List.keymember?(line.points, assigns.live_year, 0),
            do: Enum.split(line.points, -1),
            else: {line.points, []}

        %{
          line: line,
          path: line_path(settled, x, y),
          running_path:
            if(running != [] and settled != [],
              do: line_path([List.last(settled) | running], x, y)
            ),
          dots:
            for(
              {year, value} <- line.points,
              do: %{x: x.(year), y: y.(value), year: year, value: value}
            )
        }
      end

    assigns =
      assign(assigns,
        lines: lines,
        gridlines: gridlines(max, step) |> Enum.map(&{&1, y.(&1)}),
        ticks: Enum.map(years, &{&1, x.(&1)})
      )

    ~H"""
    <div id={@id} class="space-y-3">
      <div class={["relative", if(@compact, do: "ml-7 h-28", else: "ml-10 h-64 sm:h-72")]}>
        <div
          :for={{value, top} <- @gridlines}
          class="absolute inset-x-0 border-t border-dashed border-base-300"
          style={"top: #{top}%"}
        >
          <span class={[
            "absolute -translate-y-1/2 pr-2 text-right tabular-nums text-base-content/45",
            if(@compact, do: "-left-7 w-7 text-[0.6rem]", else: "-left-10 w-10 text-xs")
          ]}>
            {axis_label(value, @unit)}
          </span>
        </div>
        <svg
          viewBox="0 0 100 100"
          preserveAspectRatio="none"
          class="absolute inset-0 h-full w-full overflow-visible"
          role="img"
          aria-label="Trend chart"
        >
          <g :for={line <- @lines}>
            <path
              d={line.path}
              fill="none"
              stroke={line.line.colour}
              stroke-width={if @compact, do: 2, else: 2.5}
              stroke-linejoin="round"
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
            />
            <path
              :if={line.running_path}
              d={line.running_path}
              fill="none"
              stroke={line.line.colour}
              stroke-width={if @compact, do: 2, else: 2.5}
              stroke-dasharray="4 4"
              vector-effect="non-scaling-stroke"
            />
            <path
              :for={dot <- line.dots}
              d={"M#{dot.x} #{dot.y}h0"}
              stroke={line.line.colour}
              stroke-width={if @compact, do: 5, else: 8}
              stroke-linecap="round"
              vector-effect="non-scaling-stroke"
              class="transition-[stroke-width] hover:[stroke-width:12]"
            >
              <title>{line.line.label} {dot.year}: {value_label(dot.value, @unit)}</title>
            </path>
          </g>
        </svg>
      </div>
      <div class={["relative h-4", if(@compact, do: "ml-7", else: "ml-10")]}>
        <span
          :for={{year, left} <- @ticks}
          :if={not @compact or year in [List.first(@trend.years), List.last(@trend.years)]}
          class={[
            "absolute -translate-x-1/2 tabular-nums text-base-content/50",
            if(@compact, do: "text-[0.6rem]", else: "text-xs"),
            year == @live_year && @counting && "font-medium text-primary"
          ]}
          style={"left: #{left}%"}
        >
          {year}
        </span>
      </div>
      <ul :if={not @compact} class="flex flex-wrap gap-x-5 gap-y-1.5 pt-1 text-sm">
        <li :for={line <- @lines} class="inline-flex items-center gap-2">
          <span class="h-0.5 w-4 rounded-full" style={"background-color: #{line.line.colour}"} />
          <.link navigate={~p"/parties/#{line.line.party_id}"} class="font-medium hover:underline">
            {line.line.label}
          </.link>
          <span class="tabular-nums text-base-content/60">
            {line.line.points |> List.last() |> elem(1) |> value_label(@unit)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp line_path([], _x, _y), do: nil

  defp line_path([{year, value} | rest], x, y) do
    "M#{coordinate(x.(year))} #{coordinate(y.(value))}" <>
      Enum.map_join(rest, fn {year, value} ->
        "L#{coordinate(x.(year))} #{coordinate(y.(value))}"
      end)
  end

  defp coordinate(number), do: :erlang.float_to_binary(number / 1, decimals: 2)

  defp gridlines(max, step) do
    count = round(max / step)
    for index <- 0..count, do: index * step
  end

  defp axis_label(value, :percent), do: "#{round(value)}%"
  defp axis_label(value, :count) when value >= 1_000, do: "#{compact_thousands(value)}k"
  defp axis_label(value, :count), do: "#{round(value)}"

  defp compact_thousands(value) do
    thousands = value / 1_000
    if thousands == Float.round(thousands), do: round(thousands), else: Float.round(thousands, 1)
  end

  defp value_label(value, :percent), do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  defp value_label(value, :count), do: format_compact(round(value))
end
