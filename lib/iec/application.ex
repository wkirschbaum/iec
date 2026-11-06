defmodule Iec.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        IecWeb.Telemetry,
        Iec.Repo,
        {DNSCluster, query: Application.get_env(:iec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Iec.PubSub},
        {Registry, keys: :unique, name: Iec.Results.Registry},
        Iec.Cache,
        {Task.Supervisor, name: Iec.TaskSupervisor},
        {DynamicSupervisor, name: Iec.Parties.Pollers, strategy: :one_for_one}
      ] ++
        pollers() ++
        [IecWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    options = [strategy: :one_for_one, name: Iec.Supervisor]
    Supervisor.start_link(children, options)
  end

  # One poller per feed file, started a couple of seconds apart so the first round of
  # requests does not hit the IEC all at once.
  # Alongside them a one-off task refreshes the party list, imports what is not stored
  # yet (the previous election, map outlines, town and suburb names, municipality files),
  # and follows every party standing.
  defp pollers do
    if Application.fetch_env!(:iec, Iec.Results)[:poll] do
      setup =
        Supervisor.child_spec(
          {Task,
           fn ->
             run_setup_step(&Iec.Results.refresh_parties/0)
             run_setup_step(&Iec.Results.import_previous_election/0)
             run_setup_step(&Iec.Results.import_history/0)
             run_setup_step(&Iec.Parties.follow_national_parties/0)
             run_setup_step(&Iec.Maps.import_boundaries/0)
             # Its own task: Overpass may be busy for hours, which must not hold up the rest.
             Task.Supervisor.start_child(Iec.TaskSupervisor, &Iec.Places.complete_import/0)
             run_setup_step(&Iec.Parties.import_municipality_files/0)
             run_setup_step(&Iec.Parties.import_previous_ward_results/0)
             run_setup_step(&Iec.Parties.complete_municipality_files/0)
           end},
          id: :results_setup,
          restart: :temporary
        )

      pollers =
        Iec.Results.Feed.feeds()
        |> Enum.with_index()
        |> Enum.map(fn {feed, index} ->
          {Iec.Results.Poller, feed: feed, initial_delay: :timer.seconds(2) * (index + 1)}
        end)

      [setup | pollers]
    else
      []
    end
  end

  # One setup step; a failure is logged and the rest still run (it is retried on the next
  # start, as every step skips what is already stored).
  defp run_setup_step(step) do
    step.()
  catch
    kind, reason ->
      Logger.error(
        "Setup step #{inspect(step)} failed: " <> Exception.format(kind, reason, __STACKTRACE__)
      )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
