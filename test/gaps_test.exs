defmodule GapsTest do
  use ExUnit.Case

  setup do
    {:ok, replica1} = start_replica(1)
    {:ok, replica2} = start_replica(2)

    # Connect replicas
    :ok = Vsr.connect(replica1, replica2)
    :ok = Vsr.connect(replica2, replica1)

    {:ok, primary: replica1, backup: replica2}
  end

  defp start_replica(_id) do
    {:ok, pid} =
      GenServer.start_link(Vsr,
        log: [],
        state_machine: VsrKv,
        cluster_size: 2
      )

    {:ok, pid}
  end

  test "should reject prepare messages with gaps in operation numbers", %{
    primary: primary,
    backup: backup
  } do
    # First, do a normal operation to establish op_number 1
    VsrKv.put(primary, "key1", "value1")
    Process.sleep(50)

    backup_state = Vsr.dump(backup)
    initial_log_length = length(backup_state.log)

    # Now simulate sending a PREPARE message with a gap (op_number 3 when we expect 2)
    # We need to send this directly to test the gap validation
    gap_prepare = %Vsr.Message.Prepare{
      view: backup_state.view_number,
      # This creates a gap
      op_number: initial_log_length + 2,
      operation: {:put, "gap_key", "gap_value"},
      commit_number: backup_state.commit_number,
      from: self()
    }

    # Send the prepare message with gap
    GenServer.cast(backup, {:vsr, gap_prepare})
    Process.sleep(50)

    # Check that the backup didn't accept the operation with gap
    final_backup_state = Vsr.dump(backup)

    # Log should not have grown because the gap should be rejected
    final_log_length = length(final_backup_state.log)

    # This test should fail initially because gap validation is missing
    assert final_log_length == initial_log_length,
           "Backup should reject operations with gaps, but log grew from #{initial_log_length} to #{final_log_length}"

    # Operation should not be in the log
    log_ops = Enum.map(final_backup_state.log, & &1.operation)
    refute {:put, "gap_key", "gap_value"} in log_ops, "Gap operation should not be in log"
  end

  test "should trigger state transfer when gap is detected", %{primary: primary, backup: backup} do
    # Do initial operation
    VsrKv.put(primary, "initial", "value")
    Process.sleep(50)

    # Create a gap by sending prepare with much higher op_number
    backup_state = Vsr.dump(backup)

    # Send prepare with big gap
    gap_prepare = %Vsr.Message.Prepare{
      view: backup_state.view_number,
      # Big gap
      op_number: backup_state.op_number + 5,
      operation: {:put, "far_key", "far_value"},
      commit_number: backup_state.commit_number,
      from: self()
    }

    # Mock what should happen: backup should send GET-STATE to primary
    # Currently this doesn't happen, so test will document missing feature

    GenServer.cast(backup, {:vsr, gap_prepare})
    Process.sleep(50)

    final_backup_state = Vsr.dump(backup)

    # Gap operation should not be accepted
    log_ops = Enum.map(final_backup_state.log, & &1.operation)

    refute {:put, "far_key", "far_value"} in log_ops,
           "Gap operation should not be in log without state transfer"

    # In a correct implementation, backup would request state transfer
    # For now, we just test that the gap isn't accepted
    assert final_backup_state.op_number <= backup_state.op_number + 1,
           "op_number should not jump by more than 1 without proper state transfer"
  end
end
