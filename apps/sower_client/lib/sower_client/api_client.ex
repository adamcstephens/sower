defmodule SowerClient.ApiClient do
  @moduledoc """
  Builds authenticated Sower API requests with destination-aware environment proxy routing.
  """

  @type t :: Req.Request.t()

  def new() do
    Req.new(
      base_url: Application.fetch_env!(__MODULE__, :uri),
      auth: {:bearer, Application.fetch_env!(__MODULE__, :token)},
      # default is to retry, but let's be selective with that
      retry: false
    )
    |> SowerClient.Proxy.attach()
  end
end
