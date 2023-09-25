defmodule Sower.SCMTest do
  use Sower.DataCase

  alias Sower.SCM

  describe "hooks" do
    alias Sower.SCM.Hook

    import Sower.SCMFixtures

    @invalid_attrs %{request: nil}

    test "list_hooks/0 returns all hooks" do
      hook = hook_fixture()
      assert SCM.list_hooks() == [hook]
    end

    test "get_hook!/1 returns the hook with given id" do
      hook = hook_fixture()
      assert SCM.get_hook!(hook.id) == hook
    end

    test "create_hook/1 with valid data creates a hook" do
      valid_attrs = %{request: %{}}

      assert {:ok, %Hook{} = hook} = SCM.create_hook(valid_attrs)
      assert hook.request == %{}
    end

    test "create_hook/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = SCM.create_hook(@invalid_attrs)
    end

    test "update_hook/2 with valid data updates the hook" do
      hook = hook_fixture()
      update_attrs = %{request: %{}}

      assert {:ok, %Hook{} = hook} = SCM.update_hook(hook, update_attrs)
      assert hook.request == %{}
    end

    test "update_hook/2 with invalid data returns error changeset" do
      hook = hook_fixture()
      assert {:error, %Ecto.Changeset{}} = SCM.update_hook(hook, @invalid_attrs)
      assert hook == SCM.get_hook!(hook.id)
    end

    test "delete_hook/1 deletes the hook" do
      hook = hook_fixture()
      assert {:ok, %Hook{}} = SCM.delete_hook(hook)
      assert_raise Ecto.NoResultsError, fn -> SCM.get_hook!(hook.id) end
    end

    test "change_hook/1 returns a hook changeset" do
      hook = hook_fixture()
      assert %Ecto.Changeset{} = SCM.change_hook(hook)
    end
  end
end
