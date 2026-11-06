defmodule Iec.Repo.Migrations.CreateBoundaries do
  use Ecto.Migration

  def change do
    # Province, municipality and ward outlines from the IEC's election map, projected and
    # simplified into SVG path data in one shared coordinate space (see Iec.Maps.Geometry).
    create table(:boundaries) do
      add :level, :string, null: false
      add :area_id, :integer, null: false
      add :province_id, :integer
      add :municipality_id, :integer
      add :name, :string, null: false
      add :path, :text, null: false
      add :min_x, :integer, null: false
      add :min_y, :integer, null: false
      add :max_x, :integer, null: false
      add :max_y, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:boundaries, [:level, :area_id])
    create index(:boundaries, [:level, :province_id])
    create index(:boundaries, [:level, :municipality_id])
  end
end
