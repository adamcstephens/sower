defmodule SowerClient.Execution.Acknowledgement do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionAcknowledgement",
    type: :object,
    additionalProperties: false,
    properties: %{
      session: %Schema{type: :string},
      sequence: %Schema{type: :integer, minimum: 0}
    },
    required: [:session, :sequence]
  })
end

defmodule SowerClient.Execution.Request do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionRequest",
    type: :object,
    additionalProperties: false,
    "x-validate": __MODULE__.LiteralCommand,
    properties: %{
      system: %Schema{type: :string, enum: ["x86_64-linux"]},
      path: %Schema{type: :string, description: "Absolute guest executable path", maxLength: 4096},
      args: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 1024, default: []},
      env: %Schema{type: :object, additionalProperties: %Schema{type: :string}, default: %{}},
      stdin: %Schema{description: "JSON value delivered literally on stdin", nullable: true},
      cpus: %Schema{type: :integer, minimum: 1, maximum: 256, default: 2},
      memory: %Schema{type: :integer, minimum: 134_217_728, default: 4_294_967_296},
      scratch_bytes: %Schema{type: :integer, minimum: 1_048_576, default: 8_589_934_592},
      network: %Schema{type: :string, enum: ["none", "full"], default: "none"},
      timeout_ms: %Schema{type: :integer, minimum: 1, maximum: 86_400_000, default: 300_000}
    },
    required: [:system, :path, :stdin]
  })

  defmodule LiteralCommand do
    alias OpenApiSpex.Cast

    def cast(%Cast{} = context) do
      with {:ok, request} <- Cast.cast(%{context | schema: %{context.schema | "x-validate": nil}}),
           true <-
             String.starts_with?(request.path, "/") and not String.contains?(request.path, <<0>>) and
               Enum.all?(request.args, &(not String.contains?(&1, <<0>>))) and
               Enum.all?(request.env, fn {key, value} ->
                 key != "" and not String.contains?(key, ["=", <<0>>]) and
                   not String.contains?(value, <<0>>)
               end),
           payload = %{
             type: "execute",
             version: 1,
             path: request.path,
             args: request.args,
             env: request.env,
             stdin: request.stdin
           },
           true <- byte_size(Jason.encode!(payload)) <= 65536 do
        {:ok, request}
      else
        {:error, errors} ->
          {:error, errors}

        false ->
          Cast.error(
            context,
            {:custom, "invalid literal command or command frame exceeds 65536 bytes"}
          )
      end
    end
  end
end

defmodule SowerClient.Execution.Capability do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionCapability",
    type: :object,
    additionalProperties: false,
    properties: %{
      session: %Schema{type: :string},
      enabled: %Schema{type: :boolean},
      systems: %Schema{type: :array, items: %Schema{type: :string}},
      contract_min: %Schema{type: :integer},
      contract_max: %Schema{type: :integer},
      networks: %Schema{type: :array, items: %Schema{type: :string}},
      available: %Schema{
        type: :object,
        additionalProperties: false,
        properties:
          Map.new(
            [:vms, :cpus, :memory, :scratch_bytes],
            &{&1, %Schema{type: :integer, minimum: 0}}
          ),
        required: [:vms, :cpus, :memory, :scratch_bytes]
      },
      budgets: SowerClient.Config.VMCapacity
    },
    required: [
      :session,
      :enabled,
      :systems,
      :contract_min,
      :contract_max,
      :networks,
      :available,
      :budgets
    ]
  })
end

defmodule SowerClient.Execution.Dispatch do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionDispatch",
    type: :object,
    additionalProperties: false,
    properties: %{
      sid: %Schema{type: :string},
      session: %Schema{type: :string},
      run_sid: %Schema{type: :string},
      attempt: %Schema{type: :integer, minimum: 1},
      request: SowerClient.Execution.Request
    },
    required: [:sid, :run_sid, :session, :attempt, :request]
  })
end

defmodule SowerClient.Execution.Result do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionResult",
    type: :object,
    additionalProperties: false,
    properties: %{
      code: %Schema{type: :integer, minimum: 0, maximum: 255, nullable: true},
      signal: %Schema{type: :integer, minimum: 1, maximum: 64, nullable: true},
      error: %Schema{type: :string, nullable: true},
      detail: %Schema{type: :string, nullable: true},
      ready_ms: %Schema{type: :integer, minimum: 0, nullable: true},
      elapsed_ms: %Schema{type: :integer, minimum: 0, nullable: true},
      cleanup: %Schema{type: :string, enum: ["complete", "incomplete", "unknown"]},
      cleanup_error: %Schema{type: :string, nullable: true}
    },
    required: [:cleanup]
  })
end

defmodule SowerClient.Execution.Event do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionEvent",
    type: :object,
    additionalProperties: false,
    properties: %{
      sid: %Schema{type: :string},
      session: %Schema{type: :string},
      attempt: %Schema{type: :integer, minimum: 1},
      sequence: %Schema{type: :integer, minimum: 1},
      kind: %Schema{
        type: :string,
        enum: ["accepted", "running", "log", "result", "refused", "conflict"]
      },
      stream: %Schema{type: :string, enum: ["stdout", "stderr"]},
      bytes: %Schema{
        type: :string,
        description: "Base64-encoded binary stream bytes",
        maxLength: 87384
      },
      result: SowerClient.Execution.Result
    },
    required: [:sid, :session, :attempt, :sequence, :kind]
  })
end

defmodule SowerClient.Execution.Cancel do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionCancel",
    type: :object,
    additionalProperties: false,
    properties: %{
      sid: %Schema{type: :string},
      session: %Schema{type: :string},
      attempt: %Schema{type: :integer, minimum: 1}
    },
    required: [:sid, :session, :attempt]
  })
end

defmodule SowerClient.Execution.Info do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionInfo",
    type: :object,
    additionalProperties: false,
    properties: %{
      sid: %Schema{type: :string},
      state: %Schema{type: :string},
      run_sid: %Schema{type: :string},
      actor_sid: %Schema{type: :string},
      garden_sid: %Schema{type: :string, nullable: true},
      queue_reason: %Schema{type: :string, nullable: true},
      request: SowerClient.Execution.Request,
      result: SowerClient.Execution.Result,
      inserted_at: %Schema{type: :string, format: :"date-time"},
      updated_at: %Schema{type: :string, format: :"date-time"},
      cursor: %Schema{type: :integer, minimum: 0},
      dropped_log_bytes: %Schema{type: :integer, minimum: 0, default: 0}
    },
    required: [:sid, :run_sid, :state, :actor_sid, :request, :cursor]
  })
end

defmodule SowerClient.Execution.History do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "ExecutionHistory",
    type: :object,
    additionalProperties: false,
    properties: %{
      events: %Schema{type: :array, items: SowerClient.Execution.Event},
      cursor: %Schema{type: :integer, minimum: 0},
      execution: SowerClient.Execution.Info
    },
    required: [:events, :cursor, :execution]
  })
end
