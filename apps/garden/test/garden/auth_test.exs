defmodule Garden.AuthTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Garden.Auth

  @client_id "grdn_client_abc"

  setup do
    original = Application.get_env(:garden, :config)
    Application.put_env(:garden, :config, %SowerClient.Config{endpoint: "https://sower.test"})

    on_exit(fn ->
      if original do
        Application.put_env(:garden, :config, original)
      else
        Application.delete_env(:garden, :config)
      end
    end)

    {:ok, private_key_pem: elem(Auth.generate_keypair(), 0)}
  end

  describe "request_token/3" do
    test "returns token on 200 response", %{private_key_pem: pem} do
      post_fun = fn _url, _opts ->
        {:ok,
         %{
           status: 200,
           body: %{
             "access_token" => "abc123",
             "expires_in" => 3600,
             "token_type" => "bearer"
           }
         }}
      end

      assert {:ok, %{access_token: "abc123", expires_in: 3600, token_type: "bearer"}} =
               Auth.request_token(@client_id, pem, post_fun)
    end

    test "classifies 401 as server rejection", %{private_key_pem: pem} do
      post_fun = fn _url, _opts ->
        {:ok, %{status: 401, body: %{"error" => "invalid_client"}}}
      end

      logs =
        capture_log(fn ->
          assert {:error, {:server_rejected, 401}} =
                   Auth.request_token(@client_id, pem, post_fun)
        end)

      assert logs =~ "rejected by server"
    end

    test "classifies 400 invalid_client as server rejection", %{private_key_pem: pem} do
      post_fun = fn _url, _opts ->
        {:ok, %{status: 400, body: %{"error" => "invalid_client"}}}
      end

      capture_log(fn ->
        assert {:error, {:server_rejected, 400}} =
                 Auth.request_token(@client_id, pem, post_fun)
      end)
    end

    test "classifies 5xx as server error", %{private_key_pem: pem} do
      post_fun = fn _url, _opts ->
        {:ok, %{status: 503, body: "service unavailable"}}
      end

      capture_log(fn ->
        assert {:error, {:server_error, 503}} = Auth.request_token(@client_id, pem, post_fun)
      end)
    end

    test "classifies transport errors separately from server responses", %{private_key_pem: pem} do
      post_fun = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :closed}}
      end

      logs =
        capture_log(fn ->
          assert {:error, {:transport_error, :closed}} =
                   Auth.request_token(@client_id, pem, post_fun)
        end)

      assert logs =~ "transport error"
    end

    test "wraps unexpected errors as request errors", %{private_key_pem: pem} do
      post_fun = fn _url, _opts -> {:error, :boom} end

      capture_log(fn ->
        assert {:error, {:request_error, :boom}} = Auth.request_token(@client_id, pem, post_fun)
      end)
    end
  end
end
