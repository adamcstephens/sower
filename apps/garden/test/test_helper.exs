ExUnit.start()

ExUnit.after_suite(fn _results ->
  state_dir = Garden.Config.get().state_directory

  if String.starts_with?(state_dir, System.tmp_dir!()) do
    File.rm_rf!(state_dir)
  end
end)
