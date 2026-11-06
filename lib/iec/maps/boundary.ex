defmodule Iec.Maps.Boundary do
  @moduledoc "One area's outline as SVG path data, with its bounding box in map units."
  use Ecto.Schema

  schema "boundaries" do
    field :election, :integer
    field :level, Ecto.Enum, values: [:province, :municipality, :ward]
    field :area_id, :integer
    field :province_id, :integer
    field :municipality_id, :integer
    field :name, :string
    field :path, :string
    field :overview_path, :string
    field :area, :integer
    field :redrawn, :boolean, default: false
    field :min_x, :integer
    field :min_y, :integer
    field :max_x, :integer
    field :max_y, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
