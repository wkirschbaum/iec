import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :iec, Iec.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "iec_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :iec, IecWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "P07t5PGCJJfBDBVVUQS0nE9/8jiGwgJDON9d0DDTpshQt/XRTbDY+rjpxTz43Y05",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# No polling in tests, and every IEC request goes to a Req.Test stub.
config :iec, Iec.Results,
  poll: false,
  req_options: [plug: {Req.Test, Iec.Results.Feed}, retry: false]

config :iec, IecWeb.LiveUpdates, refresh_delay: 0
