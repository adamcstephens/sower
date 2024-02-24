defmodule SowerTree.CLI do
  def main(argv) do
    options =
      argv
      |> OptionParser.parse(
        strict: [
          sower_url: :string,
          name: :string,
          type: :string,
          reboot: :boolean,
          mode: :string
        ]
      )
      |> IO.inspect()

    {options, _, _} = options

    sower_url = Keyword.get(options, :sower_url)
    type = Keyword.get(options, :type, "nixos")
    name = Keyword.get(options, :name, default_name(type))
    reboot = Keyword.get(options, :reboot, false)
    mode = Keyword.get(options, :mode, "switch")

    seed_url = "#{sower_url}/api/seeds/latest?name=#{name}&type=#{type}"

    {:ok, resp} = Req.get(seed_url)

    IO.puts(":: fetched #{seed_url}")

    if resp.body["out_path"] == nil do
      IO.puts("!! No out_path found")
      Kernel.exit(1)
    end

    resp.body["out_path"]
    |> realize()
    |> activate(type, mode)

    if type == "nixos" && reboot_needed?() do
      IO.puts("Reboot is needed")

      if reboot || mode == "boot" do
        System.cmd("sudo", ["--askpass", "systemctl", "reboot"])
      end
    end
  end

  defp activate(out_path, "home-manager", _mode) do
    {_, 0} = System.cmd("#{out_path}/activate", [])
    out_path
  end

  defp activate(out_path, "nixos", mode) do
    set_profile(out_path, "/nix/var/nix/profiles/system")

    # handle failure better
    System.cmd("sudo", ["--askpass", "#{out_path}/bin/switch-to-configuration", mode])

    out_path
  end

  defp default_name("home-manager") do
    System.fetch_env!("USER")
  end

  defp default_name("nixos") do
    {:ok, hostname} = :inet.gethostname()
    hostname
  end

  defp realize(out_path) do
    IO.puts(":: found #{out_path}")
    # ignore errors as activating services sometimes fails
    {_, _} = System.cmd("nix-store", ["--realize", out_path])
    out_path
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
    {_, 0} =
      System.cmd("sudo", [
        "--askpass",
        "nix-env",
        "--set",
        "--profile",
        profile,
        out_path
      ])

    out_path
  end
end
