defmodule Iec.Repo.Migrations.CreateResults do
  use Ecto.Migration

  def change do
    # One row per feed download that returned new content (HTTP 200). The gzipped body is
    # kept so the history can be re-ingested if the parser changes.
    create table(:fetches) do
      add :election, :integer, null: false
      add :feed, :string, null: false
      add :url, :string, null: false
      add :etag, :string
      add :last_modified, :string
      add :report_date, :utc_datetime_usec
      add :body_bytes, :integer, null: false
      add :body, :binary, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:fetches, [:election, :feed, :inserted_at])

    # One row per area (national, a province or a municipality) each time its figures
    # change. previous_snapshot_id points at the area's snapshot before this one.
    create table(:snapshots) do
      add :fetch_id, references(:fetches, on_delete: :delete_all), null: false
      add :previous_snapshot_id, references(:snapshots, on_delete: :nilify_all)
      add :election, :integer, null: false
      add :level, :string, null: false
      add :area_id, :integer, null: false
      add :area_name, :string, null: false
      add :province_id, :integer
      add :report_date, :utc_datetime_usec
      add :content_hash, :string, null: false

      add :registered_voters, :integer
      add :total_votes_cast, :integer
      add :valid_votes_cast, :integer
      add :spoilt_votes, :integer
      add :special_votes, :integer

      add :voting_districts_complete, :integer
      add :voting_districts_expected, :integer
      add :wards_complete, :integer
      add :wards_expected, :integer
      add :municipalities_complete, :integer
      add :municipalities_expected, :integer
      add :seats_complete, :integer
      add :seats_expected, :integer
      add :hung_councils, :integer
      add :majority_councils, :integer
      add :drawn_councils, :integer

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:snapshots, [:election, :level, :area_id, :id])
    create index(:snapshots, [:election, :province_id, :level])
    create index(:snapshots, [:inserted_at])

    create table(:party_results) do
      add :snapshot_id, references(:snapshots, on_delete: :delete_all), null: false
      add :party_id, :integer, null: false
      add :party_name, :string
      add :position, :integer
      add :total_valid_votes, :integer
      add :vote_percentage, :float
      add :ward_votes, :integer
      add :pr_votes, :integer
      add :ward_seats_won, :integer
      add :pr_seats_won, :integer
      add :total_seats_won, :integer
      add :available_seats, :integer
      add :councils_won, :integer
      add :majority_won, :integer
      add :council_winner, :boolean
    end

    create index(:party_results, [:snapshot_id])

    # Party names, abbreviations and colours from the dashboard's PartyList.js. The 2021
    # result files carry only party ids, so names come from here.
    create table(:parties, primary_key: false) do
      add :id, :integer, primary_key: true
      add :abbreviation, :string, null: false
      add :name, :string, null: false
      add :colour, :string

      timestamps(type: :utc_datetime_usec)
    end
  end
end
