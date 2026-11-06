defmodule Iec.Results.Party do
  @moduledoc "A party's abbreviation, name and colour, keyed by the IEC party id."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "parties" do
    field :abbreviation, :string
    field :name, :string
    field :colour, :string

    timestamps(type: :utc_datetime_usec)
  end
end
