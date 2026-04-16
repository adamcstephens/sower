defmodule SowerClient.Orchestration.Subscription.Policy do
  use SowerClient.Schema

  alias SowerClient.Orchestration.Subscription.Window

  @actions ["stage", "activate", "restart"]
  @triggers ["manual", "scheduled", "realtime", "poll_on_connect"]

  @actions_by_seed_type %{
    "nixos" => ["stage", "activate", "restart"],
    "nix-darwin" => ["stage", "activate", "restart"],
    "home-manager" => ["stage", "activate"],
    "service" => ["stage", "activate"]
  }

  # Highest disruption first
  @disruption_hierarchy ["restart", "activate", "stage"]

  @default_policy [
    %{actions: ["activate"], triggers: ["manual", "scheduled", "poll_on_connect"]}
  ]

  OpenApiSpex.schema(%{
    title: "SubscriptionPolicy",
    description: "A deployment policy rule controlling when and how actions are permitted",
    type: :object,
    properties: %{
      actions: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: @actions},
        description: "Actions this rule permits"
      },
      triggers: %Schema{
        type: :array,
        items: %Schema{type: :string, enum: @triggers},
        description: "Triggers this rule applies to. Omit for all.",
        nullable: true
      },
      window: Window,
      confirm: %Schema{
        type: :boolean,
        description: "Require explicit confirmation before proceeding",
        default: false
      }
    },
    required: [:actions]
  })

  def actions, do: @actions
  def triggers, do: @triggers
  def actions_by_seed_type, do: @actions_by_seed_type

  @doc """
  Evaluate policy rules against a trigger and current time.

  The `timezone` parameter is the subscription's IANA timezone, used as fallback
  when a rule's window does not specify its own `tz`.

  Returns `{:allow, action}`, `{:confirm, action}`, or `:deny`.
  """
  def evaluate(rules, trigger, now, seed_type, timezone \\ "Etc/UTC") do
    rules = rules |> normalize_rules() |> effective_rules()
    supported_actions = Map.get(@actions_by_seed_type, seed_type, [])

    @disruption_hierarchy
    |> Enum.filter(&(&1 in supported_actions))
    |> Enum.find_value(:deny, fn action ->
      matching_rules =
        Enum.filter(rules, fn rule ->
          action_matches?(rule, action) and
            trigger_matches?(rule, trigger) and
            window_matches?(rule, now, timezone)
        end)

      case matching_rules do
        [] ->
          nil

        rules ->
          if Enum.any?(rules, &confirm?/1) do
            {:confirm, String.to_existing_atom(action)}
          else
            {:allow, String.to_existing_atom(action)}
          end
      end
    end)
  end

  @doc """
  Returns the highest-disruption action permitted by any rule at the given time,
  ignoring triggers. Used by the garden deployer to determine activation mode —
  the server already approved the deployment, the garden just needs to know how
  far it can go right now.

  Returns `:restart`, `:activate`, `:stage`, or `nil`.
  """
  def highest_permitted_action(rules, now, seed_type, timezone \\ "Etc/UTC") do
    rules = rules |> normalize_rules() |> effective_rules()
    supported_actions = Map.get(@actions_by_seed_type, seed_type, [])

    @disruption_hierarchy
    |> Enum.filter(&(&1 in supported_actions))
    |> Enum.find_value(nil, fn action ->
      if Enum.any?(rules, fn rule ->
           action_matches?(rule, action) and window_matches?(rule, now, timezone)
         end) do
        String.to_existing_atom(action)
      end
    end)
  end

  @doc """
  Map an audit reason to a policy trigger.
  """
  def trigger_for_reason(:user_triggered), do: :manual
  def trigger_for_reason(:user_retry), do: :manual
  def trigger_for_reason(:schedule_triggered), do: :scheduled
  def trigger_for_reason(:realtime_triggered), do: :realtime
  def trigger_for_reason(:poll_on_connect), do: :poll_on_connect

  @doc """
  Convert legacy subscription fields to equivalent policy rules.

  Accepts a subscription struct or map with old-style fields:
  `reboot_policy`, `allow_realtime`, `poll_on_connect`, `window`, `activation_args`.
  """
  def from_legacy(subscription) do
    reboot_policy = get_field(subscription, :reboot_policy, "never")
    allow_realtime = get_field(subscription, :allow_realtime, false)
    poll_on_connect = get_field(subscription, :poll_on_connect, false)
    window = get_field(subscription, :window, nil)

    actions = build_legacy_actions(reboot_policy)
    triggers = build_legacy_triggers(allow_realtime, poll_on_connect)

    rule = %{actions: actions, triggers: triggers}

    rule =
      if window do
        Map.put(rule, :window, normalize_window(window))
      else
        rule
      end

    %{"default" => rule}
  end

  defp build_legacy_actions(reboot_policy) when reboot_policy in ["always", "when-required"],
    do: ["stage", "activate", "restart"]

  defp build_legacy_actions(_), do: ["stage", "activate"]

  defp build_legacy_triggers(allow_realtime, poll_on_connect) do
    base = ["manual", "scheduled"]
    base = if poll_on_connect, do: base ++ ["poll_on_connect"], else: base
    if allow_realtime, do: base ++ ["realtime"], else: base
  end

  defp normalize_window(%{days: _} = w),
    do: %{days: w.days, time_start: w.time_start, time_end: w.time_end, tz: Map.get(w, :tz)}

  defp normalize_window(%{"days" => _} = w),
    do: %{
      days: w["days"],
      time_start: w["time_start"],
      time_end: w["time_end"],
      tz: w["tz"]
    }

  defp get_field(%{__struct__: _} = s, key, default), do: Map.get(s, key, default)

  defp get_field(m, key, default) when is_map(m),
    do: Map.get(m, key, Map.get(m, to_string(key), default))

  @doc """
  Returns true if any policy rule includes the realtime trigger.
  """
  def has_realtime_trigger?(rules) do
    rules = rules |> normalize_rules() |> effective_rules()

    Enum.any?(rules, fn rule ->
      case rule_triggers(rule) do
        nil -> true
        triggers -> "realtime" in triggers
      end
    end)
  end

  defp normalize_rules(nil), do: nil
  defp normalize_rules(rules) when is_list(rules), do: rules
  defp normalize_rules(rules) when rules == %{}, do: []

  defp normalize_rules(rules) when is_map(rules) do
    Enum.map(rules, fn {name, rule} ->
      Map.put(rule, :name, name)
    end)
  end

  defp effective_rules(nil), do: @default_policy
  defp effective_rules([]), do: @default_policy
  defp effective_rules(rules) when rules == %{}, do: @default_policy

  defp effective_rules(rules) when is_map(rules) do
    Enum.map(rules, fn {_name, rule} -> rule end)
  end

  defp effective_rules(rules) when is_list(rules), do: rules

  defp action_matches?(rule, action) do
    actions = rule_actions(rule)
    action in actions
  end

  defp trigger_matches?(rule, trigger) do
    case rule_triggers(rule) do
      nil -> true
      triggers -> to_string(trigger) in triggers
    end
  end

  defp window_matches?(rule, now, timezone) do
    case rule_window(rule) do
      nil -> true
      window -> within_window?(window, now, timezone)
    end
  end

  defp within_window?(window, now, timezone) do
    tz = window_tz(window) || timezone || "Etc/UTC"
    local = DateTime.shift_zone!(now, tz)
    day = local |> DateTime.to_date() |> Date.day_of_week() |> day_name()
    time = DateTime.to_time(local)

    start_time = Time.from_iso8601!("#{window_time_start(window)}:00")
    end_time = Time.from_iso8601!("#{window_time_end(window)}:00")

    days = window_days(window)

    if Time.compare(start_time, end_time) == :gt do
      # Overnight span: e.g. 22:00-06:00
      # The "days" field refers to the day the window opens
      overnight_match?(days, day, time, start_time, end_time, local)
    else
      # Normal span: e.g. 09:00-17:00
      day in days and
        Time.compare(time, start_time) != :lt and
        Time.compare(time, end_time) != :gt
    end
  end

  defp overnight_match?(days, day, time, start_time, end_time, local) do
    # Check if we're in the "after start" portion (same day as window opens)
    in_opening_day = day in days and Time.compare(time, start_time) != :lt

    # Check if we're in the "before end" portion (day after window opened)
    yesterday =
      local
      |> DateTime.to_date()
      |> Date.add(-1)
      |> Date.day_of_week()
      |> day_name()

    in_closing_day = yesterday in days and Time.compare(time, end_time) != :gt

    in_opening_day or in_closing_day
  end

  # Field accessors that work with both maps (string/atom keys) and structs

  defp rule_actions(%{actions: actions}), do: actions
  defp rule_actions(%{"actions" => actions}), do: actions

  defp rule_triggers(%{triggers: triggers}), do: triggers
  defp rule_triggers(%{"triggers" => triggers}), do: triggers
  defp rule_triggers(_), do: nil

  defp rule_window(%{window: window}), do: window
  defp rule_window(%{"window" => window}), do: window
  defp rule_window(_), do: nil

  defp confirm?(%{confirm: true}), do: true
  defp confirm?(%{"confirm" => true}), do: true
  defp confirm?(_), do: false

  defp window_days(%{days: days}), do: days
  defp window_days(%{"days" => days}), do: days

  defp window_time_start(%{time_start: ts}), do: ts
  defp window_time_start(%{"time_start" => ts}), do: ts

  defp window_time_end(%{time_end: te}), do: te
  defp window_time_end(%{"time_end" => te}), do: te

  defp window_tz(%{tz: tz}), do: tz
  defp window_tz(%{"tz" => tz}), do: tz
  defp window_tz(_), do: nil

  defp day_name(1), do: "mon"
  defp day_name(2), do: "tue"
  defp day_name(3), do: "wed"
  defp day_name(4), do: "thu"
  defp day_name(5), do: "fri"
  defp day_name(6), do: "sat"
  defp day_name(7), do: "sun"
end
