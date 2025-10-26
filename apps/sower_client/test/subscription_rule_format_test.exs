defmodule SowerClient.SubscriptionRuleFormatTest do
  use ExUnit.Case, async: true

  alias SowerClient.SubscriptionRuleFormat

  describe "parse/1" do
    test "parses valid key=value format" do
      assert {:ok, %{"key" => "branch", "op" => "eq", "value" => "main"}} =
               SubscriptionRuleFormat.parse("branch=main")
    end

    test "handles values with special characters" do
      assert {:ok, %{"key" => "repo", "op" => "eq", "value" => "https://example.com/repo"}} =
               SubscriptionRuleFormat.parse("repo=https://example.com/repo")
    end

    test "handles values with spaces" do
      assert {:ok, %{"key" => "label", "op" => "eq", "value" => "my value"}} =
               SubscriptionRuleFormat.parse("label=my value")
    end

    test "handles values containing equals sign" do
      assert {:ok, %{"key" => "equation", "op" => "eq", "value" => "x=y"}} =
               SubscriptionRuleFormat.parse("equation=x=y")
    end

    test "returns error for invalid format without equals" do
      assert {:error, "Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse("invalid")
    end

    test "returns error for empty key" do
      assert {:error, "Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse("=value")
    end

    test "returns error for empty value" do
      assert {:error, "Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse("key=")
    end

    test "returns error for empty string" do
      assert {:error, "Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse("")
    end
  end

  describe "parse!/1" do
    test "parses valid key=value format" do
      assert %{"key" => "branch", "op" => "eq", "value" => "main"} =
               SubscriptionRuleFormat.parse!("branch=main")
    end

    test "raises ArgumentError for invalid format" do
      assert_raise ArgumentError, "Invalid rule format, expected key=value", fn ->
        SubscriptionRuleFormat.parse!("invalid")
      end
    end
  end

  describe "print/1" do
    test "prints eq operation in key=value format" do
      assert "branch=main" =
               SubscriptionRuleFormat.print(%{"key" => "branch", "op" => "eq", "value" => "main"})
    end

    test "prints eq operation with atom op in key=value format" do
      assert "branch=main" =
               SubscriptionRuleFormat.print(%{key: "branch", op: :eq, value: "main"})
    end

    test "prints non-eq operations in key op value format" do
      assert "count ne 5" =
               SubscriptionRuleFormat.print(%{"key" => "count", "op" => "ne", "value" => "5"})
    end

    test "handles struct input" do
      rule = %{key: "repo", op: "eq", value: "example"}

      assert "repo=example" = SubscriptionRuleFormat.print(rule)
    end
  end

  describe "parse_list/1" do
    test "parses list of valid rules" do
      assert {:ok,
              [
                %{"key" => "branch", "op" => "eq", "value" => "main"},
                %{"key" => "repo", "op" => "eq", "value" => "example"}
              ]} = SubscriptionRuleFormat.parse_list(["branch=main", "repo=example"])
    end

    test "parses empty list" do
      assert {:ok, []} = SubscriptionRuleFormat.parse_list([])
    end

    test "returns error for invalid rule in list with index" do
      assert {:error, "Rule 2: Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse_list(["branch=main", "invalid"])
    end

    test "returns error for first invalid rule" do
      assert {:error, "Rule 1: Invalid rule format, expected key=value"} =
               SubscriptionRuleFormat.parse_list(["invalid", "branch=main"])
    end
  end

  describe "print_list/1" do
    test "prints list of rules" do
      assert ["branch=main", "repo=example"] =
               SubscriptionRuleFormat.print_list([
                 %{"key" => "branch", "op" => "eq", "value" => "main"},
                 %{"key" => "repo", "op" => "eq", "value" => "example"}
               ])
    end

    test "prints empty list" do
      assert [] = SubscriptionRuleFormat.print_list([])
    end

    test "handles mixed eq and non-eq operations" do
      assert ["branch=main", "count ne 5"] =
               SubscriptionRuleFormat.print_list([
                 %{"key" => "branch", "op" => "eq", "value" => "main"},
                 %{"key" => "count", "op" => "ne", "value" => "5"}
               ])
    end
  end
end
