defmodule SowerClient.SubscriptionRuleFormat do
  @moduledoc """
  Parser and printer for subscription rules in key=value format.
  """

  @doc """
  Parse a key=value string into a subscription rule map.

  ## Examples

      iex> SowerClient.SubscriptionRuleFormat.parse("branch=main")
      {:ok, %{"key" => "branch", "op" => "eq", "value" => "main"}}

      iex> SowerClient.SubscriptionRuleFormat.parse("invalid")
      {:error, "Invalid rule format, expected key=value"}
  """
  def parse(rule_string) when is_binary(rule_string) do
    case String.split(rule_string, "=", parts: 2) do
      [key, value] when key != "" and value != "" ->
        {:ok, %{"key" => key, "op" => "eq", "value" => value}}

      _ ->
        {:error, "Invalid rule format, expected key=value"}
    end
  end

  @doc """
  Parse a key=value string into a subscription rule map, raising on error.

  ## Examples

      iex> SowerClient.SubscriptionRuleFormat.parse!("branch=main")
      %{"key" => "branch", "op" => "eq", "value" => "main"}
  """
  def parse!(rule_string) do
    case parse(rule_string) do
      {:ok, rule} -> rule
      {:error, msg} -> raise ArgumentError, msg
    end
  end

  @doc """
  Print a subscription rule in key=value format.

  ## Examples

      iex> SowerClient.SubscriptionRuleFormat.print(%{key: "branch", op: "eq", value: "main"})
      "branch=main"

      iex> SowerClient.SubscriptionRuleFormat.print(%{key: "branch", op: "ne", value: "main"})
      "branch ne main"
  """
  def print(rule) do
    key = Map.get(rule, :key) || Map.get(rule, "key")
    op = Map.get(rule, :op) || Map.get(rule, "op")
    value = Map.get(rule, :value) || Map.get(rule, "value")

    case op do
      "eq" -> "#{key}=#{value}"
      :eq -> "#{key}=#{value}"
      _ -> "#{key} #{op} #{value}"
    end
  end

  @doc """
  Parse a list of key=value strings into subscription rule maps.

  ## Examples

      iex> SowerClient.SubscriptionRuleFormat.parse_list(["branch=main", "repo=example"])
      {:ok, [
        %{"key" => "branch", "op" => "eq", "value" => "main"},
        %{"key" => "repo", "op" => "eq", "value" => "example"}
      ]}
  """
  def parse_list(rule_strings) when is_list(rule_strings) do
    rule_strings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {rule_string, index}, {:ok, acc} ->
      case parse(rule_string) do
        {:ok, rule} -> {:cont, {:ok, [rule | acc]}}
        {:error, msg} -> {:halt, {:error, "Rule #{index + 1}: #{msg}"}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  @doc """
  Print a list of subscription rules in key=value format.

  ## Examples

      iex> SowerClient.SubscriptionRuleFormat.print_list([
      ...>   %{key: "branch", op: "eq", value: "main"},
      ...>   %{key: "repo", op: "eq", value: "example"}
      ...> ])
      ["branch=main", "repo=example"]
  """
  def print_list(rules) when is_list(rules) do
    Enum.map(rules, &print/1)
  end
end
