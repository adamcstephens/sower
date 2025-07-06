defmodule Nix.Profile do
  use Xema

  @derive Jason.Encoder

  xema_struct do
    field :type, atom()
    field :current, __MODULE__.Generation
    field :latest, __MODULE__.Generation
    field :previous, :list, items: __MODULE__.Generation

    required [:type, :current]
  end

  @doc "Path to the currently running version of the profile"
  @callback current_path() :: :string

  @doc "Calculate path to the profile"
  @callback profile_path() :: :string

  @doc "read the type's state"
  @callback get_state() :: {:ok, __MODULE__} | {:error, :string | atom()}

  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)

    quote do
      @behaviour unquote(__MODULE__)

      @impl unquote(__MODULE__)
      def get_state() do
        case path_to_generation() do
          {:ok, latest_generation} ->
            unquote(__MODULE__).cast(%{
              type: unquote(type),
              current: current_generation!(),
              latest: latest_generation,
              previous: profile_generations()
            })

          {:error, _} = err ->
            err
        end
      end

      def current_generation!() do
        current_path() |> path_to_generation!()
      end

      def path_to_generation(profile \\ __MODULE__.profile_path()) do
        with {:ok, latest} <- follow_link(profile),
             {:ok, %File.Stat{ctime: ctime}} <- File.lstat(profile),
             {:ok, ctime} <- NaiveDateTime.from_erl(ctime),
             {:ok, ctime} <- DateTime.from_naive(ctime, Timex.Timezone.Local.lookup()) do
          unquote(__MODULE__).Generation.cast(%{
            created: ctime,
            path: latest,
            link: profile
          })
        else
          {:error, _} = err -> err
        end
      end

      def path_to_generation!(profile) do
        {:ok, generation} = path_to_generation(profile)

        generation
      end

      def profile_generations(profile \\ __MODULE__.profile_path()) do
        parent = Path.dirname(profile)
        profile_name = Path.basename(profile)

        File.ls!(parent)
        |> Enum.filter(&String.starts_with?(&1, profile_name))
        |> Enum.reject(&(&1 == profile_name))
        |> Enum.map(&Path.expand(&1, parent))
        |> Enum.sort()
        |> Enum.reverse()
        |> Enum.map(&path_to_generation!/1)
      end

      defp follow_link(path) do
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
  end
end
