defmodule Maelstrom.GlobalData do
  @moduledoc """
  ETS-backed key-value store for GenServer.from() tuples.

  This module provides a way to serialize GenServer from tuples (which contain
  PIDs and references that can't be JSON-encoded) by storing them in ETS and
  using their hash as a serializable key.

  The hash is generated using :erlang.phash2/1 which provides a consistent
  hash for the same tuple within the same VM session.
  """

  use GenServer

  @doc """
  Starts the GlobalData store GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a GenServer.from() tuple and returns its hash key.

  ## Examples

      iex> from = {self(), make_ref()}
      iex> hash = Maelstrom.GlobalData.store_from(from)
      iex> is_integer(hash)
      true
  """
  @spec store_from(GenServer.from()) :: integer()
  def store_from(from) do
    hash = :erlang.phash2(from)
    :ets.insert(__MODULE__, {hash, from})
    hash
  end

  @doc """
  Stores the current pid associated with the node name.
  """
  @spec register(String.t()) :: :ok
  def register(node_name) do
    :ets.insert(__MODULE__, {node_name, self()})
    :ok
  end

  @doc """
  Retrieves a GenServer.from() tuple by its hash key.
  Retrieves a node pid by its node name.

  Returns `{:ok, from}` if found, or `:error` if not found.

  ## Examples

      iex> from = {self(), make_ref()}
      iex> hash = Maelstrom.GlobalData.store_from(from)
      iex> Maelstrom.GlobalData.fetch(hash)
      {:ok, from}
      
      iex> Maelstrom.GlobalData.fetch(999999)
      :error
  """
  @spec fetch(term) :: {:ok, GenServer.from()} | :error
  def fetch(hash) do
    case :ets.lookup(__MODULE__, hash) do
      [{^hash, from}] -> {:ok, from}
      [] -> :error
    end
  end

  @doc """
  Retrieves and removes a GenServer.from() tuple by its hash key.

  Returns `{:ok, from}` if found, or `:error` if not found.
  This is useful for one-time use scenarios where the from tuple
  should be consumed after retrieval.

  ## Examples

      iex> from = {self(), make_ref()}
      iex> hash = Maelstrom.GlobalData.store_from(from)
      iex> Maelstrom.GlobalData.pop!(hash)
      from
  """
  @spec pop!(integer()) :: {:ok, GenServer.from()} | :error
  def pop!(hash) when is_integer(hash) do
    case :ets.lookup(__MODULE__, hash) do
      [{^hash, from}] ->
        :ets.delete(__MODULE__, hash)
        from

      [] ->
        raise "No from tuple found for hash #{hash}"
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with public read/write access
    :ets.new(__MODULE__, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    {:ok, [], :hibernate}
  end
end
