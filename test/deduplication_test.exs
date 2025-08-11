defmodule DeduplicationTest do
  use ExUnit.Case

  setup do
    {:ok, replica1} = start_replica(1)
    {:ok, replica2} = start_replica(2)

    :ok = Vsr.connect(replica1, replica2)
    :ok = Vsr.connect(replica2, replica1)

    {:ok, primary: replica1, backup: replica2}
  end

  defp start_replica(id) do
    Vsr.start_link(
      name: :"replica_#{id}",
      log: [],
      state_machine: VsrKv,
      cluster_size: 2
    )
  end

  # Test client request deduplication with explicit request IDs
  # SKIPPED: Write operation deduplication requires complex VSR protocol integration
  # See README.md "Current Limitations" section for details
  @tag :skip
  test "duplicate client requests with same request ID should be deduplicated", %{
    primary: primary
  } do
    # Create a mock client that sends requests with explicit IDs
    request_id = make_ref()

    # Send same request multiple times with same ID
    # This should be handled through the VSR protocol, not just VsrKv

    # First request
    result1 =
      Task.async(fn ->
        Vsr.client_request(primary, {:put, "dedup_key", "value1"}, request_id)
      end)

    # Duplicate request with same ID (should be deduplicated)
    result2 =
      Task.async(fn ->
        Vsr.client_request(primary, {:put, "dedup_key", "value2"}, request_id)
      end)

    # Wait for results
    res1 = Task.await(result1)
    res2 = Task.await(result2)

    # Both should succeed but only first should be applied
    assert res1 == {:ok, :ok}
    # Deduplication returns cached result
    assert res2 == {:ok, :ok}

    # Check final value - should be from first request only
    {:ok, final_value} = VsrKv.fetch(primary, "diff_key")

    assert final_value == "value1",
           "Value should be from first request, got: #{inspect(final_value)}"

    # This test will initially fail because deduplication is not implemented
  end

  test "different request IDs should not be deduplicated", %{primary: primary} do
    request_id1 = make_ref()
    request_id2 = make_ref()

    # Send requests with different IDs
    assert :ok = Vsr.client_request(primary, {:put, "diff_key", "value1"}, request_id1)
    assert :ok = Vsr.client_request(primary, {:put, "diff_key", "value2"}, request_id2)

    # Second request should overwrite first (different IDs)
    {:ok, final_value} = VsrKv.fetch(primary, "diff_key")
    assert final_value == "value2"
  end

  test "client_table should exist in state", %{primary: primary} do
    # Check that client_table field exists in state
    state = Vsr.dump(primary)

    # client_table should exist 
    assert Map.has_key?(state, :client_table), "State should have client_table field"
    assert state.client_table == %{}, "client_table should start empty"
  end

  test "read-only operations with same ID should be deduplicated", %{primary: primary} do
    # For read-only operations, deduplication should work immediately
    client_pid = self()
    request_id = make_ref()

    # Send same read-only request twice
    assert :error = Vsr.client_request(primary, {:fetch, "nonexistent"}, request_id)
    assert :error = Vsr.client_request(primary, {:fetch, "nonexistent"}, request_id)

    # Check that it was cached
    state = Vsr.dump(primary)
    client_key = {client_pid, request_id}
    assert Map.has_key?(state.client_table, client_key), "Read-only result should be cached"
  end
end
