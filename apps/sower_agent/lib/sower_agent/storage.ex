defmodule SowerAgent.Storage do
  use GenServer
  use TypedStruct

  require Logger

  @derive {Jason.Encoder, only: [:local_sid, :agent_sid]}

  typedstruct do
    field :local_sid, String.t()
    field :agent_sid, String.t()

    field :subscriptions, list(SowerClient.Orchestration.Subscription)
  end

  # client

  def get(field) do
    GenServer.call(__MODULE__, {:get, field})
  end

  def put(field, value) do
    GenServer.call(__MODULE__, {:put, field, value})
  end

  def write(struct) do
    GenServer.call(__MODULE__, {:write, struct})
  end

  def read() do
    GenServer.call(__MODULE__, :read)
  end

  # server

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(_opts) do
    state_dir = SowerAgent.Config.get().state_directory
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

    data = :erlang.binary_to_term(bin)

    {:ok, %{file: file, data: data}}
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
  def handle_call({:put, field, value}, _from, state) do
    new_data = Map.put(state.data, field, value)
    {:reply, :ok, do_write(new_data, state)}
  end

  defp do_write(data, %{file: file} = state) do
    File.write!(file, :erlang.term_to_binary(data))
    Logger.debug(msg: "Wrote storage", file: file)
    %{state | data: data}
  end

  defp default() do
    %__MODULE__{
      local_sid: SowerClient.Sid.generate("loc_agent")
    }
  end
end
