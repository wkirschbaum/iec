defmodule Iec.Repo.Migrations.CreatePartyResults do
  use Ecto.Migration

  def change do
    # Party files are views of the same count and change every minute or two, so their
    # bodies are not kept; the fetch row still records when each one landed.
    alter table(:fetches) do
      modify :body, :binary, null: true, from: {:binary, null: false}
    end

    # Which municipality each ward belongs to, from the IEC's municipality files.
    # Ward ids are the Demarcation Board's: the municipality's code then a three-digit
    # ward number.
    create table(:wards, primary_key: false) do
      add :id, :integer, primary_key: true
      add :municipality_id, :integer, null: false
      add :ward_number, :integer, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:wards, [:municipality_id])

    # One party's share of one ward, and whether it won the ward. first_won_at is when we
    # first saw the ward declared for this party.
    create table(:party_ward_results) do
      add :election, :integer, null: false
      add :party_id, :integer, null: false
      add :ward_id, :integer, null: false
      add :vote_percentage, :float
      add :won, :boolean, null: false, default: false
      add :first_won_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:party_ward_results, [:election, :party_id, :ward_id])
    create index(:party_ward_results, [:election, :ward_id], where: "won")

    # One party's share and seats in one municipal council, and whether it holds a
    # majority there.
    create table(:party_municipality_results) do
      add :election, :integer, null: false
      add :party_id, :integer, null: false
      add :municipality_id, :integer, null: false
      add :province_id, :integer
      add :vote_percentage, :float
      add :seats_won, :integer
      add :majority, :boolean, null: false, default: false
      add :council_winner, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:party_municipality_results, [:election, :party_id, :municipality_id])
  end
end
