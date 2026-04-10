defmodule SowerWeb.Router do
  use SowerWeb, :router

  import Phoenix.LiveDashboard.Router
  import SowerWeb.UserAuth
  import SowerWeb.TokenAuth
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

  pipeline :forge_webhook do
    plug :accepts, ["json"]
    plug SowerWeb.Plugs.Webhook
  end

  scope "/", SowerWeb do
    pipe_through :browser

    get "/", PageController, :home

    scope "/client" do
      get "/bootstrap", BootstrapController, :client_script
      get "/bin/:system", BootstrapController, :client_bin
    end
  end

  scope "/", SowerWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated, on_mount: [{SowerWeb.UserAuth, :ensure_authenticated}] do
      live "/gardens", GardenLive.Index, :index
      live "/gardens/new", GardenLive.Index, :new
      live "/gardens/:sid/edit", GardenLive.Index, :edit
      live "/gardens/:sid", GardenLive.Show, :show
      live "/gardens/:sid/show/edit", GardenLive.Show, :edit

      live "/gardens/:garden_sid/subscriptions", SubscriptionLive.Index, :index
      live "/gardens/:garden_sid/subscriptions/new", SubscriptionLive.Index, :new
      live "/gardens/:garden_sid/subscriptions/:sid/edit", SubscriptionLive.Index, :edit
      live "/gardens/:garden_sid/subscriptions/:sid", SubscriptionLive.Show, :show
      live "/gardens/:garden_sid/subscriptions/:sid/show/edit", SubscriptionLive.Show, :edit

      live "/deployments", DeploymentLive.Index, :index
      live "/deployments/:sid", DeploymentLive.Show, :show

      get "/forges/:sid/login", Forge.OauthController, :login
      get "/forges/oauth/callback", Forge.OauthController, :callback

      live "/forges", Forge.ConnectionLive.Index, :index
      live "/forges/new", Forge.ConnectionLive.Index, :new
      live "/forges/:sid", Forge.ConnectionLive.Show, :show
      live "/forges/:sid/edit", Forge.ConnectionLive.Index, :edit
      live "/forges/:sid/show/edit", Forge.ConnectionLive.Show, :edit

      live "/seeds", SeedLive.Index, :index
      live "/seeds/:sid", SeedLive.Show, :show

      live "/nix/caches", Nix.CacheLive.Index, :index
      live "/nix/caches/new", Nix.CacheLive.Index, :new
      live "/nix/caches/:sid/edit", Nix.CacheLive.Index, :edit
      live "/nix/caches/:sid", Nix.CacheLive.Show, :show
      live "/nix/caches/:sid/show/edit", Nix.CacheLive.Show, :edit

      live "/settings", Settings.IndexLive, :index
      live "/settings/access-tokens", Settings.AccessTokenLive.Index, :index
      live "/settings/access-tokens/new", Settings.AccessTokenLive.Index, :new
      live "/settings/access-tokens/:sid/edit", Settings.AccessTokenLive.Index, :edit
      live "/settings/access-tokens/:sid", Settings.AccessTokenLive.Show, :show
      live "/settings/access-tokens/:sid/show/edit", Settings.AccessTokenLive.Show, :edit
    end
  end

  scope "/" do
    pipe_through [:browser, :require_authenticated_user]
    get "/docs/swagger-ui", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"

    scope "/dev" do
      live_dashboard "/dashboard", metrics: SowerWeb.Telemetry
    end
  end

  scope "/forges", SowerWeb.Forge do
    pipe_through [:forge_webhook]
    post "/:forge_sid/repos/:repo_sid/webhook", WebhookController, :post
  end

  scope "/api" do
    pipe_through :api
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api/oauth", SowerWeb.OAuth do
    pipe_through :api
    post "/token", TokenController, :create
  end

  scope "/api/v1", SowerWeb.Api do
    pipe_through [:api, :ensure_token_authenticated]

    get "/auth/verify", AuthController, :verify

    post "/gardens/register", GardenController, :register

    get "/nix/caches", Nix.CacheController, :list
    get "/seeds", SeedController, :list
    get "/seeds/latest", SeedController, :latest
    get "/seeds/:sid", SeedController, :get
    post "/seeds", SeedController, :create
  end

  if Mix.env() in [:dev, :test] do
    scope "/dev", SowerWeb do
      pipe_through :browser
      get "/login", DevLoginController, :login
    end
  end

  scope "/auth" do
    pipe_through :browser
    get "/:provider", SowerWeb.AuthController, :request
    get "/:provider/callback", SowerWeb.AuthController, :callback
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
    end
  end
end
