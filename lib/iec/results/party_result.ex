defmodule Iec.Results.PartyResult do
  @moduledoc "One party's votes and seats within a snapshot."
  use Ecto.Schema

  schema "party_results" do
    belongs_to :snapshot, Iec.Results.Snapshot

    field :party_id, :integer
    field :party_name, :string
    field :position, :integer
    field :total_valid_votes, :integer
    field :vote_percentage, :float
    field :ward_votes, :integer
    field :pr_votes, :integer
    field :ward_seats_won, :integer
    field :pr_seats_won, :integer
    field :total_seats_won, :integer
    field :available_seats, :integer
    field :councils_won, :integer
    field :majority_won, :integer
    field :council_winner, :boolean
  end
end
