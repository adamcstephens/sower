defmodule Nix.Eval.Jobs do
  use GenServer
  use TypedStruct

  typedstruct do
    field :target, String.t()
    field :workers, integer()
    field :from, pid()
  end

  def run(target, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {target, opts})

    GenServer.call(pid, :run, 10 * 60 * 60 * 1000)
  end

  def init({target, opts}) do
    state = %__MODULE__{
      target: target,
      workers: Keyword.get(opts, :workers, 8)
    }

    {:ok, state}
  end

  def handle_call(:run, from, state) do
    results = run_target(state.target)

    GenServer.reply(from, {check_ok(results), results})

    # TODO shutdown?
    {:noreply, state}
  end

  def run_target(target) when is_binary(target) do
    case Nix.Eval.run(target) do
      {_, %{output: output} = eval} when is_binary(output) ->
        [eval]

      {:ok, %{output: output}} when is_list(output) ->
        # TODO this is flake specific, at least handle it
        output
        |> Enum.map(&"#{target}.#{&1}")
        |> Enum.map(&run_target/1)
        |> List.flatten()
    end
  end

  def check_ok(results) do
    if Enum.any?(results, fn eval -> eval.status == :error end) do
      :error
    else
      :ok
    end
  end
end
