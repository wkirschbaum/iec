defmodule Iec.Places.Place do
  @moduledoc "A town or suburb from OpenStreetMap, and the live ward it lies in (if any)."
  use Ecto.Schema

  schema "places" do
    field :osm_type, :string
    field :osm_id, :integer
    field :name, :string
    field :alternate_names, {:array, :string}, default: []
    field :kind, :string
    field :population, :integer
    field :latitude, :float
    field :longitude, :float
    field :ward_id, :integer
    field :municipality_id, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
