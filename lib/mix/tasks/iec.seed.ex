defmodule Mix.Tasks.Iec.Seed do
  @shortdoc "Fills the database from the IEC's results feed"

  @moduledoc """
  Fills the database from the IEC's public results feed in one go (see `Iec.Seed`).

      mix iec.seed

  Safe to run again: it only adds what changed. The pollers are not started, so this can
  run while the server is up.
  """
  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(_arguments) do
    config = Application.fetch_env!(:iec, Iec.Results)
    Application.put_env(:iec, Iec.Results, Keyword.put(config, :poll, false))
    # Progress lines only, not every SQL query.
    Logger.configure(level: :info)
    Mix.Task.run("app.start")

    Iec.Seed.run(fn message -> Mix.shell().info(message) end)
  end
end
