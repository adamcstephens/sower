defmodule SowerWeb.Router do
  use SowerWeb, :router
  use Plug.ErrorHandler

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SowerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SowerWeb do
    pipe_through :browser

    get "/", PageController, :home

    get "/client/script", AppController, :client_script

    # TODO add back auth routes and route protection
    # sign_in_route(register_path: "/register")
    # sign_out_route AuthController
    # auth_routes_for Sower.Accounts.User, to: AuthController

    # ash_authentication_live_session :authentication_required,
    #   on_mount: {SowerWeb.LiveUserAuth, :live_user_required} do
    live "/clients", ClientLive.Index, :index
    live "/clients/new", ClientLive.Index, :new
    live "/clients/:id/edit", ClientLive.Index, :edit
    live "/clients/:id", ClientLive.Show, :show
    live "/clients/:id/show/edit", ClientLive.Show, :edit
    live "/seeds", SeedLive.Index, :index
    live "/seeds/:id", SeedLive.Show, :show
    live "/inputs/repos", RepositoryLive.Index, :index
    live "/inputs/repos/:id", RepositoryLive.Show, :show
    # end

    # ash_authentication_live_session :authentication_optional,
    #   on_mount: {SowerWeb.LiveUserAuth, :live_user_optional} do
    # end
  end

  scope "/api" do
    pipe_through :api
    get "/config", SowerWeb.AppController, :config

    get "/seeds", SowerWeb.SeedController, :list
    get "/seeds/latest", SowerWeb.SeedController, :find_latest
    post "/seeds", SowerWeb.SeedController, :new
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sower, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SowerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # and implement the callback handle_errors/2
  # defp handle_errors(conn, _) do
  #   conn |> json(%{error: "unknown"}) |> halt()
  # end
end
