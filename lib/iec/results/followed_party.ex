defmodule Iec.Results.FollowedParty do
  @moduledoc "A party whose file is followed: every party standing in the live election."
  use Ecto.Schema

  @primary_key {:party_id, :integer, autogenerate: false}
  schema "followed_parties" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
