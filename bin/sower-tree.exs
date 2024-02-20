#!/usr/bin/env -S ERL_FLAGS=+B elixir

Mix.install([{:req, "~> 0.4.0"}])

defmodule Sower.Tree do
  def main() do
    {:ok, hostname} = :inet.gethostname()

    options =
      System.argv()
      |> OptionParser.parse(
        strict: [
          name: :string,
          sower_url: :string,
          type: :string
        ]
      )
      |> IO.inspect()

    {[sower_url: sower_url], _, _} = options

    resp =
      Req.get!("#{sower_url}/api/seeds/latest?name=#{hostname}&type=nixos")
      |> IO.inspect()

    if resp.body["out_path"] == nil do
      IO.inspect(resp)
      IO.puts("!! No out_path found")
      Kernel.exit(1)
    end

    out_path = resp.body["out_path"]

    # need to error handle
    System.cmd("nix-store", ["--realize", out_path])

    System.cmd("sudo", [
      "--askpass",
      "nix-env",
      "--set",
      "--profile",
      "/nix/var/nix/profiles/system",
      out_path
    ])

    # if selecting boot, no need to check reboot_needed
    System.cmd("sudo", ["--askpass", "#{out_path}/bin/switch-to-configuration", "switch"])

    if reboot_needed?() do
      IO.puts("Reboot is needed")
    end
  end

  def reboot_needed?() do
    ["initrd", "kernel", "kernel-modules"]
    |> Enum.any?(fn f ->
      File.exists?("/run/booted-system/#{f}") &&
        File.read_link!("/run/booted-system/#{f}") !=
          File.read_link!("/nix/var/nix/profiles/system/#{f}")
    end)
  end
end

Sower.Tree.main()
