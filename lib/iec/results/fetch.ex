defmodule Iec.Results.Fetch do
  @moduledoc """
  A downloaded file with new content (national and province files keep their gzipped
  body), or a record that a one-off file was read or does not exist, so it is not asked
  for again (`Iec.Results.record_read!/3`).
  """
  use Ecto.Schema

  schema "fetches" do
    field :election, :integer
    field :feed, :string
    field :url, :string
    field :etag, :string
    field :last_modified, :string
    field :report_date, :utc_datetime_usec
    field :body_bytes, :integer
    field :body, :binary, redact: true

    has_many :snapshots, Iec.Results.Snapshot

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
