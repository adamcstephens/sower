defmodule Garden.Storage do
  use GenServer
  use TypedStruct

  require Logger

  @derive {Jason.Encoder, only: [:garden_sid]}

  typedstruct do
    field :garden_sid, String.t()
    field :subscriptions, list(SowerClient.Orchestration.Subscription)
    field :oauth_credentials, map()
    field :private_key_pem, String.t()
  end

  @cooldown_seconds 60
  @max_attempts 3

  # client

  def get(garden) do
    GenServer.call(__MODULE__, {:get, garden})
  end

  def put(garden, value) do
    GenServer.call(__MODULE__, {:put, garden, value})
  end

  def write(struct) do
    GenServer.call(__MODULE__, {:write, struct})
  end

  def read() do
    GenServer.call(__MODULE__, :read)
  end

  def check_cooldown(key) do
    GenServer.call(__MODULE__, {:check_cooldown, key})
  end

  @doc """
  Like `check_cooldown/1`, but also caps the total number of attempts.

  Returns `:ok` when the attempt may proceed, `{:cooldown, elapsed}` while the
  window is still open, and `:exhausted` once the cap has been reached.
  """
  def check_attempt(key, opts \\ []) do
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, @cooldown_seconds)
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)

    GenServer.call(__MODULE__, {:check_attempt, key, cooldown_seconds, max_attempts})
  end

  # server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    state_dir = Garden.Config.get().state_directory
    file = Path.join(state_dir, "storage.etf")

    if not File.exists?(file) do
      parent_dir = file |> Path.dirname()

      if not File.dir?(parent_dir) do
        File.mkdir_p!(parent_dir)
        Logger.debug(msg: "Creating storage parent directory", dir: parent_dir)
      end

      File.write!(file, :erlang.term_to_binary(default()))
      Logger.debug(msg: "Wrote initial storage", file: file)
    end

    Logger.debug(msg: "Reading storage", file: file)
    {:ok, bin} = File.read(file)

    raw = :erlang.binary_to_term(bin)

    data =
      raw
      |> ensure_fields()

    if data != raw do
      File.write!(file, :erlang.term_to_binary(data))
      Logger.debug(msg: "Persisted migrated storage", file: file)
    end

    {:ok, %{file: file, data: data, cooldowns: %{}, attempts: %{}}}
  end

  @impl GenServer
  def handle_call({:write, struct}, _from, state) do
    {:reply, :ok, do_write(struct, state)}
  end

  @impl GenServer
  def handle_call(:read, _from, state) do
    {:reply, state.data, state}
  end

  @impl GenServer
  def handle_call({:put, garden, value}, _from, state) do
    new_data = Map.put(state.data, garden, value)
    {:reply, :ok, do_write(new_data, state)}
  end

  @impl GenServer
  def handle_call({:check_cooldown, key}, _from, state) do
    now = System.monotonic_time(:second)

    case Map.get(state.cooldowns, key) do
      last when is_integer(last) and now - last < @cooldown_seconds ->
        {:reply, {:cooldown, now - last}, state}

      _ ->
        {:reply, :ok, put_in(state.cooldowns[key], now)}
    end
  end

  @impl GenServer
  def handle_call({:check_attempt, key, cooldown_seconds, max_attempts}, _from, state) do
    now = System.monotonic_time(:second)
    last = Map.get(state.cooldowns, key)

    cond do
      Map.get(state.attempts, key, 0) >= max_attempts ->
        {:reply, :exhausted, state}

      is_integer(last) and now - last < cooldown_seconds ->
        {:reply, {:cooldown, now - last}, state}

      true ->
        state =
          state
          |> put_in([:cooldowns, key], now)
          |> update_in([:attempts, key], &((&1 || 0) + 1))

        {:reply, :ok, state}
    end
  end

  defp do_write(data, %{file: file} = state) do
    File.write!(file, :erlang.term_to_binary(data))
    Logger.debug(msg: "Wrote storage", file: file)
    %{state | data: data}
  end

  # Ensure deserialized structs have all current fields (handles schema evolution)
  defp ensure_fields(%{__struct__: __MODULE__} = data) do
    struct(__MODULE__, Map.from_struct(data))
  end

  defp default() do
    %__MODULE__{}
  end
end
