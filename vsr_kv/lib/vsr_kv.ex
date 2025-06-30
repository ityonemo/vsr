defmodule VsrKv do
  @moduledoc """
  KV store using VSR for distributed consistency.
  """

  @enforce_keys [:vsr]
  defstruct @enforce_keys ++ [map: %{}]

  use Vsr.StateMachine

  def new(vsr, _options), do: %__MODULE__{vsr: vsr}

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

  def require_linearized?(_, _), do: true

  def read_only?(_, _), do: true

  def apply_operation(kv, {:fetch, key}) do
    {kv, Map.fetch(kv.map, key)}
  end

  def apply_operation(kv, {:put, key, value}) do
    {%{kv | map: Map.put(kv.map, key, value)}, :ok}
  end

  def apply_operation(kv, {:delete, key}) do
    {%{kv | map: Map.delete(kv.map, key)}, :ok}
  end

  def get_state(_), do: raise("not implemented")

  def set_state(_, _), do: raise("not implemented")
end
