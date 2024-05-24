defmodule SowerWeb.ClientSocket do
  require Logger
  use Phoenix.Socket

  channel("client:*", SowerWeb.ClientChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    signer = Joken.Signer.create("HS256", Application.fetch_env!(:sower, :bootstrap_token))

    case Joken.Signer.verify(token, signer) do
      {:ok, claims} ->
        case get_tree(claims) do
          {:ok, tree} -> {:ok, socket |> assign(:tree_id, tree.id)}
          {:error, e} -> Logger.error(~s"failed to find tree: #{e}")
        end

      _ ->
        {:error, "unauthorized"}
    end
  end

  @impl true
  def id(_socket), do: nil

  # TODO: use id provided by claims
  defp get_tree(%{"name" => name, "seed_type" => seed_type}) do
    case res = Sower.Tree.find(name, seed_type) |> dbg() do
      {:error, %Ash.Error.Query.NotFound{}} -> Sower.Tree.register(name, seed_type)
      _ -> res
    end
  end
end
