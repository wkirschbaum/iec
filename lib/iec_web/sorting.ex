defmodule IecWeb.Sorting do
  @moduledoc ~S"""
  Sortable tables on every page. Mounted for all pages in the router, it keeps the sort of
  each table in `@sorts` (`%{table_id => {column, :asc | :desc}}`) and handles the
  `"sort"` event from `sort_header/1`.

  Rows are flat maps with one field per column (`IecWeb.TableRows`); a column sorts by
  the row field it names:

      <.sortable_table id="parties" rows={@rows} sorts={@sorts} row_id={&"party-#{&1.party_id}"}>
        <:column :let={row} label="Votes" field="votes" align="right">{row.votes}</:column>
      </.sortable_table>

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

  defp aria_sort(:asc), do: "ascending"
  defp aria_sort(:desc), do: "descending"
  defp aria_sort(nil), do: "none"

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
      aria-sort={aria_sort(@direction)}
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

  @doc """
  The first `limit` rows in the table's chosen order, for a table that shows more on
  request: `%{rows, shown, total}`.
  """
  def sorted_page(rows, sort, limit) do
    visible = rows |> sort_rows(sort) |> Enum.take(limit)
    %{rows: visible, shown: length(visible), total: length(rows)}
  end

  attr :id, :string, default: nil
  attr :sort_key, :string, default: nil, doc: "its key in `sorts`, if not its id"
  attr :rows, :list, required: true
  attr :sorts, :map, required: true
  attr :sorted, :boolean, default: false, doc: "rows already in order (and paged)"
  attr :row_id, :any, required: true, doc: "row → the row's id"
  attr :row_class, :any, default: nil, doc: "row → its classes"
  attr :class, :any, default: nil, doc: "for the scrolling box around the table"

  slot :column, required: true do
    attr :label, :string, required: true
    attr :field, :string, required: true, doc: "the row field it sorts by"
    attr :first, :string
    attr :align, :string
    attr :class, :any, doc: "for its cells: classes, or row → classes"
  end

  slot :inner_block, doc: "under the table: a show-more button, notes"

  @doc """
  A sortable table, each column once: its heading and what its cells show (see the
  module doc). Right-aligned columns line up their figures; the table scrolls sideways.
  """
  def sortable_table(assigns) do
    key = assigns.sort_key || assigns.id
    rows = if assigns.sorted, do: assigns.rows, else: sort_rows(assigns.rows, assigns.sorts[key])
    assigns = assign(assigns, key: key, visible: rows)

    ~H"""
    <div class={["overflow-x-auto", @class]}>
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <.sort_header
              :for={column <- @column}
              table={@key}
              column={column.field}
              sorts={@sorts}
              first={column[:first] || "desc"}
              align={column[:align] || "left"}
            >
              {column.label}
            </.sort_header>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @visible} id={@row_id.(row)} class={@row_class && @row_class.(row)}>
            <td
              :for={column <- @column}
              class={[
                column[:align] == "right" && "text-right tabular-nums",
                cell_class(column[:class], row)
              ]}
            >
              {render_slot(column, row)}
            </td>
          </tr>
        </tbody>
      </table>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp cell_class(class, row) when is_function(class, 1), do: class.(row)
  defp cell_class(class, _row), do: class
end
