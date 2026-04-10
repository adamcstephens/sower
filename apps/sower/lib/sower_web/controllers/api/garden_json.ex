defmodule SowerWeb.Api.GardenJSON do
  def register(%{garden: garden, client_id: client_id}) do
    %{
      sid: garden.sid,
      oauth_credentials: %{
        client_id: client_id
      }
    }
  end

  def error(%{error: error}) do
    %{error: error}
  end
end
