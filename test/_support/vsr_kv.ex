defmodule VsrKv do
  @moduledoc """
  KV store using VSR for distributed consistency.
  """

  @enforce_keys [:vsr]
  defstruct @enforce_keys ++ [map: %{}]

  # external API

  def new(vsr, options) do
    %__MODULE__{vsr: vsr}
  end

  def start_link(vsr, options) do
    kv = VsrKv.new(vsr, options)
    {:ok, kv}
  end

  def fetch(kv, key) do
    Vsr.client_request(kv.vsr, {:fetch, key})
  end

  def fetch!(kv, key) do
    case fetch(kv, key) do
      {:ok, value} -> value
      :error -> raise KeyError, term: kv, key: key
    end
  end

  def get(kv, key, default \\ nil) do
    case fetch(kv, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def put(kv, key, value) do
    Vsr.client_request(kv.vsr, {:put, key, value})
  end

  def delete(kv, key) do
    Vsr.client_request(kv.vsr, {:delete, key})
  end

  # internal API for protocol

  use Vsr.StateMachine

  @impl Vsr.StateMachine
  def _new(replica, _), do: %__MODULE__{vsr: replica}

  @impl Vsr.StateMachine
  def _require_linearized?(_, _), do: true

  @impl Vsr.StateMachine
  def _read_only?(_, {:fetch, _}), do: true
  def _read_only?(_, _), do: false

  @impl Vsr.StateMachine
  def _apply_operation(kv, {:fetch, key}) do
    {kv, Map.fetch(kv.map, key)}
  end

  @impl Vsr.StateMachine
  def _apply_operation(kv, {:put, key, value}) do
    {%{kv | map: Map.put(kv.map, key, value)}, :ok}
  end

  @impl Vsr.StateMachine
  def _apply_operation(kv, {:delete, key}) do
    {%{kv | map: Map.delete(kv.map, key)}, :ok}
  end

  @impl Vsr.StateMachine
  def _get_state(kv), do: kv.map

  @impl Vsr.StateMachine
  def _set_state(kv, new_map), do: %{kv | map: new_map}
end
