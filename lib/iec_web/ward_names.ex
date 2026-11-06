defmodule IecWeb.WardNames do
  @moduledoc """
  What to call a ward: its number, and a name from the towns and suburbs in it
  (`Iec.Places.list_ward_names/0`), as the IEC gives wards numbers only. Read once and
  shared, as places only change with an import.
  """

  @doc "Every ward's name, keyed by ward id."
  def all, do: Iec.Cache.fetch_lasting(:ward_names, &Iec.Places.list_ward_names/0)

  @doc "A ward's name (\"Bergvliet, Meadowridge\"), or nil without places in it."
  def name(ward_id), do: all()[ward_id]

  @doc "\"Ward 73 · Bergvliet, Meadowridge\", or \"Ward 73\" without a name."
  def label(ward_id, ward_number) do
    case name(ward_id) do
      nil -> "Ward #{ward_number}"
      name -> "Ward #{ward_number} · #{name}"
    end
  end

  @doc "Adds `ward_name` to rows with a `ward_id`."
  def with_names(rows) do
    names = all()
    Enum.map(rows, &Map.put(&1, :ward_name, names[&1.ward_id]))
  end
end
