defmodule SowerWeb.UserAuthLoginPathTest do
  use SowerWeb.ConnCase, async: false

  alias SowerWeb.UserAuth

  setup do
    previous = Application.get_env(:ueberauth, Ueberauth)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ueberauth, Ueberauth)
        value -> Application.put_env(:ueberauth, Ueberauth, value)
      end
    end)

    :ok
  end

  test "points at the dev login when no OIDC provider is configured" do
    Application.delete_env(:ueberauth, Ueberauth)

    assert UserAuth.login_path() == ~p"/dev/login"
  end

  test "points at the OIDC provider when one is configured" do
    Application.put_env(:ueberauth, Ueberauth, providers: [oidcc: {Ueberauth.Strategy.Oidcc, []}])

    assert UserAuth.login_path() == ~p"/auth/oidcc"
  end
end
