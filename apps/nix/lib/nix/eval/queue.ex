defmodule Nix.Eval.Queue do
  @moduledoc """
  High-performance FIFO queue backed by ETS.

  Optimized for bulk operations and frequent size checks.
  Uses ordered_set with monotonic counter for FIFO ordering.

  ## Storage Design

  Uses ETS ordered_set where:
  - Keys: monotonically increasing integers (FIFO order)
  - Values: the queued items
  - Counter: :atomics reference for thread-safe sequence generation

  ## Performance Characteristics

  - enqueue/3: O(n) where n = number of items being added
  - dequeue/2: O(m) where m = number of items being removed
  - size/1: O(1) via :ets.info metadata
  - empty?/1: O(1) via :ets.info metadata

  All operations are lock-free for readers with read_concurrency.
  """

  @type t :: :ets.tid()
  @type item :: term()

  @doc """
  Creates a new queue.

  Returns the ETS table identifier and atomics reference for the counter.
  The table has public access with read_concurrency enabled.

  ## Options
    * `:name` - Named table (optional)

  ## Examples

      iex> {table, counter} = Nix.Eval.Queue.new()
      iex> is_reference(table)
      true
      iex> is_reference(counter)
      true
  """
  @spec new(keyword()) :: {t(), reference()}
  def new(opts \\ []) do
    table_opts = [
      :ordered_set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, false}  # Single writer (GenServer) is fine
    ]

    table_name = Keyword.get(opts, :name, __MODULE__)

    table = :ets.new(table_name, table_opts)

    # Create atomic counter starting at 0
    # Using atomics for thread-safe increment without locks
    counter = :atomics.new(1, signed: false)
    :atomics.put(counter, 1, 0)

    {table, counter}
  end

  @doc """
  Enqueues one or more items. Optimized for bulk inserts.

  ## Examples

      iex> {table, counter} = Nix.Eval.Queue.new()
      iex> Nix.Eval.Queue.enqueue(table, counter, :item1)
      :ok
      iex> Nix.Eval.Queue.enqueue(table, counter, [:item2, :item3, :item4])
      :ok
      iex> Nix.Eval.Queue.size(table)
      4
  """
  @spec enqueue(t(), reference(), item() | [item()]) :: :ok
  def enqueue(table, counter, items) when is_list(items) do
    # Bulk insert optimization: generate all keys first, then single insert
    count = length(items)

    # Atomically reserve a range of sequence numbers
    start_seq = :atomics.add_get(counter, 1, count)
    start_seq = start_seq - count + 1  # Adjust to get first number in range

    # Build list of {key, value} tuples
    records =
      items
      |> Enum.with_index(start_seq)
      |> Enum.map(fn {item, seq} -> {seq, item} end)

    # Single ETS insert for all items
    :ets.insert(table, records)
    :ok
  end

  def enqueue(table, counter, item) do
    seq = :atomics.add_get(counter, 1, 1)
    :ets.insert(table, {seq, item})
    :ok
  end

  @doc """
  Dequeues up to `count` items from the front of the queue.
  Returns empty list if queue is empty.

  ## Examples

      iex> {table, counter} = Nix.Eval.Queue.new()
      iex> Nix.Eval.Queue.enqueue(table, counter, [:a, :b, :c, :d, :e])
      :ok
      iex> Nix.Eval.Queue.dequeue(table, 3)
      [:a, :b, :c]
      iex> Nix.Eval.Queue.dequeue(table, 5)
      [:d, :e]
  """
  @spec dequeue(t(), pos_integer()) :: [item()]
  def dequeue(table, count) do
    dequeue_loop(table, count, :ets.first(table), [])
  end

  @doc """
  Returns the number of items in the queue. O(1) operation.

  ## Examples

      iex> {table, counter} = Nix.Eval.Queue.new()
      iex> Nix.Eval.Queue.size(table)
      0
      iex> Nix.Eval.Queue.enqueue(table, counter, [:a, :b, :c])
      :ok
      iex> Nix.Eval.Queue.size(table)
      3
  """
  @spec size(t()) :: non_neg_integer()
  def size(table) do
    :ets.info(table, :size)
  end

  @doc """
  Returns true if queue is empty. O(1) operation.

  ## Examples

      iex> {table, counter} = Nix.Eval.Queue.new()
      iex> Nix.Eval.Queue.empty?(table)
      true
      iex> Nix.Eval.Queue.enqueue(table, counter, :item)
      :ok
      iex> Nix.Eval.Queue.empty?(table)
      false
  """
  @spec empty?(t()) :: boolean()
  def empty?(table) do
    :ets.info(table, :size) == 0
  end

  @doc """
  Deletes the queue and frees resources.

  ## Examples

      iex> {table, _counter} = Nix.Eval.Queue.new()
      iex> Nix.Eval.Queue.delete(table)
      :ok
  """
  @spec delete(t()) :: :ok
  def delete(table) do
    :ets.delete(table)
    :ok
  end

  # Private helper for dequeue
  defp dequeue_loop(_table, 0, _key, acc), do: Enum.reverse(acc)
  defp dequeue_loop(_table, _count, :"$end_of_table", acc), do: Enum.reverse(acc)

  defp dequeue_loop(table, count, key, acc) do
    case :ets.take(table, key) do
      [{^key, item}] ->
        # Successfully took item, get next key and continue
        next_key = :ets.first(table)  # After take, first is now the next item
        dequeue_loop(table, count - 1, next_key, [item | acc])

      [] ->
        # Key was already taken (race condition), try next
        next_key = :ets.first(table)
        dequeue_loop(table, count, next_key, acc)
    end
  end
end
