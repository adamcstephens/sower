defmodule Garden.Storage do
  @moduledoc """
  Serializes Garden identity and subscription-state persistence.

  Explicit uninstall removes only the captured name/SID binding atomically, so
  a replacement subscription is not removed by a delayed completion.
  """

  use GenServer
  use TypedStruct

  require Logger

  @derive {Jason.Encoder, only: [:garden_sid]}

  typedstruct do
    field :garden_sid, String.t()
    field :subscriptions, list(SowerClient.Orchestration.Subscription), default: []
    field :oauth_credentials, map()
    field :private_key_pem, String.t()
    field :credentials_rejected_at, String.t()
    field :removed_subscription_sids, list(String.t()), default: []
  end

  @cooldown_seconds 60

  # client

  def get(garden) do
    GenServer.call(__MODULE__, {:get, garden})
  end

  def put(garden, value) do
    GenServer.call(__MODULE__, {:put, garden, value})
  end

  def remove_subscription(name, sid) do
    GenServer.call(__MODULE__, {:remove_subscription, name, sid})
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

      persist(default(), file)
      Logger.debug(msg: "Wrote initial storage", file: file)
    end

    Logger.debug(msg: "Reading storage", file: file)
    {:ok, bin} = File.read(file)

    raw =
      try do
        :erlang.binary_to_term(bin)
      rescue
        error in ArgumentError ->
          Logger.warning(
            msg: "Resetting corrupt storage to defaults",
            file: file,
            error: Exception.message(error)
          )

          data = default()
          persist(data, file)
          data
      end

    data =
      raw
      |> ensure_fields()

    if data != raw do
      persist(data, file)
      Logger.debug(msg: "Persisted migrated storage", file: file)
    end

    {:ok, %{file: file, data: data, cooldowns: %{}}}
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
  def handle_call({:put, :subscriptions, subscriptions}, _from, state) do
    active = Enum.reject(subscriptions, &(&1.sid in state.data.removed_subscription_sids))

    retained =
      Enum.filter(state.data.subscriptions || [], fn existing ->
        existing.seed_type in ["package", "devshell"] and
          existing.sid not in state.data.removed_subscription_sids and
          not Enum.any?(active, &(&1.name == existing.name))
      end)

    {:reply, :ok, do_write(%{state.data | subscriptions: active ++ retained}, state)}
  end

  def handle_call({:put, garden, value}, _from, state) do
    new_data = Map.put(state.data, garden, value)
    {:reply, :ok, do_write(new_data, state)}
  end

  def handle_call({:remove_subscription, name, sid}, _from, state) do
    subscriptions =
      Enum.reject(state.data.subscriptions, &(&1.name == name and &1.sid == sid))

    updated = %{
      state.data
      | subscriptions: subscriptions,
        removed_subscription_sids: Enum.uniq([sid | state.data.removed_subscription_sids])
    }

    {:reply, subscriptions, do_write(updated, state)}
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

  defp do_write(data, %{file: file} = state) do
    removed = Enum.uniq(state.data.removed_subscription_sids ++ data.removed_subscription_sids)

    subscriptions =
      case data.subscriptions do
        nil -> []
        subscriptions -> Enum.reject(subscriptions, &(&1.sid in removed))
      end

    data = %{data | subscriptions: subscriptions, removed_subscription_sids: removed}
    persist(data, file)
    Logger.debug(msg: "Wrote storage", file: file)
    %{state | data: data}
  end

  defp persist(%__MODULE__{} = data, file) do
    temporary = file <> ".tmp"
    File.write!(temporary, :erlang.term_to_binary(data), [:sync])
    File.rename!(temporary, file)

    if data.removed_subscription_sids != [] do
      executable = System.find_executable("sower") || raise "directory sync helper unavailable"

      case System.cmd(executable, ["internal", "sync-directory", Path.dirname(file)],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, code} -> raise "storage directory sync failed (#{code}): #{output}"
      end
    end
  end

  # Ensure deserialized structs have all current fields (handles schema evolution)
  defp ensure_fields(%{__struct__: __MODULE__} = data) do
    current = struct(__MODULE__, Map.from_struct(data))
    %{current | subscriptions: current.subscriptions || []}
  end

  defp default() do
    %__MODULE__{}
  end
end
