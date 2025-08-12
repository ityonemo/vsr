defmodule Maelstrom.KvTest do
  use ExUnit.Case
  alias Maelstrom.Kv

  @moduletag :maelstrom

  describe "_new/2" do
    test "creates new KV state machine with empty state" do
      kv = Kv._new("test_replica", [])

      assert %Kv{state: state} = kv
      assert state == %{}
    end

    test "ignores replica_node_pid parameter" do
      kv1 = Kv._new("node1", [])
      kv2 = Kv._new("node2", custom_opt: :value)

      assert %Kv{state: %{}} = kv1
      assert %Kv{state: %{}} = kv2
    end
  end

  describe "_apply_operation/2" do
    setup do
      kv = Kv._new(self(), [])
      {:ok, kv: kv}
    end

    test "handles read operation on empty state", %{kv: kv} do
      {_updated_kv, {:error, :not_found}} = Kv._apply_operation(kv, ["read", "nonexistent"])
    end

    test "handles write operation", %{kv: kv} do
      {updated_kv, :ok} = Kv._apply_operation(kv, ["write", "key1", "value1"])

      assert updated_kv.state == %{"key1" => "value1"}
    end

    test "handles read operation after write", %{kv: kv} do
      assert {kv_after_write, _} = Kv._apply_operation(kv, ["write", "key1", "value1"])
      assert {updated_kv, {:ok, "value1"}} = Kv._apply_operation(kv_after_write, ["read", "key1"])

      # State unchanged on read
      assert updated_kv == kv_after_write
    end

    test "handles multiple write operations", %{kv: kv} do
      assert {kv1, :ok} = Kv._apply_operation(kv, ["write", "key1", "value1"])
      assert {kv2, :ok} = Kv._apply_operation(kv1, ["write", "key2", "value2"])
      assert {kv3, :ok} = Kv._apply_operation(kv2, ["write", "key1", "updated_value1"])

      assert kv3.state == %{
               "key1" => "updated_value1",
               "key2" => "value2"
             }
    end

    test "handles cas operation with matching value", %{kv: kv} do
      # Write initial value
      {kv_with_value, _} = Kv._apply_operation(kv, ["write", "key1", "old_value"])

      # CAS with matching from value
      {updated_kv, :ok} =
        Kv._apply_operation(kv_with_value, ["cas", "key1", "old_value", "new_value"])

      assert updated_kv.state == %{"key1" => "new_value"}
    end

    test "handles cas operation with non-matching value", %{kv: kv} do
      # Write initial value
      {kv_with_value, _} = Kv._apply_operation(kv, ["write", "key1", "actual_value"])

      # CAS with non-matching from value
      {updated_kv, result} =
        Kv._apply_operation(kv_with_value, ["cas", "key1", "wrong_value", "new_value"])

      assert result == {:error, :precondition_failed}
      # State unchanged
      assert updated_kv.state == %{"key1" => "actual_value"}
    end

    test "handles cas operation on nonexistent key", %{kv: kv} do
      {updated_kv, result} =
        Kv._apply_operation(kv, ["cas", "nonexistent", "anything", "new_value"])

      assert result == {:error, :precondition_failed}
      # State unchanged
      assert updated_kv.state == %{}
    end

    test "nil result on non-existent key", %{kv: kv} do
      # CAS expecting key to not exist
      {updated_kv, result} =
        Kv._apply_operation(kv, ["cas", "new_key", "key_does_not_exist", "new_value"])

      assert result == {:error, :precondition_failed}
      assert updated_kv.state == %{}
    end
  end

  describe "_read_only?/2" do
    setup do
      kv = Kv._new("test", [])
      {:ok, kv: kv}
    end

    test "returns true for read operations", %{kv: kv} do
      assert Kv._read_only?(kv, ["read", "any_key"])
    end

    test "returns false for write operations", %{kv: kv} do
      refute Kv._read_only?(kv, ["write", "key", "value"])
    end

    test "returns false for cas operations", %{kv: kv} do
      refute Kv._read_only?(kv, ["cas", "key", "from", "to"])
    end
  end

  describe "_require_linearized?/2" do
    setup do
      kv = Kv._new("test", [])
      {:ok, kv: kv}
    end

    test "returns true for all operations" do
      kv = Kv._new("test", [])

      assert Kv._require_linearized?(kv, ["read", "key"])
      assert Kv._require_linearized?(kv, ["write", "key", "value"])
      assert Kv._require_linearized?(kv, ["cas", "key", "from", "to"])
    end
  end

  describe "_get_state/1" do
    test "returns the current state map" do
      kv = Kv._new("test", [])
      assert Kv._get_state(kv) == %{}

      {updated_kv, _} = Kv._apply_operation(kv, ["write", "key", "value"])
      assert Kv._get_state(updated_kv) == %{"key" => "value"}
    end
  end

  describe "_set_state/2" do
    test "sets the state to provided value" do
      kv = Kv._new("test", [])
      new_state = %{"preset_key" => "preset_value"}

      updated_kv = Kv._set_state(kv, new_state)

      assert updated_kv.state == new_state
      assert Kv._get_state(updated_kv) == new_state
    end

    test "completely replaces existing state" do
      kv = Kv._new("test", [])
      {kv_with_data, _} = Kv._apply_operation(kv, ["write", "old_key", "old_value"])

      new_state = %{"completely_new_key" => "completely_new_value"}
      updated_kv = Kv._set_state(kv_with_data, new_state)

      assert updated_kv.state == new_state
      assert Map.has_key?(updated_kv.state, "completely_new_key")
      refute Map.has_key?(updated_kv.state, "old_key")
    end
  end

  describe "integration scenarios" do
    test "typical key-value store workflow" do
      kv = Kv._new("test_node", [])

      # Write some initial data
      assert {kv, :ok} = Kv._apply_operation(kv, ["write", "user:1:name", "Alice"])

      assert {kv, :ok} = Kv._apply_operation(kv, ["write", "user:1:email", "alice@example.com"])

      # Read the data back
      assert {kv, {:ok, "Alice"}} = Kv._apply_operation(kv, ["read", "user:1:name"])

      assert {kv, {:ok, "alice@example.com"}} = Kv._apply_operation(kv, ["read", "user:1:email"])

      # Try to read nonexistent key
      assert {kv, {:error, :not_found}} = Kv._apply_operation(kv, ["read", "user:2:name"])

      # Update using CAS
      assert {kv, :ok} = Kv._apply_operation(kv, ["cas", "user:1:name", "Alice", "Alice Smith"])

      # Verify update
      assert {_kv, {:ok, "Alice Smith"}} = Kv._apply_operation(kv, ["read", "user:1:name"])
    end

    test "concurrent modification scenario with CAS" do
      kv = Kv._new("test_node", [])

      # Initial write
      {kv, _} = Kv._apply_operation(kv, ["write", "counter", 0])

      # Simulate two operations - both try to CAS from 0 to 1
      # First one succeeds
      {kv1, :ok} = Kv._apply_operation(kv, ["cas", "counter", 0, 1])

      # Second one fails because counter is now 1, not 0
      {_kv2, {:error, :precondition_failed}} = Kv._apply_operation(kv1, ["cas", "counter", 0, 1])

      # Verify final state from successful operation
      {_final_kv, _result} = Kv._apply_operation(kv1, ["read", "counter"])
    end
  end
end
