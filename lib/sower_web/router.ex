defmodule SowerWeb.Router do
  use SowerWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SowerWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :scm do
    plug(Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      body_reader: {SowerWeb.Plugs.ScmWebhookVerify, :read_and_store_body, []}
    )

    plug(SowerWeb.Plugs.ScmWebhookVerify)
  end

  scope "/", SowerWeb do
    pipe_through(:browser)

    get("/", PageController, :home)

    live("/hooks", HookLive.Index, :index)
    live("/hooks/new", HookLive.Index, :new)
    live("/hooks/:id/edit", HookLive.Index, :edit)
    live("/hooks/:id", HookLive.Show, :show)

    get("/auth/callback", AuthController, :callback)
  end

  scope "/scm" do
    pipe_through([:scm, :api])
    post("/", SowerWeb.WebhookController, :handler)
  end

  # Other scopes may use custom stacks.
  # scope "/api", SowerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:sower, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      live_dashboard("/dashboard", metrics: SowerWeb.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
