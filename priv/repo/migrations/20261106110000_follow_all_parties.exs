defmodule Iec.Repo.Migrations.FollowAllParties do
  use Ecto.Migration

  def change do
    # Every party standing anywhere, found in the municipality files, so ward winners are
    # known for all parties rather than only the national list.
    create table(:followed_parties, primary_key: false) do
      add :party_id, :integer, primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Outlines per election, so 2021 wards can be compared with their 2026 namesakes.
    # `redrawn` marks a 2026 ward whose shape differs from the 2021 ward with its id, and
    # `overview_path` is a coarser outline for showing every ward in the country at once.
    alter table(:boundaries) do
      add :election, :integer, null: false, default: 2026
      add :area, :bigint
      add :redrawn, :boolean, null: false, default: false
      add :overview_path, :text
    end

    drop unique_index(:boundaries, [:level, :area_id])
    create unique_index(:boundaries, [:election, :level, :area_id])
  end
end
