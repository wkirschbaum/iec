defmodule Iec.Results.PartyMunicipalityResult do
  @moduledoc "One party's share and seats in one council, and whether it holds a majority."
  use Ecto.Schema

  schema "party_municipality_results" do
    field :election, :integer
    field :party_id, :integer
    field :municipality_id, :integer
    field :province_id, :integer
    field :vote_percentage, :float
    field :seats_won, :integer
    field :majority, :boolean
    field :council_winner, :boolean

    timestamps(type: :utc_datetime_usec)
  end
end
