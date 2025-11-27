defmodule SowerAgent.Subscription do
  @moduledoc """
  Agent has its own idea of subscription to avoid sending
  everything to the server m
  """
  alias OpenApiSpex.Schema
  require OpenApiSpex
  require Logger

  alias SowerClient.Schemas.Orchestration.Subscription.Rule

  OpenApiSpex.schema(%{
    title: "AgentSubscription",
    type: :object,
    properties: %{
      # Fields shared with server (mirrors SowerClient.Schemas.Orchestration.Subscription)
      sid: %Schema{
        type: :string,
        description: "Subscription sid allocated by Sower",
        readOnly: true,
        nullable: true
      },
      seed_name: %Schema{
        type: :string,
        description: "Name of the seed",
        example: "myhost"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: SowerClient.Schemas.Seed.seed_types(),
        example: "nixos"
      },
      rules: %Schema{
        type: :array,
        items: Rule,
        default: [],
        description: "Tag-based rules to filter seeds"
      },

      # Agent-only fields
      schedule: %Schema{
        type: :string,
        description: "Cron expression for polling schedule",
        example: "*/15 * * * *",
        nullable: true
      },
      poll_on_connect: %Schema{
        type: :boolean,
        description: "Whether to request deployment immediately on connect",
        default: false
      }
    },
    required: [:seed_name, :seed_type]
  })

  @doc """
  Convert to the client schema for sending to the server.
  Strips agent-only fields.
  """
  def to_client_schema(%__MODULE__{} = sub) do
    %SowerClient.Schemas.Orchestration.Subscription{
      sid: sub.sid,
      seed_name: sub.seed_name,
      seed_type: sub.seed_type,
      rules: sub.rules
    }
  end

  @doc """
  Cast a map to the AgentSubscription struct with validation.
  """
  def cast(attrs) do
    spec = build_spec()
    resolved_schema = spec.components.schemas["AgentSubscription"]
    OpenApiSpex.cast_value(attrs, resolved_schema, spec)
  end

  def cast!(attrs) do
    {:ok, val} = cast(attrs)
    val
  end

  def start_schedule(%__MODULE__{sid: sid, schedule: schedule} = sub)
      when not is_nil(sid) and not is_nil(schedule) do
    SowerAgent.Scheduler.new_job()
    |> Quantum.Job.set_name(:"sub_#{sid}")
    |> Quantum.Job.set_schedule(sub.schedule)
    |> Quantum.Job.set_task(fn ->
      Logger.debug(
        msg: "Running subscription schedule",
        subscription_sid: sid,
        schedule: schedule
      )
    end)
    |> SowerAgent.Scheduler.add_job()
  end

  def start_schedule(_), do: nil

  defp build_spec do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{title: "AgentSubscription", version: "1.0.0"},
      paths: %{},
      components: nil
    }
    |> OpenApiSpex.resolve_schema_modules()
    |> OpenApiSpex.add_schemas([__MODULE__])
  end
end
