defmodule Vsr.KV do
  @moduledoc """
  Key-Value store client that wraps calls to a Vsr.Replica.

  This module provides a simple API for interacting with a VSR replica
  by wrapping VSR protocol operations in a clean key-value interface.
  """

  alias Vsr.Replica
  alias Vsr.Messages

  defstruct [:replica_pid]

  @doc """
  Creates a new KV client that wraps the given replica.
  """
  def new(replica_pid) do
    %__MODULE__{replica_pid: replica_pid}
  end

  @doc """
  Puts a key-value pair into the store.
  """
  def put(%__MODULE__{replica_pid: replica_pid}, key, value) do
    request_id = make_ref()
    operation = {:put, key, value}

    Replica.client_request(replica_pid, operation, self(), request_id)

    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @doc """
  Gets a value by key from the store.
  """
  def get(%__MODULE__{replica_pid: replica_pid}, key) do
    request_id = make_ref()
    operation = {:get, key}

    Replica.client_request(replica_pid, operation, self(), request_id)

    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end

  @doc """
  Deletes a key from the store.
  """
  def delete(%__MODULE__{replica_pid: replica_pid}, key) do
    request_id = make_ref()
    operation = {:delete, key}

    Replica.client_request(replica_pid, operation, self(), request_id)

    receive do
      %Messages.ClientReply{request_id: ^request_id, result: result} ->
        result
    after
      5000 ->
        {:error, :timeout}
    end
  end
end
