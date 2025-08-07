defmodule ViewChangeTest do
  use ExUnit.Case
  
  setup do
    {:ok, replica1} = start_replica(1)
    {:ok, replica2} = start_replica(2)
    {:ok, replica3} = start_replica(3)

    # Connect replicas
    :ok = Vsr.connect(replica1, replica2)
    :ok = Vsr.connect(replica1, replica3)
    :ok = Vsr.connect(replica2, replica1)
    :ok = Vsr.connect(replica2, replica3)
    :ok = Vsr.connect(replica3, replica1)
    :ok = Vsr.connect(replica3, replica2)

    {:ok, replicas: [replica1, replica2, replica3]}
  end

  defp start_replica(_id) do
    {:ok, pid} = GenServer.start_link(Vsr, [
      log: [],
      state_machine: VsrKv,
      cluster_size: 3,
      heartbeat_interval: 50,      # Fast for testing
      primary_inactivity_timeout: 150  # Fast timeout
    ])
    {:ok, pid}
  end

  test "view change should complete and elect new primary", %{replicas: [replica1, replica2, replica3]} do
    # Identify current primary (should be first in sorted order)
    all_replicas = [replica1, replica2, replica3]
    sorted_replicas = Enum.sort(all_replicas)
    initial_primary = hd(sorted_replicas)
    
    initial_states = Enum.map(all_replicas, &Vsr.dump/1)
    initial_view = hd(initial_states).view_number
    
    # Trigger view change from a backup
    backup = if initial_primary == replica1, do: replica2, else: replica1
    :ok = Vsr.start_view_change(backup)
    
    # Wait for view change to complete
    Process.sleep(100)
    
    final_states = Enum.map(all_replicas, &Vsr.dump/1)
    
    # All replicas should be in same view
    final_views = Enum.map(final_states, & &1.view_number)
    assert Enum.all?(final_views, fn v -> v == hd(final_views) end), "All replicas should have same view number"
    
    # View should have incremented
    final_view = hd(final_views)
    assert final_view > initial_view, "View number should increment"
    
    # All replicas should be in normal status
    final_statuses = Enum.map(final_states, & &1.status)
    assert Enum.all?(final_statuses, fn s -> s == :normal end), "All replicas should return to normal status"
  end

  test "operations should work after view change", %{replicas: [replica1, replica2, replica3]} do
    # Do initial operation
    VsrKv.put(replica1, "before_view_change", "value1")
    
    # Trigger view change
    :ok = Vsr.start_view_change(replica2)
    Process.sleep(150)  # Wait for view change
    
    # Operations should still work after view change
    result = VsrKv.put(replica1, "after_view_change", "value2")
    assert result == :ok
    
    # Both values should be readable
    assert VsrKv.get(replica1, "before_view_change") == "value1"
    assert VsrKv.get(replica1, "after_view_change") == "value2"
  end

  test "view change should preserve committed operations", %{replicas: [replica1, replica2, replica3]} do
    # Do several operations to build up log
    VsrKv.put(replica1, "key1", "value1")
    VsrKv.put(replica1, "key2", "value2")
    VsrKv.put(replica1, "key3", "value3")
    
    Process.sleep(50)  # Let operations commit
    
    # Get states before view change
    states_before = Enum.map([replica1, replica2, replica3], &Vsr.dump/1)
    commit_numbers_before = Enum.map(states_before, & &1.commit_number)
    
    # Trigger view change
    :ok = Vsr.start_view_change(replica3)
    Process.sleep(150)
    
    # Check that committed operations are preserved
    assert VsrKv.get(replica1, "key1") == "value1"
    assert VsrKv.get(replica2, "key2") == "value2"
    assert VsrKv.get(replica3, "key3") == "value3"
    
    # Check that commit numbers are preserved or increased
    states_after = Enum.map([replica1, replica2, replica3], &Vsr.dump/1)
    commit_numbers_after = Enum.map(states_after, & &1.commit_number)
    
    Enum.zip(commit_numbers_before, commit_numbers_after)
    |> Enum.each(fn {before, after_change} ->
      assert after_change >= before, "Commit numbers should not decrease during view change"
    end)
  end

  test "multiple concurrent view changes should converge", %{replicas: [replica1, replica2, replica3]} do
    # Multiple replicas trigger view change simultaneously
    :ok = Vsr.start_view_change(replica1)
    :ok = Vsr.start_view_change(replica2)
    :ok = Vsr.start_view_change(replica3)
    
    # Wait for convergence
    Process.sleep(200)
    
    # All should converge to same view
    final_states = Enum.map([replica1, replica2, replica3], &Vsr.dump/1)
    final_views = Enum.map(final_states, & &1.view_number)
    
    assert Enum.all?(final_views, fn v -> v == hd(final_views) end), 
      "Concurrent view changes should converge to same view"
    
    # All should be in normal status
    final_statuses = Enum.map(final_states, & &1.status)
    assert Enum.all?(final_statuses, fn s -> s == :normal end),
      "All replicas should be in normal status after convergence"
  end

  test "new primary should be able to accept operations immediately", %{replicas: [replica1, replica2, replica3]} do
    initial_view = Vsr.dump(replica1).view_number
    
    # Trigger view change
    :ok = Vsr.start_view_change(replica2)
    Process.sleep(150)
    
    # Determine new primary
    final_states = Enum.map([replica1, replica2, replica3], &Vsr.dump/1)
    final_view = hd(final_states).view_number
    assert final_view > initial_view, "View should have changed"
    
    # New primary should accept operations immediately
    result = VsrKv.put(replica1, "new_primary_test", "works")
    assert result == :ok
    
    # Operation should be replicated
    Process.sleep(50)
    assert VsrKv.get(replica2, "new_primary_test") == "works"
    assert VsrKv.get(replica3, "new_primary_test") == "works"
  end
end