defmodule Nix.Profile do
  @moduledoc "Reads native Nix profile generations and sets a profile to a store artifact."
  @doc "Path to the currently running version of the profile"
  @callback current_path() :: String.t()

  @doc "Calculate path to the profile"
  @callback profile_path() :: String.t()

  @doc "set tags"
  @callback tags() :: map()

  defmacro __using__(_opts) do
    caller = __CALLER__.module

    quote do
      use TypedStruct

      @derive Jason.Encoder

      typedstruct do
        field :current, Nix.Profile.Generation, enforce: true
        field :latest, Nix.Profile.Generation
        field :profiles, list(Nix.Profile.Generation), default: []
        field :tags, map(), default: %{}
      end

      @behaviour Nix.Profile
      import Nix.Profile

      @impl Nix.Profile
      def current_path() do
        profile_path()
      end

      @impl Nix.Profile
      def tags() do
        %{}
      end

      def get_state() do
        case profile() do
          {:ok, latest_generation} ->
            %unquote(caller){
              current: profile!(current_path()),
              latest: latest_generation,
              profiles: profiles(),
              tags: tags()
            }

          {:error, _} = err ->
            err
        end
      end

      def current_generation!() do
        current_path() |> profile!()
      end

      def profile(profile \\ profile_path()) do
        with {:ok, latest} <- follow_link(profile),
             {:ok, %File.Stat{ctime: ctime}} <- File.lstat(profile),
             {:ok, ctime} <- NaiveDateTime.from_erl(ctime),
             {:ok, ctime} <- DateTime.from_naive(ctime, "Etc/UTC") do
          {:ok,
           %Nix.Profile.Generation{
             created: ctime,
             path: latest,
             link: profile
           }}
        else
          {:error, _} = err -> err
        end
      end

      def profile!(profile \\ profile_path()) do
        {:ok, profile} = profile(profile)

        profile
      end

      def profiles(profile \\ profile_path()) do
        parent = Path.dirname(profile)
        profile_name = Path.basename(profile)
        link_pattern = ~r/^#{Regex.escape(profile_name)}-\d+-link$/

        File.ls!(parent)
        |> Enum.filter(&Regex.match?(link_pattern, &1))
        |> Enum.map(&Path.expand(&1, parent))
        |> Enum.sort_by(
          fn path ->
            [_, number] = Regex.run(~r/-(\d+)-link$/, path)
            String.to_integer(number)
          end,
          :desc
        )
        |> Enum.map(&profile!/1)
      end

      defoverridable(current_path: 0, tags: 0)
    end
  end

  def set(profile, artifact, on_output \\ fn _ -> :ok end) do
    File.mkdir_p!(Path.dirname(profile))

    {output, status} =
      System.cmd("nix-env", ["--profile", profile, "--set", artifact], stderr_to_stdout: true)

    lines = String.split(output, "\n", trim: true)
    Enum.each(lines, on_output)
    if status == 0, do: {:ok, lines}, else: {:error, status, lines}
  end

  def generations(profile) do
    parent = Path.dirname(profile)
    pattern = ~r/^#{Regex.escape(Path.basename(profile))}-(\d+)-link$/

    case File.ls(parent) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(pattern, &1))
        |> Enum.sort_by(fn entry ->
          [_, number] = Regex.run(pattern, entry)
          String.to_integer(number)
        end)
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, generations} ->
          link = Path.join(parent, entry)

          with {:ok, path} <- follow_link(link),
               {:ok, stat} <- File.lstat(link, time: :posix) do
            generation = %Nix.Profile.Generation{
              path: path,
              link: link,
              created: DateTime.from_unix!(stat.ctime)
            }

            {:cont, {:ok, [generation | generations]}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def follow_link(path) do
    parent = Path.dirname(path)

    case File.read_link(path) do
      {:ok, source} ->
        source = Path.absname(source, parent)

        case source |> Path.absname() |> File.lstat() do
          {:ok, %{type: :symlink}} -> follow_link(source)
          {:ok, _} -> {:ok, source}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end
end
