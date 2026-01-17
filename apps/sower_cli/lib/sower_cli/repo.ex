defmodule SowerCli.Repo do
  alias SowerCli.Output

  def get_tags(%Nix.Eval.Request{path: path, type: type}) do
    get_tags(path, type)
  end

  def get_tags(path, type) when is_binary(path) do
    Output.step("Discovered repository tags")

    tags =
      if File.exists?(path) do
        {path, []}
        |> get_eval_type_tags(type)
        |> get_jj_tags()
        |> get_git_tags()
        |> then(fn {_, tags} -> tags end)
        |> Enum.map(fn {k, v} -> %SowerClient.SeedTag{key: k, value: v} end)
        |> Enum.uniq()
      else
        []
      end

    # output the found tags
    tags
    |> Enum.map(&SowerClient.SeedTag.to_query_string/1)
    |> Enum.sort()
    |> Enum.map(&SowerCli.Output.info/1)

    tags
  end

  def find_dir(path) do
    if File.exists?(path) do
      path
    else
      nil
    end
  end

  def get_eval_type_tags({dir, existing}, :flake) do
    new =
      with true <- File.exists?("#{dir}/flake.lock"),
           nix when not is_nil(nix) <- System.find_executable("nix"),
           {metadata, 0} <- System.cmd(nix, ["flake", "metadata", "--json"], cd: dir) do
        Jason.decode!(metadata)
        |> Map.fetch!("locked")
        |> Enum.reduce([], fn
          {"dirtyRev", rev}, acc ->
            Keyword.put(acc, :flake_git_rev, rev) |> Keyword.put(:flake_dirty, "true")

          {"rev", rev}, acc ->
            Keyword.put(acc, :flake_git_rev, rev)

          _, acc ->
            acc
        end)
      else
        _ -> []
      end

    {dir, existing ++ new}
  end

  def get_type_tags(dir, _), do: {dir, []}

  def get_jj_tags({dir, existing}) do
    new =
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

    {dir, existing ++ new}
  end

  def get_git_tags({dir, existing}) do
    new =
      case System.find_executable("git") do
        nil ->
          []

        git ->
          if is_git?(git, dir) do
            git_rev = git_rev(git, dir)

            if git_dirty?(git, dir) do
              [git_dirty: "true", git_rev: "#{git_rev}-dirty"]
            else
              [git_branch: git_branch(git, dir), git_rev: git_rev]
            end
            |> Enum.reject(fn {_, v} -> is_nil(v) end)
          else
            []
          end
      end

    {dir, existing ++ new}
  end

  defp git_rev(git, dir) do
    case System.cmd(git, ["rev-parse", "HEAD"], stderr_to_stdout: true, cd: dir) do
      {rev, 0} when rev != "HEAD" ->
        String.trim(rev)

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

  defp is_git?(git, dir) do
    case System.cmd(git, ["rev-parse", "--git-dir"], stderr_to_stdout: true, cd: dir) do
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
