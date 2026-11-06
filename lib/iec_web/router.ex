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

    live "/", NationalLive
    live "/provinces/:id", ProvinceLive
    live "/municipalities/:id", MunicipalityLive
    live "/changes", ChangesLive
    live "/movers", MoversLive
    live "/map", MapLive
    live "/parties/:id", PartyLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", IecWeb do
  #   pipe_through :api
  # end
end
