defmodule Iec.Results.Fetch do
  @moduledoc "A feed download that returned new content, with its gzipped body."
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
