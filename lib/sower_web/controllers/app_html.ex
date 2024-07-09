defmodule SowerWeb.AppHTML do
  use SowerWeb, :html

  embed_templates("app_html/*")

  attr :arch, :string, required: true
  attr :path, :string, required: true

  def case_arch(assigns) do
    ~H"""
    <%= @arch %>)
    nix-store --realize <%= @path %> $cache_args #
    exec <%= @path %>/bin/sower "$@"
    ;;
    """
  end

  attr :nix_caches, :list, required: true

  def cache_args(assigns) do
    substituters =
      if assigns.nix_caches |> length > 0 do
        "--extra-substituters " <>
          (assigns.nix_caches |> Enum.map_join(",", &(&1 |> Keyword.get(:url))))
      else
        ""
      end

    keys =
      if assigns.nix_caches |> length > 0 do
        "--extra-trusted-public-keys " <>
          (assigns.nix_caches |> Enum.map_join(",", &(&1 |> Keyword.get(:public_key))))
      else
        ""
      end

    ~H"<%= substituters %> <%= keys %>"
  end
end
