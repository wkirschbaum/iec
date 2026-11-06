defmodule Iec.Repo.Migrations.CreatePlaces do
  use Ecto.Migration

  def change do
    # Towns and suburbs from OpenStreetMap, each placed in the live ward that holds it, so
    # a ward can be found by a place name the IEC itself never publishes.
    create table(:places) do
      add :osm_type, :string, null: false
      add :osm_id, :bigint, null: false
      add :name, :string, null: false
      add :alternate_names, {:array, :string}, null: false, default: []
      add :kind, :string, null: false
      add :population, :bigint
      add :latitude, :float, null: false
      add :longitude, :float, null: false
      add :ward_id, :integer
      add :municipality_id, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:places, [:osm_type, :osm_id])
    create index(:places, [:ward_id])
  end
end
