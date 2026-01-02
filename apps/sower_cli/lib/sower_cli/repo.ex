defmodule SowerCli.Repo do
  def get_tags() do
    (get_tags(:git) ++ get_tags(:jj) ++ get_tags(:flake))
    |> Enum.map(fn {k, v} -> %SowerClient.SeedTag{key: k, value: v} end)
    |> Enum.uniq()
  end

  def get_tags(:flake) do
    with true <- File.exists?("flake.lock"),
         nix when not is_nil(nix) <- System.find_executable("nix"),
         {metadata, 0} <- System.cmd(nix, ["flake", "metadata", "--json"]) do
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

  def get_tags(:jj) do
    case System.find_executable("jj") do
      nil ->
        []

      jj ->
        if is_jj?(jj) do
          {change_id, 0} =
            System.cmd(jj, [
              "log",
              "-r",
              "ancestors(@) & ~empty()",
              "-n",
              "1",
              "--no-graph",
              "-T",
              "change_id"
            ])

          bookmarks =
            case System.cmd(jj, [
                   "log",
                   "-r",
                   "latest(ancestors(@) & ~empty()) & bookmarks()",
                   "--no-graph",
                   "-T",
                   ~s<"{ \\"local_bookmarks\\": [" ++ local_bookmarks.map(|b| "\\"" ++ b.name() ++ "\\"").join(", ") ++ "], \\"remote_bookmarks\\": [" ++ remote_bookmarks.map(|b| "\\"" ++ b.name() ++ "@" ++ b.remote() ++ "\\"").join(", ") ++ "]}">
                 ]) do
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

  def get_tags(:git) do
    case System.find_executable("git") do
      nil ->
        []

      git ->
        with {_, 0} <- System.cmd(git, ["rev-parse", "--git-dir"], stderr_to_stdout: true) do
          ([git_rev: git_rev(git)] ++
             if(git_dirty?(git),
               do: [{:dirty, "true"}],
               else: [git_branch: git_branch(git)]
             ))
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
        else
          _ -> []
        end
    end
  end

  defp git_rev(git) do
    case System.cmd(git, ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {rev, 0} when rev != "HEAD" ->
        rev = String.trim(rev)

        if git_dirty?(git), do: rev <> "-dirty", else: rev

      _ ->
        nil
    end
  end

  defp git_branch(git) do
    case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> nil
    end
  end

  defp git_dirty?(git) do
    case System.cmd(git, ["status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> false
      {_, 0} -> true
      _ -> false
    end
  end

  def is_jj?(jj) do
    case System.cmd(jj, ["root"], stderr_to_stdout: true) do
      {_root, 0} ->
        true

      _ ->
        false
    end
  end
end
