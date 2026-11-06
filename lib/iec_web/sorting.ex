defmodule IecWeb.Sorting do
  @moduledoc """
  Sortable tables on every page. Mounted for all pages in the router, it keeps the sort of
  each table in `@sorts` (`%{table_id => {column, :asc | :desc}}`) and handles the
  `"sort"` event from `sort_header/1`.

  Rows are flat maps with one field per column (`IecWeb.TableRows`); a column sorts by
  the row field of the same name:

      <.sort_header table="parties" column="votes" sorts={@sorts} align="right">Votes</.sort_header>
      <tr :for={row <- sort_rows(@rows, @sorts["parties"])}>

  Sorting runs on the server, so it covers rows a paged table is not showing yet and
  holds across live updates. Missing values always sort last.
  """
  use Phoenix.Component

  import Phoenix.LiveView, only: [attach_hook: 4]

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:sorts, %{})
     |> attach_hook(:sorting, :handle_event, &handle_event/3)}
  end

  defp handle_event("sort", %{"table" => table, "column" => column} = params, socket) do
    direction =
      case socket.assigns.sorts[table] do
        {^column, :desc} -> :asc
        {^column, :asc} -> :desc
        _other_column -> if params["first"] == "asc", do: :asc, else: :desc
      end

    {:halt, update(socket, :sorts, &Map.put(&1, table, {column, direction}))}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  Rows in the table's chosen order, or unchanged without one. Text sorts
  case-insensitively, times chronologically, and rows missing the value come last.
  """
  def sort_rows(rows, nil), do: rows

  def sort_rows(rows, {column, direction}) do
    field = String.to_existing_atom(column)
    {present, missing} = Enum.split_with(rows, &(not is_nil(Map.get(&1, field))))
    Enum.sort_by(present, &comparable(Map.get(&1, field)), direction) ++ missing
  rescue
    # A column name that is no field at all leaves the rows as they are.
    ArgumentError -> rows
  end

  defp comparable(value) when is_binary(value), do: String.downcase(value)
  defp comparable(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp comparable(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&comparable/1) |> List.to_tuple()

  defp comparable(true), do: 1
  defp comparable(false), do: 0
  defp comparable(value), do: value

  attr :table, :string, required: true
  attr :column, :string, required: true
  attr :sorts, :map, required: true
  attr :first, :string, default: "desc", doc: "direction of the first click: desc for numbers"
  attr :align, :string, default: "left", values: ["left", "right"]
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A `<th>` that sorts its table when clicked, showing the current direction."
  def sort_header(assigns) do
    assigns =
      assign(
        assigns,
        :direction,
        case assigns.sorts[assigns.table] do
          {column, direction} when column == assigns.column -> direction
          _other -> nil
        end
      )

    ~H"""
    <th
      class={@align == "right" && "text-right"}
      aria-sort={
        case @direction do
          :asc -> "ascending"
          :desc -> "descending"
          nil -> "none"
        end
      }
      {@rest}
    >
      <button
        type="button"
        phx-click="sort"
        phx-value-table={@table}
        phx-value-column={@column}
        phx-value-first={@first}
        class={[
          "group inline-flex cursor-pointer items-center gap-1 whitespace-nowrap hover:text-base-content",
          @align == "right" && "flex-row-reverse",
          @direction && "text-base-content"
        ]}
      >
        {render_slot(@inner_block)}
        <span class={["text-[0.6rem]", is_nil(@direction) && "opacity-0 group-hover:opacity-40"]}>
          {if @direction == :asc, do: "▲", else: "▼"}
        </span>
      </button>
    </th>
    """
  end
end
