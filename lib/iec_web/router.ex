defmodule IecWeb.Router do
  use IecWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IecWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", IecWeb do
    pipe_through :browser

    # Every table on every page can be sorted by its columns.
    live_session :results, on_mount: IecWeb.Sorting do
      live "/", NationalLive
      live "/provinces/:id", ProvinceLive
      live "/municipalities/:id", MunicipalityLive
      live "/wards", WardSearchLive
      live "/wards/:id", WardLive
      live "/changes", ChangesLive
      live "/movers", MoversLive
      live "/close-contests", ContestsLive
      live "/map", MapLive
      live "/trends", TrendsLive
      live "/about", AboutLive
      live "/status", StatusLive
      live "/parties/:id", PartyLive
    end
  end

  scope "/", IecWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", IecWeb do
  #   pipe_through :api
  # end
end
