defmodule SowerWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Sower.AccountsFixtures
      import Sower.OrchestrationFixtures
      import Sower.SeedFixtures
      import SowerWeb.ChannelCase

      @endpoint SowerWeb.Endpoint
    end
  end

  setup tags do
    Sower.DataCase.setup_sandbox(tags)

    on_exit(fn ->
      for pid <- Task.Supervisor.children(Sower.TaskSupervisor) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    :ok
  end

  def generate_keypair do
    JOSE.JWK.generate_key({:rsa, 2048})
    |> then(fn jwk ->
      {_, priv} = JOSE.JWK.to_pem(jwk)
      {_, pub} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
      {priv, pub}
    end)
  end

  def create_garden_with_oauth(attrs \\ %{}) do
    {private_pem, public_pem} = generate_keypair()

    garden =
      Sower.OrchestrationFixtures.garden_fixture(
        Map.merge(
          %{
            sid: SowerClient.Sid.generate("grdn")
          },
          attrs
        )
      )

    {:ok, client} = Sower.GardenAuth.create_client(garden.sid, public_pem)

    {:ok, garden} =
      Sower.Orchestration.Garden.update_garden(garden, %{oauth_client_id: client.id})

    assertion = build_client_assertion(client.id, private_pem)
    {:ok, %{access_token: boruta_token}} = Sower.GardenAuth.issue(assertion)

    %{garden: garden, boruta_token: boruta_token}
  end

  defp build_client_assertion(client_id, private_key_pem) do
    now = System.system_time(:second)

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => "sower",
      "iat" => now,
      "exp" => now + 60
    }

    jwk = JOSE.JWK.from_pem(private_key_pem)
    jws = %{"alg" => "RS512"}
    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, claims))
    token
  end

  defmacro connect_and_join_garden(attrs \\ Macro.escape(%{})) do
    quote do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      %{garden: garden, boruta_token: boruta_token} =
        SowerWeb.ChannelCase.create_garden_with_oauth(unquote(attrs))

      {:ok, socket} =
        connect(SowerWeb.GardenSocket, %{},
          connect_info: %{
            x_headers: [{"x-auth-token", "boruta:#{boruta_token}"}]
          }
        )

      {:ok, _reply, socket} =
        subscribe_and_join(
          socket,
          SowerWeb.GardenChannel,
          "garden:#{garden.sid}",
          %{}
        )

      %{socket: socket, garden: garden, user: user}
    end
  end
end
