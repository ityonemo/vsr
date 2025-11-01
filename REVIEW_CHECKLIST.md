# VSR Review Checklist

This document tracks issues identified in REVIEW-3.GROK.md and REVIEW-3.OPENAI.md with test-driven approaches for fixing each.

## Strategy

- **"Extra X" issues**: Run Maelstrom tests before and after removal to ensure no regression
- **Other issues**: Write failing tests first, then implement fixes
- **Reconfiguration**: Document as known limitation (not implementing)

---

## General

### ✅ TODO-0: Add Reconfiguration Limitation Note to README

**Issue**: No reconfiguration support (GROK-6, mentioned in both reviews)

**Approach**: Documentation only
- Add note to README.md under "Current Limitations" section
- Explain that cluster membership is static (no dynamic add/remove of replicas)
- Reference this as a known limitation from the VSR paper

**Test**: N/A (documentation only)

---

## GROK Issues

### TODO-1: Client Deduplication for Stale Requests (CRITICAL)

**Issue**: When `request_id < cached_request_id`, code sends cached result from higher request_id. Should drop without reply.

**Location**: `client_request_impl/2` in `lib/vsr_server.ex`

**Current behavior**:
```elixir
{:ok, {:cached, cached_request_id, cached_result}}
when request_id < cached_request_id ->
  # WRONG: sends mismatched cached result
  maybe_send_reply(cached_result, from, state)
```

**Expected behavior**: Drop the request without reply (client already received original response)

**Test-Driven Approach**:

1. **Write failing test** (`test/deduplication_test.exs`):
   ```elixir
   test "stale requests (lower request_id) are dropped without reply" do
     # Send request with id=100
     task1 = Task.async(fn -> Vsr.ListKv.write(primary, "key1", "value100") end)
     :ok = Task.await(task1)

     # Send older request with id=50 (should be ignored)
     # Create a mock client_id/request_id mechanism
     result = send_stale_request(primary, client_id: "client1", request_id: 50)

     # Should timeout or return :dropped (not the cached value100)
     assert result == :timeout || result == :dropped
   end
   ```

2. **Run test** - Should fail (currently returns cached result)

3. **Implement fix**:
   ```elixir
   {:ok, {:cached, cached_request_id, _cached_result}}
   when request_id < cached_request_id ->
     # Stale request - drop without reply
     {:noreply, state}
   ```

4. **Verify test passes**

5. **Run Maelstrom** to ensure no regression

---

### TODO-2: Missing Apply After State Transfer

**Issue**: `new_state_impl` doesn't call `apply_committed_operations` after state transfer

**Location**: `new_state_impl/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/state_transfer_test.exs`):
   ```elixir
   test "state transfer applies committed operations to state machine" do
     # Setup: Create 3-node cluster
     # Partition one node (backup1) from others
     # Commit operations on primary and backup2
     # Trigger state transfer to backup1
     # Verify backup1's state machine has all committed operations

     # After NewState, backup1.commit_number should match
     # AND state machine should have applied all operations
     state = VsrServer.dump(backup1)
     assert state.commit_number == expected_commit_number

     # Verify state machine actually has the data
     assert {:ok, "value"} = Vsr.ListKv.read(backup1, "key")
   end
   ```

2. **Run test** - May pass or fail depending on edge cases

3. **Implement fix**:
   ```elixir
   defp new_state_impl(%NewState{} = new_state, state) do
     # ... existing code to update log, op_number, commit_number ...

     # Add: Apply committed operations for consistency
     final_state = apply_committed_operations(updated_state, updated_state.commit_number)

     {:noreply, final_state}
   end
   ```

4. **Verify test passes**

5. **Run Maelstrom**

---

### TODO-3: Remove Extra ViewChangeOk Message

**Issue**: Code sends `ViewChangeOk` after `StartView` - not in VSR spec, adds unnecessary complexity

**Location**: Search for `ViewChangeOk` in codebase

**Approach**: REMOVAL - Run Maelstrom before and after

**Test-Driven Approach**:

1. **Establish baseline**:
   ```bash
   ./maelstrom-kv > results_before_viewchangeok_removal.txt 2>&1
   ```

2. **Remove ViewChangeOk**:
   - Search and remove `ViewChangeOk` struct definition
   - Remove any code that sends `ViewChangeOk`
   - Remove any code that handles `ViewChangeOk`

3. **Run Maelstrom again**:
   ```bash
   ./maelstrom-kv > results_after_viewchangeok_removal.txt 2>&1
   ```

4. **Compare results** - Should be identical or better

5. **If Maelstrom passes**, commit the removal

---

### TODO-4: Remove Extra StartViewChangeAck Message

**Issue**: Uses `StartViewChangeAck` broadcast (not in paper) to collect quorum before `DoViewChange`

**Location**: `start_view_change_ack_impl/2` in `lib/vsr_server.ex`

**Approach**: REMOVAL - Run Maelstrom before and after

**Consideration**: This is more complex than ViewChangeOk because it's part of the view change flow

**Test-Driven Approach**:

1. **Establish baseline**:
   ```bash
   ./maelstrom-kv > results_before_ack_removal.txt 2>&1
   ```

2. **Understand current flow**:
   - `StartViewChange` → broadcast `StartViewChangeAck` → wait for quorum → send `DoViewChange`

3. **Simplify to standard VSR**:
   - `StartViewChange` → count `StartViewChange` messages → send `DoViewChange` at quorum
   - Remove `StartViewChangeAck` message type
   - Modify `start_view_change_impl` to track votes directly

4. **Run Maelstrom**:
   ```bash
   ./maelstrom-kv > results_after_ack_removal.txt 2>&1
   ```

5. **Compare** - Should still pass linearizability

**Alternative**: Keep it if removal breaks Maelstrom (document as implementation choice)

---

## OPENAI Issues

### TODO-5: Log Conflict Detection (CRITICAL SAFETY)

**Issue**: Replica doesn't check for log conflicts when `op_number <= log_length` - can ACK conflicting history

**Location**: `prepare_impl/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/log_conflict_test.exs`):
   ```elixir
   test "replicas detect and reject conflicting log entries" do
     # Setup: 3-node cluster
     # Create network partition: primary1 with backup1, primary2 with backup2
     # Have primary1 commit op1 to position 1
     # Have primary2 commit different op2 to position 1
     # Heal partition
     # Verify: backup doesn't ACK conflicting entry
     # Verify: GetState is requested for conflict resolution

     # Monitor for GetState message being sent
     telemetry_ref = TelemetryHelper.expect([:protocol, :get_state, :sent])

     # Trigger conflict scenario
     # ...

     TelemetryHelper.wait_for(telemetry_ref)
     TelemetryHelper.detach(telemetry_ref)
   end
   ```

2. **Run test** - Should fail (currently ACKs conflicting entry)

3. **Implement fix**:
   ```elixir
   prepare.op_number <= log_length ->
     case state.module.log_fetch(state.log, prepare.op_number) do
       {:ok, %LogEntry{view: v, operation: op}}
       when v == prepare.view and op == prepare.operation ->
         # Exact match - send ACK
         send_prepare_ok(state, prepare)
         {:noreply, state}

       _ ->
         # Conflict - request state transfer
         send_to(state, prepare.leader_id, %GetState{
           view: prepare.view,
           op_number: state.op_number,
           sender: state.node_id
         })
         {:noreply, state}
     end
   ```

4. **Verify test passes**

5. **Run Maelstrom** - Critical to verify linearizability maintained

---

### TODO-6: Deterministic Primary Election

**Issue**: Using `Enum.sort([node_id | replicas])` with potentially non-stable ordering (PIDs)

**Location**: `primary_for_view/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/primary_election_test.exs`):
   ```elixir
   test "all replicas agree on primary for each view" do
     # Create 3 replicas with known node_ids
     node_ids = [:n0, :n1, :n2]
     replicas = start_cluster(node_ids)

     # Check each replica's view of who's primary for views 0-10
     for view <- 0..10 do
       primaries = Enum.map(replicas, fn replica ->
         state = VsrServer.dump(replica)
         compute_primary_for_view(view, state)
       end)

       # All should agree
       assert Enum.uniq(primaries) |> length() == 1

       # Primary should be deterministic based on view
       expected = Enum.at(Enum.sort(node_ids), rem(view, 3))
       assert List.first(primaries) == expected
     end
   end
   ```

2. **Run test** - Should pass if using atoms, may fail with PIDs

3. **Implement fix**:
   ```elixir
   # Add members field to state struct
   defstruct [..., members: []]

   # In do_set_cluster
   sorted_members = Enum.sort([node_id | MapSet.to_list(replicas_set)])
   %{state | members: sorted_members, ...}

   # In primary_for_view
   defp primary_for_view(view_number, state) do
     Enum.at(state.members, rem(view_number, length(state.members)))
   end
   ```

4. **Verify test passes**

5. **Run Maelstrom**

---

### TODO-7: Consistent Quorum Math

**Issue**: Commit uses `MapSet.size(state.replicas) + 1` while other places use `cluster_size`

**Location**: `maybe_commit_operation/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/quorum_test.exs`):
   ```elixir
   test "quorum calculations use cluster_size consistently" do
     # Create cluster with explicit cluster_size=5 but only 3 replicas started
     {:ok, replica1} = start_replica(cluster_size: 5, node_id: :n1, replicas: [:n2, :n3])

     state = VsrServer.dump(replica1)

     # Verify quorum is calculated from cluster_size (5), not connected replicas (3)
     # This means we need 3 ACKs (majority of 5), not 2 (majority of 3)
     quorum_size = div(state.cluster_size, 2) + 1
     assert quorum_size == 3

     # Test that commits require proper quorum
     # Should NOT commit with only 2 ACKs when cluster_size=5
   end
   ```

2. **Run test** - May fail if using connected_replicas

3. **Implement fix**:
   ```elixir
   defp maybe_commit_operation(state, op_number) do
     quorum_size = div(state.cluster_size, 2) + 1  # Use cluster_size consistently
     ack_count = Map.get(state.prepare_ok_count, {state.view_number, op_number}, 0)

     if ack_count >= quorum_size do
       # commit logic
     end
   end
   ```

4. **Update `has_quorum?/1`** similarly

5. **Verify test passes**

6. **Run Maelstrom**

---

### TODO-8: Use Leader's View in GetState

**Issue**: When requesting state transfer, uses `state.view_number` instead of `prepare.view`

**Location**: `prepare_impl/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/state_transfer_test.exs`):
   ```elixir
   test "GetState request uses leader's view number" do
     # Setup: Create scenario where backup is behind on view
     # Backup is in view 0, receives Prepare from view 2
     # Backup should request GetState with view=2, not view=0

     # Intercept GetState message
     telemetry_ref = TelemetryHelper.expect([:protocol, :get_state, :sent])

     # Trigger state transfer scenario
     # ...

     metadata = TelemetryHelper.wait_for(telemetry_ref)
     assert metadata.get_state_view == 2  # Leader's view

     TelemetryHelper.detach(telemetry_ref)
   end
   ```

2. **Run test** - Should fail (currently uses state.view_number)

3. **Implement fix**:
   ```elixir
   # In gap detection
   send_to(state, primary_node, %GetState{
     view: prepare.view,  # Use prepare.view, not state.view_number
     op_number: state.op_number,
     sender: state.node_id
   })
   ```

4. **Verify test passes**

5. **Run Maelstrom**

---

### TODO-9: Clear Per-View Counters on View Adoption

**Issue**: `prepare_ok_count` and other view-specific state not cleared on all view adoptions

**Location**: Multiple places in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/view_change_test.exs`):
   ```elixir
   test "per-view counters are cleared on view adoption" do
     # Create scenario where view changes
     state_before = VsrServer.dump(replica1)

     # Populate some prepare_ok_count for old view
     # Trigger view change

     state_after = VsrServer.dump(replica1)

     # Verify old view counters are cleared
     old_view_keys = Enum.filter(
       Map.keys(state_before.prepare_ok_count),
       fn {view, _op} -> view == state_before.view_number end
     )

     for key <- old_view_keys do
       refute Map.has_key?(state_after.prepare_ok_count, key)
     end
   end
   ```

2. **Run test** - May fail if counters aren't cleared

3. **Implement fix**: Add counter clearing to:
   - `new_state_impl/2` (after state transfer)
   - `prepare_impl/2` (when adopting higher view)
   - `start_view_impl/2` (already done, verify)

4. **Verify test passes**

5. **Run Maelstrom**

---

### TODO-10: Improve Duplicate Request Handling

**Issue**: Duplicate requests while original is processing get no reply - clients timeout

**Location**: `client_request_impl/2` in `lib/vsr_server.ex`

**Test-Driven Approach**:

1. **Write test** (`test/deduplication_test.exs`):
   ```elixir
   test "duplicate requests during processing get same result" do
     # Send request with id=100 (blocks on slow operation)
     task1 = Task.async(fn ->
       slow_write(primary, "key1", "value1", client_id: "c1", request_id: 100)
     end)

     # While first is processing, send duplicate
     task2 = Task.async(fn ->
       slow_write(primary, "key1", "value1", client_id: "c1", request_id: 100)
     end)

     # Both should get :ok
     assert :ok = Task.await(task1, 5000)
     assert :ok = Task.await(task2, 5000)  # Should not timeout
   end
   ```

2. **Run test** - Should fail (task2 times out)

3. **Implement fix**: Add waiter list
   ```elixir
   # Change client_table entry format
   {:processing, request_id, [from1, from2, ...]}  # List of waiting froms

   # On duplicate during processing
   {:ok, {:processing, ^request_id, waiters}} ->
     # Add to waiter list
     updated_entry = {:processing, request_id, [from | waiters]}
     updated_table = Map.put(state.client_table, client_id, updated_entry)
     {:noreply, %{state | client_table: updated_table}}

   # On commit, reply to all waiters
   for from <- waiters do
     state.module.send_reply(from, result, state.inner)
   end
   ```

4. **Verify test passes**

5. **Run Maelstrom**

---

## Test Execution Order

1. **Document reconfiguration limitation** (TODO-0)
2. **Critical safety fixes first**:
   - TODO-1: Client deduplication (GROK)
   - TODO-5: Log conflict detection (OPENAI)
   - TODO-6: Deterministic primary (OPENAI)
3. **Consistency fixes**:
   - TODO-7: Quorum math (OPENAI)
   - TODO-2: Apply after state transfer (GROK)
   - TODO-8: Leader's view in GetState (OPENAI)
   - TODO-9: Clear counters (OPENAI)
4. **Quality improvements**:
   - TODO-10: Duplicate handling (OPENAI)
5. **Simplifications** (run Maelstrom before/after):
   - TODO-3: Remove ViewChangeOk (GROK)
   - TODO-4: Remove StartViewChangeAck (GROK)

---

## Success Criteria

- All new tests pass
- All existing 106 tests still pass
- Maelstrom `lin-kv` workload passes with minimal timeouts
- No linearizability violations reported by Maelstrom

---

## Notes

- Reconfiguration is documented as a known limitation (not implemented)
- Each fix should be committed separately with tests
- Maelstrom should be run after each major change
- "Extra X" removals are lower priority - only remove if Maelstrom still passes
