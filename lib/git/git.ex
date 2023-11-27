defmodule Git.Git do
  def clone(repo) do
    dest_dir = prep_workdir(repo)

    case ExGit.clone(repo, dest_dir) do
      {:error, :exists} -> {:ok, "already cloned"}
      o -> o
    end
  end

  def clone!(repo) do
    dest_dir = prep_workdir(repo)

    case ExGit.clone(repo, dest_dir) do
      {:error, e} -> raise "#{dest_dir}: #{e}"
      o -> o
    end
  end

  def checkout(repo, branch) do
    ExGit.checkout_branch(prep_workdir(repo), branch)
  end

  defp prep_workdir(repo) do
    working_dir = Application.get_env(:sower, :working_dir)
    repo_stub = repo |> URI.parse() |> Map.get(:path) |> Path.basename()

    File.mkdir_p!(working_dir)

    Path.join(working_dir, repo_stub)
  end
end
