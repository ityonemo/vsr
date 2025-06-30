defmodule VsrKv do
  @moduledoc """
  KV store using VSR for distributed consistency.
  """

  @enforce_keys [:vsr]
  defstruct @enforce_keys ++ [map: %{}]

  use Vsr.StateMachine

  # PUBLIC API

  def start_link(vsr_options) do
    Vsr.start_link(__MODULE__, vsr_options ++ [state_machine: {__MODULE__, []}])
  end

  def fetch(replica, key) do
    Vsr.client_request(replica, {:fetch, key})
  end

  def fetch!(replica, key) do
    case fetch(replica, key) do
      {:ok, value} -> value
      :error -> raise KeyError, term: replica, key: key
    end
  end

  def get(replica, key, default \\ nil) do
    case fetch(replica, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def put(replica, key, value) do
    Vsr.client_request(replica, {:put, key, value})
  end

  def delete(replica, key) do
    Vsr.client_request(replica, {:delete, key})
  end

  # internal API

  @impl Vsr.StateMachine
  def new(vsr, _options), do: %__MODULE__{vsr: vsr}

  @impl Vsr.StateMachine
  def require_linearized?(_, _), do: true

  @impl Vsr.StateMachine
  def read_only?(_, _), do: true

  @impl Vsr.StateMachine
  def apply_operation(kv, {:fetch, key}) do
    {kv, Map.fetch(kv.map, key)}
  end

  def apply_operation(kv, {:put, key, value}) do
    {%{kv | map: Map.put(kv.map, key, value)}, :ok}
  end

  def apply_operation(kv, {:delete, key}) do
    {%{kv | map: Map.delete(kv.map, key)}, :ok}
  end

  @impl Vsr.StateMachine
  def get_state(_), do: raise("not implemented")

  def set_state(_, _), do: raise("not implemented")
end
