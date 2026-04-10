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

  defmacro connect_and_join_garden(attrs \\ Macro.escape(%{})) do
    quote do
      user = user_fixture()
      Sower.Repo.put_org_id(user.org_id)

      {:ok, access_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "test",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "garden:register"}]
        })

      garden =
        garden_fixture(
          Map.merge(
            %{
              sid: SowerClient.Sid.generate("grdn"),
              local_sid: SowerClient.Sid.generate("lc_grdn")
            },
            unquote(attrs)
          )
        )

      encoded_token = Base.encode64(access_token.token)

      {:ok, socket} = connect(SowerWeb.GardenSocket, %{"token" => encoded_token})

      {:ok, _reply, socket} =
        subscribe_and_join(
          socket,
          SowerWeb.GardenChannel,
          "garden:#{garden.sid}",
          %{"local_sid" => garden.local_sid}
        )

      %{socket: socket, garden: garden, user: user, access_token: access_token}
    end
  end
end
