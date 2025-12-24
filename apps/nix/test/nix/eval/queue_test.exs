defmodule Nix.Eval.QueueTest do
  use ExUnit.Case, async: true

  alias Nix.Eval.Queue

  describe "new/1" do
    test "creates a new queue" do
      {table, counter} = Queue.new()
      assert is_reference(table)
      assert is_reference(counter)
      assert Queue.empty?(table)
      assert Queue.size(table) == 0
    end

    test "creates a named queue" do
      {table, counter} = Queue.new(name: :test_queue)
      assert is_reference(table)
      assert is_reference(counter)
      assert :test_queue == :ets.info(table, :name)
    end
  end

  describe "enqueue/3" do
    test "enqueues a single item" do
      {table, counter} = Queue.new()
      assert :ok = Queue.enqueue(table, counter, :item1)
      assert Queue.size(table) == 1
      refute Queue.empty?(table)
    end

    test "enqueues multiple items as a list" do
      {table, counter} = Queue.new()
      items = [:item1, :item2, :item3]
      assert :ok = Queue.enqueue(table, counter, items)
      assert Queue.size(table) == 3
    end

    test "enqueues items sequentially" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, :first)
      Queue.enqueue(table, counter, :second)
      Queue.enqueue(table, counter, :third)
      assert Queue.size(table) == 3
    end

    test "handles bulk enqueue of large lists" do
      {table, counter} = Queue.new()
      items = Enum.to_list(1..10_000)
      assert :ok = Queue.enqueue(table, counter, items)
      assert Queue.size(table) == 10_000
    end

    test "handles empty list enqueue" do
      {table, counter} = Queue.new()
      assert :ok = Queue.enqueue(table, counter, [])
      assert Queue.size(table) == 0
      assert Queue.empty?(table)
    end
  end

  describe "dequeue/2" do
    test "dequeues items in FIFO order" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, [:first, :second, :third])

      result = Queue.dequeue(table, 2)
      assert result == [:first, :second]
      assert Queue.size(table) == 1

      result = Queue.dequeue(table, 1)
      assert result == [:third]
      assert Queue.empty?(table)
    end

    test "dequeues from empty queue returns empty list" do
      {table, _counter} = Queue.new()
      assert Queue.dequeue(table, 5) == []
    end

    test "dequeues fewer items than requested when queue is small" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, [:a, :b])

      result = Queue.dequeue(table, 10)
      assert result == [:a, :b]
      assert Queue.empty?(table)
    end

    test "maintains FIFO order across multiple enqueue/dequeue operations" do
      {table, counter} = Queue.new()

      Queue.enqueue(table, counter, [1, 2, 3])
      assert Queue.dequeue(table, 2) == [1, 2]

      Queue.enqueue(table, counter, [4, 5, 6])
      assert Queue.dequeue(table, 3) == [3, 4, 5]

      Queue.enqueue(table, counter, 7)
      assert Queue.dequeue(table, 10) == [6, 7]
    end

    test "handles dequeue of large bulk enqueue" do
      {table, counter} = Queue.new()
      items = Enum.to_list(1..1000)
      Queue.enqueue(table, counter, items)

      result = Queue.dequeue(table, 500)
      assert length(result) == 500
      assert result == Enum.to_list(1..500)

      result = Queue.dequeue(table, 500)
      assert length(result) == 500
      assert result == Enum.to_list(501..1000)

      assert Queue.empty?(table)
    end
  end

  describe "size/1" do
    test "returns 0 for empty queue" do
      {table, _counter} = Queue.new()
      assert Queue.size(table) == 0
    end

    test "returns correct size after enqueues" do
      {table, counter} = Queue.new()

      Queue.enqueue(table, counter, :a)
      assert Queue.size(table) == 1

      Queue.enqueue(table, counter, [:b, :c])
      assert Queue.size(table) == 3
    end

    test "returns correct size after dequeues" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, [1, 2, 3, 4, 5])

      Queue.dequeue(table, 2)
      assert Queue.size(table) == 3

      Queue.dequeue(table, 3)
      assert Queue.size(table) == 0
    end
  end

  describe "empty?/1" do
    test "returns true for new queue" do
      {table, _counter} = Queue.new()
      assert Queue.empty?(table)
    end

    test "returns false when queue has items" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, :item)
      refute Queue.empty?(table)
    end

    test "returns true after all items dequeued" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, [:a, :b, :c])
      Queue.dequeue(table, 3)
      assert Queue.empty?(table)
    end
  end

  describe "delete/1" do
    test "deletes the queue table" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, :item)

      assert :ok = Queue.delete(table)
      # :ets.info returns undefined for deleted tables
      assert :ets.info(table, :size) == :undefined
    end
  end

  describe "complex scenarios" do
    test "handles mixed operations" do
      {table, counter} = Queue.new()

      # Start with some items
      Queue.enqueue(table, counter, [1, 2, 3])
      assert Queue.size(table) == 3

      # Dequeue some
      assert Queue.dequeue(table, 1) == [1]
      assert Queue.size(table) == 2

      # Add more
      Queue.enqueue(table, counter, [4, 5])
      assert Queue.size(table) == 4

      # Dequeue all
      result = Queue.dequeue(table, 10)
      assert result == [2, 3, 4, 5]
      assert Queue.empty?(table)
    end

    test "handles struct items" do
      {table, counter} = Queue.new()

      items = [
        %{id: 1, data: "first"},
        %{id: 2, data: "second"},
        %{id: 3, data: "third"}
      ]

      Queue.enqueue(table, counter, items)
      result = Queue.dequeue(table, 3)

      assert result == items
    end

    test "monotonic sequence ensures ordering even with bulk operations" do
      {table, counter} = Queue.new()

      # Mix single and bulk enqueues
      Queue.enqueue(table, counter, :a)
      Queue.enqueue(table, counter, [:b, :c, :d])
      Queue.enqueue(table, counter, :e)
      Queue.enqueue(table, counter, [:f, :g])

      result = Queue.dequeue(table, 10)
      assert result == [:a, :b, :c, :d, :e, :f, :g]
    end
  end

  describe "concurrent access (read_concurrency)" do
    test "multiple processes can read size concurrently" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, Enum.to_list(1..100))

      # Spawn multiple processes to read size
      tasks = for _ <- 1..10 do
        Task.async(fn ->
          Queue.size(table)
        end)
      end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == 100))
    end

    test "reads don't block during other reads" do
      {table, counter} = Queue.new()
      Queue.enqueue(table, counter, Enum.to_list(1..1000))

      # This should complete quickly due to read_concurrency
      start = System.monotonic_time(:millisecond)

      tasks = for _ <- 1..100 do
        Task.async(fn ->
          Queue.size(table)
          Queue.empty?(table)
        end)
      end

      Task.await_many(tasks)
      elapsed = System.monotonic_time(:millisecond) - start

      # Should be fast (under 100ms for 100 concurrent readers)
      assert elapsed < 100
    end
  end
end
