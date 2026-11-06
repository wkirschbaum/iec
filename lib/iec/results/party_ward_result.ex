defmodule Iec.Results.PartyWardResult do
  @moduledoc "One party's share of one ward, and whether it won it."
  use Ecto.Schema

  schema "party_ward_results" do
    field :election, :integer
    field :party_id, :integer
    field :ward_id, :integer
    field :vote_percentage, :float
    field :won, :boolean
    field :first_won_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
