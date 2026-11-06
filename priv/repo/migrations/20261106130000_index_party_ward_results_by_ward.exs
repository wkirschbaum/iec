defmodule Iec.Repo.Migrations.IndexPartyWardResultsByWard do
  use Ecto.Migration

  # Built without locking writes, so the pollers keep storing party files meanwhile.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # A ward's page, its map and the ward search read every party's row for a few wards;
    # the unique index leads with the party, so those reads scanned the table.
    create_if_not_exists index(:party_ward_results, [:ward_id, :election], concurrently: true)
  end
end
