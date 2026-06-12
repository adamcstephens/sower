defmodule SowerCli.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SowerCli.Output

  describe "push_summary/2" do
    test "success prints a single line" do
      output =
        capture_io(fn ->
          Output.push_summary("niks3://", {:ok, %{uploaded: ["/nix/store/abc-foo"], failed: []}})
        end)

      assert output =~ "Pushed 1 path(s) to niks3://"
    end

    test "upload error prints exit code and full output verbatim" do
      error = %Nix.Cache.UploadError{
        backend: "niks3",
        exit_code: 1,
        output: """
        time=2026-06-11 level=INFO msg="Uploading 39 paths"
        time=2026-06-11 level=INFO msg="Uploading abc-foo (4.3MB)"
        time=2026-06-11 level=ERROR msg="upload failed: 401 Unauthorized"
        """
      }

      output =
        capture_io(fn ->
          Output.push_summary("niks3://", {:error, error})
        end)

      assert output =~ "Push to niks3:// failed (exit 1)"
      assert output =~ ~s(level=INFO msg="Uploading 39 paths")
      assert output =~ ~s(level=ERROR msg="upload failed: 401 Unauthorized")
    end

    test "binary error reason prints as-is" do
      output =
        capture_io(fn ->
          Output.push_summary("niks3://", {:error, "niks3 command not found in PATH"})
        end)

      assert output =~ "Push to niks3:// failed: niks3 command not found in PATH"
    end
  end
end
