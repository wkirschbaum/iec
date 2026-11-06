# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :iec,
  ecto_repos: [Iec.Repo],
  generators: [timestamp_type: :utc_datetime]

# Results feed of the Local Government Elections, as read by the IEC's public
# results dashboard (results.elections.org.za/dashboards/lge). The event ids come from
# `var EEID2026` and friends on LGEResultsDashboard.aspx.
config :iec, Iec.Results,
  base_url: "https://results.elections.org.za/dashboards/lge/MapsJason",
  # Boundaries (GeoJSON) behind the IEC's election map.
  map_url: "https://results.elections.org.za/ElectionMap/MapData",
  # Polled while counting runs.
  live_election: %{year: 2026, electoral_event: "EEID1887"},
  # Imported once (its files are final) to compare against. `var EEID2021` on the same page.
  previous_election: %{year: 2021, electoral_event: "EEID1091"},
  # Earlier elections, imported once for the trends (event ids from the same page).
  history_elections: [
    %{year: 2000, electoral_event: "EEID2"},
    %{year: 2006, electoral_event: "EEID95"},
    %{year: 2011, electoral_event: "EEID197"},
    %{year: 2016, electoral_event: "EEID402"}
  ],
  province_ids: Enum.to_list(1..9),
  poll: true

# Configure the endpoint
config :iec, IecWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IecWeb.ErrorHTML, json: IecWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Iec.PubSub,
  live_view: [signing_salt: "EIvC1erQ"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  iec: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  iec: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
