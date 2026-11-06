defmodule Iec.Results.Ward do
  @moduledoc "A ward and the municipality it belongs to."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "wards" do
    field :municipality_id, :integer
    field :ward_number, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Ward ids end in a three-digit ward number; the rest is the municipality's code."
  def municipality_code(ward_id), do: div(ward_id, 1000)
  def ward_number(ward_id), do: rem(ward_id, 1000)
end
