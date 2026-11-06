defmodule Iec.Repo do
  use Ecto.Repo,
    otp_app: :iec,
    adapter: Ecto.Adapters.Postgres
end
