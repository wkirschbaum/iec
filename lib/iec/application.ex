defmodule Iec.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        IecWeb.Telemetry,
        Iec.Repo,
        {DNSCluster, query: Application.get_env(:iec, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Iec.PubSub},
        {Registry, keys: :unique, name: Iec.Results.Registry},
        {Task.Supervisor, name: Iec.TaskSupervisor},
        {DynamicSupervisor, name: Iec.Parties.Pollers, strategy: :one_for_one}
      ] ++
        pollers() ++
        [IecWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Iec.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # One poller per feed file, started a couple of seconds apart so the first round of
  # requests does not hit the IEC all at once.
  # Before that, a one-off task refreshes the party list, imports the previous election
  # if it is not stored yet, starts the party pollers and fills the ward directory.
  defp pollers do
    if Application.fetch_env!(:iec, Iec.Results)[:poll] do
      setup =
        Supervisor.child_spec(
          {Task,
           fn ->
             Iec.Results.refresh_parties()
             Iec.Results.import_previous_election()
             Iec.Parties.track_national_parties()
             Iec.Maps.import_boundaries()
             Iec.Parties.complete_ward_directory()
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IecWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
