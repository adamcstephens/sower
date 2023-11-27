defmodule Git.Git do
  use Task

  require Logger

  def start_link(arg) do
    Task.start_link(__MODULE__, :startup, [arg])
  end

  def clone(repo) do
    dest_dir = working_dir(repo)

    case ExGit.clone(repo, dest_dir) do
      {:error, :exists} -> {:ok, "already cloned"}
      o -> o
    end
  end

  def clone!(repo) do
    dest_dir = working_dir(repo)

    case ExGit.clone(repo, dest_dir) do
      {:error, e} -> raise "#{dest_dir}: #{e}"
      o -> o
    end
  end

  def checkout(repo, branch) do
    repo = :git.open(working_dir(repo))
    :git.checkout(repo, branch)
  end

  def startup(_) do
    working_dir = Application.fetch_env!(:sower, :working_dir)
    Logger.info("Initializing git working dir: #{working_dir}")
    File.mkdir_p(working_dir)
  end

  def working_dir(repo) do
    working_dir = Application.get_env(:sower, :working_dir)
    repo_stub = repo |> URI.parse() |> Map.get(:path) |> Path.basename()

    Path.join(working_dir, repo_stub)
  end
end
