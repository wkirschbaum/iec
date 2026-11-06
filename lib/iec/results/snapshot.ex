defmodule Iec.Results.Snapshot do
  @moduledoc """
  The figures of one area (national, a province or a municipality) at one point in time.
  A new snapshot is stored only when the area's figures differ from its previous one.
  """
  use Ecto.Schema

  @progress_fields [
    :registered_voters,
    :total_votes_cast,
    :valid_votes_cast,
    :spoilt_votes,
    :special_votes,
    :voting_districts_complete,
    :voting_districts_expected,
    :wards_complete,
    :wards_expected,
    :municipalities_complete,
    :municipalities_expected,
    :seats_complete,
    :seats_expected,
    :hung_councils,
    :majority_councils,
    :drawn_councils
  ]

  schema "snapshots" do
    belongs_to :fetch, Iec.Results.Fetch
    belongs_to :previous_snapshot, __MODULE__

    field :election, :integer
    field :level, Ecto.Enum, values: [:national, :province, :municipality]
    field :area_id, :integer
    field :area_name, :string
    field :province_id, :integer
    field :report_date, :utc_datetime_usec
    field :content_hash, :string

    for field_name <- @progress_fields do
      field field_name, :integer
    end

    has_many :party_results, Iec.Results.PartyResult, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def progress_fields, do: @progress_fields
end
