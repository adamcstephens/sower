defmodule SowerCli.Repo do
  def get_tags(%Nix.Eval.Request{type: type} = request) do
    case find_dir(request) do
      nil ->
        []

      dir ->
        (get_tags(:git, dir) ++ get_tags(:jj, dir) ++ get_tags(type, dir))
        |> Enum.map(fn {k, v} -> %SowerClient.SeedTag{key: k, value: v} end)
        |> Enum.uniq()
    end
  end

  def find_dir(%Nix.Eval.Request{path: path}) do
    if File.exists?(path) do
      path
    else
      nil
    end
  end

  def get_tags(:flake, dir) do
    with true <- File.exists?("#{dir}/flake.lock"),
         nix when not is_nil(nix) <- System.find_executable("nix"),
         {metadata, 0} <- System.cmd(nix, ["flake", "metadata", "--json"], cd: dir) do
      Jason.decode!(metadata)
      |> Map.fetch!("locked")
      |> Enum.reduce([], fn
        {"dirtyRev", rev}, acc ->
          Keyword.put(acc, :git_rev, rev) |> Keyword.put(:dirty, "true")

        {"rev", rev}, acc ->
          Keyword.put(acc, :git_rev, rev)

        _, acc ->
          acc
      end)
    else
      _ -> []
    end
  end

  def get_tags(:jj, dir) do
    case System.find_executable("jj") do
      nil ->
        []

      jj ->
        if is_jj?(jj, dir) do
          {change_id, 0} =
            System.cmd(
              jj,
              [
                "log",
                "-r",
                "ancestors(@) & ~empty()",
                "-n",
                "1",
                "--no-graph",
                "-T",
                "change_id"
              ],
              cd: dir
            )

          bookmarks =
            case System.cmd(
                   jj,
                   [
                     "log",
                     "-r",
                     "latest(ancestors(@) & ~empty()) & bookmarks()",
                     "--no-graph",
                     "-T",
                     ~s<"{ \\"local_bookmarks\\": [" ++ local_bookmarks.map(|b| "\\"" ++ b.name() ++ "\\"").join(", ") ++ "], \\"remote_bookmarks\\": [" ++ remote_bookmarks.map(|b| "\\"" ++ b.name() ++ "@" ++ b.remote() ++ "\\"").join(", ") ++ "]}">
                   ],
                   cd: dir
                 ) do
              {bookmarks, 0} when bookmarks != "" -> Jason.decode!(bookmarks)
              _ -> %{}
            end

          local_bookmarks =
            bookmarks
            |> Map.get("local_bookmarks", [])
            |> Enum.map(fn book -> {:jj_local_bookmark, book} end)

          remote_bookmarks =
            bookmarks
            |> Map.get("remote_bookmarks", [])
            |> Enum.reject(&String.ends_with?(&1, "@git"))
            |> Enum.map(fn book -> {:jj_bookmark, book} end)

          [jj_change_id: String.trim(change_id)] ++ local_bookmarks ++ remote_bookmarks
        else
          []
        end
    end
  end

  def get_tags(:git, dir) do
    case System.find_executable("git") do
      nil ->
        []

      git ->
        with {_, 0} <-
               System.cmd(git, ["rev-parse", "--git-dir"], stderr_to_stdout: true, cd: dir) do
          ([git_rev: git_rev(git, dir)] ++
             if(git_dirty?(git, dir),
               do: [{:dirty, "true"}],
               else: [git_branch: git_branch(git, dir)]
             ))
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
        else
          _ -> []
        end
    end
  end

  defp git_rev(git, dir) do
    case System.cmd(git, ["rev-parse", "HEAD"], stderr_to_stdout: true, cd: dir) do
      {rev, 0} when rev != "HEAD" ->
        rev = String.trim(rev)

        if git_dirty?(git, dir), do: rev <> "-dirty", else: rev

      _ ->
        nil
    end
  end

  defp git_branch(git, dir) do
    case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true, cd: dir) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  end

  defp git_dirty?(git, dir) do
    case System.cmd(git, ["status", "--porcelain"], stderr_to_stdout: true, cd: dir) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> false
    end
  end

  def is_jj?(jj, dir) do
    case System.cmd(jj, ["root"], stderr_to_stdout: true, cd: dir) do
      {_root, 0} ->
        true

      _ ->
        false
    end
  end
end
