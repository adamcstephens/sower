defmodule SowerWeb.Router do
  use SowerWeb, :router

  import SowerWeb.UserAuth
  use Plug.ErrorHandler

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SowerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: SowerWeb.ApiSpec
  end

  scope "/", SowerWeb do
    pipe_through :browser

    get "/", PageController, :home

    get "/client/script", AppController, :client_script
  end

  scope "/", SowerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated, on_mount: [{SowerWeb.UserAuth, :ensure_authenticated}] do
      live "/clients", ClientLive.Index, :index
      live "/clients/new", ClientLive.Index, :new
      live "/clients/:id/edit", ClientLive.Index, :edit
      live "/clients/:id", ClientLive.Show, :show
      live "/clients/:id/show/edit", ClientLive.Show, :edit
      live "/seeds", SeedLive.Index, :index
      live "/seeds/:id", SeedLive.Show, :show
      live "/inputs/repos", RepositoryLive.Index, :index
      live "/inputs/repos/:id", RepositoryLive.Show, :show
    end
  end

  scope "/" do
    pipe_through [:browser, :require_authenticated_user]
    get "/docs/swagger-ui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  scope "/api" do
    pipe_through :api
    get "/config", SowerWeb.AppController, :config

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []

    get "/seeds", SowerWeb.SeedController, :list
    get "/seeds/:id", SowerWeb.SeedController, :get
    get "/seeds/:id/paths/latest", SowerWeb.SeedController, :latest
    post "/seeds", SowerWeb.SeedController, :new
    post "/seeds/:id/paths", SowerWeb.SeedController, :new_store_path
  end

  scope "/auth" do
    pipe_through :browser
    get "/:provider", SowerWeb.AuthController, :request
    get "/:provider/callback", SowerWeb.AuthController, :callback
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

  ## Authentication routes
  scope "/", SowerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{SowerWeb.UserAuth, :ensure_authenticated}] do
      live "/users/settings", UserSettingsLive, :edit
    end
  end
end
