defmodule Mix.Tasks.Compile.RexecNative do
  @moduledoc "Compiles the rexec_native Rust binary."

  use Mix.Task.Compiler

  @native_dir "native/rexec_native"

  @impl true
  def run(_args) do
    native_dir = Path.join(File.cwd!(), @native_dir)
    priv_dir = Path.join(File.cwd!(), "priv")
    File.mkdir_p!(priv_dir)

    target = Path.join(priv_dir, "rexec_native")
    manifest = Path.join(native_dir, "target/release/rexec_native")

    if needs_build?(target, native_dir) do
      Mix.shell().info("Compiling rexec_native...")

      case System.cmd("cargo", ["build", "--release"],
             cd: native_dir,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          File.cp!(manifest, target)
          File.chmod!(target, 0o755)
          {:ok, []}

        {output, code} ->
          {:error, [{:error, "cargo build failed (exit #{code}):\n#{output}"}]}
      end
    else
      {:noop, []}
    end
  end

  defp needs_build?(target, native_dir) do
    if File.exists?(target) do
      target_mtime = File.stat!(target).mtime

      Path.wildcard(Path.join(native_dir, "src/**/*.rs"))
      |> Enum.concat([Path.join(native_dir, "Cargo.toml")])
      |> Enum.any?(fn src ->
        File.stat!(src).mtime > target_mtime
      end)
    else
      true
    end
  end
end
