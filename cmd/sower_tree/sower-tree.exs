#!/usr/bin/env -S ERL_FLAGS=+B elixir

defmodule Sower.Tree do
  def main() do
    options =
      System.argv()
      |> OptionParser.parse(
        strict: [
          sower_url: :string,
          name: :string,
          type: :string
        ]
      )
      |> IO.inspect()

    {[{:sower_url, sower_url}, {:type, type}, {:name, name} | _rest], _, _} = options

    seed_url = "#{sower_url}/api/seeds/latest?name=#{name}&type=#{type}"

    {:ok, resp} = Req.get(seed_url)

    IO.puts(":: fetched #{seed_url}")

    if resp.body["out_path"] == nil do
      IO.inspect(resp)
      IO.puts("!! No out_path found")
      Kernel.exit(1)
    end

    resp.body["out_path"]
    |> IO.inspect()
    |> realize()
    |> activate(type)

    if reboot_needed?() do
      IO.puts("Reboot is needed")
    end
  end

  defp activate(out_path, "home-manager") do
    System.cmd("#{out_path}/activate")
  end

  defp activate(out_path, "nixos") do
    set_profile(out_path, "/nix/var/nix/profiles/system")
    System.cmd("sudo", ["--askpass", "#{out_path}/bin/switch-to-configuration", "switch"])
  end

  defp realize(out_path) do
    # need to error handle
    System.cmd("nix-store", ["--realize", out_path])
  end

  defp reboot_needed?() do
    ["initrd", "kernel", "kernel-modules"]
    |> Enum.any?(fn f ->
      File.exists?("/run/booted-system/#{f}") &&
        File.read_link!("/run/booted-system/#{f}") !=
          File.read_link!("/nix/var/nix/profiles/system/#{f}")
    end)
  end

  defp set_profile(out_path, profile) do
    System.cmd("sudo", [
      "--askpass",
      "nix-env",
      "--set",
      "--profile",
      profile,
      out_path
    ])
  end
end

Sower.Tree.main()
