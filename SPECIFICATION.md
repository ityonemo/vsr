# Viewstamped Replication (VSR) Specification

## Overview

Viewstamped Replication is a consensus algorithm for building fault-tolerant distributed systems. VSR ensures that a collection of replicas agree on a sequence of operations, even in the presence of failures.

## Core Concepts

### Roles
- **Primary**: The current leader that processes client requests and coordinates replication
- **Backup**: Followers that maintain replicated state and can become primary
- **Client**: External entities that submit operations to the system

### View
A **view** is a configuration period with a designated primary. Views are numbered sequentially starting from 0.
The primary for view `v` is determined by: `primary = configuration[v % length(configuration)]`

### Operation Log
Each replica maintains an ordered log of operations. Operations are identified by:
- **View number**: The view in which the operation was proposed
- **Operation number**: Sequential number within the view
- **Operation**: The actual operation to execute
- **Sender ID**: The replica that proposed the operation

### Replica State
Each replica maintains:
```elixir
%Vsr.Replica{
  replica_id: integer(),           # Unique identifier for this replica
  view_number: integer(),          # Current view number
  status: :normal | :view_change | :recovering,  # Current operational status
  op_number: integer(),            # Highest operation number seen
  commit_number: integer(),        # Highest committed operation number
  log: [log_entry()],             # Ordered list of operations
  configuration: [integer()],      # List of all replica IDs
  primary: integer(),             # Current primary replica ID
  store: term(),                  # State machine storage
  client_table: term(),           # Client request deduplication
  prepare_ok_count: %{integer() => integer()},  # Count of prepare-ok per operation
  view_change_votes: %{integer() => boolean()}, # Votes for view change
  last_normal_view: integer()     # Last view in normal operation
}
```

## Algorithm Phases

### 1. Normal Operation Phase

#### Client Request Processing

**Message**: Client sends operation to primary
**Internal State Changes**:
1. **Primary receives client request**:
   - Checks if request already processed (client_table lookup)
   - If duplicate: return cached result
   - If new: increment `op_number`
   - Create log entry: `{view_number, op_number, operation, replica_id}`
   - Append to `log`
   - Initialize `prepare_ok_count[op_number] = 1` (self-vote)

#### Prepare Phase

**Message**: Primary sends `PREPARE(view, op-num, operation, commit-num)` to all backups
**Internal State Changes**:
1. **Backup receives PREPARE**:
   - Validates `view >= view_number`
   - If `op_number > length(log)`: append operation to `log`
   - Update `op_number = max(op_number, received_op_number)`
   - Send `PREPARE-OK(view, op-num, replica-id)` to primary

2. **Primary receives PREPARE-OK**:
   - Increment `prepare_ok_count[op_number]`
   - If `prepare_ok_count[op_number] > majority`:
     - Update `commit_number = max(commit_number, op_number)`
     - Apply all operations where `log_op_number <= commit_number` to state machine
     - Send `COMMIT(view, commit-num)` to all backups

#### Commit Phase

**Message**: Primary sends `COMMIT(view, commit-num)` to backups
**Internal State Changes**:
1. **Backup receives COMMIT**:
   - Validates `view == view_number`
   - If `commit_number < received_commit_number`:
     - Update `commit_number = received_commit_number`
     - Apply all operations where `log_op_number <= commit_number` to state machine
     - Update client_table with results

### 2. View Change Phase

#### Detecting Primary Failure

**Trigger**: Backup detects primary timeout or failure
**Internal State Changes**:
1. **Backup initiates view change**:
   - Increment `view_number`
   - Set `status = :view_change`
   - Calculate new `primary = configuration[view_number % length(configuration)]`
   - Initialize `view_change_votes[replica_id] = true`
   - Send `START-VIEW-CHANGE(view, replica-id)` to all replicas

#### Start View Change Phase

**Message**: `START-VIEW-CHANGE(view, replica-id)` sent to all replicas
**Internal State Changes**:
1. **Replica receives START-VIEW-CHANGE**:
   - If `view > view_number`:
     - Update `view_number = view`
     - Set `status = :view_change` 
     - Update `primary = configuration[view % length(configuration)]`
     - Set `view_change_votes[sender_id] = true`
     - Send `START-VIEW-CHANGE-ACK(view, replica-id)` to sender
   - If `count(view_change_votes) > majority`:
     - Send `DO-VIEW-CHANGE(view, log, last_normal_view, op_number, commit_number, replica-id)` to new primary

#### Do View Change Phase

**Message**: `DO-VIEW-CHANGE(view, log, last_normal_view, op_number, commit_number, replica-id)` sent to new primary
**Internal State Changes**:
1. **New primary receives DO-VIEW-CHANGE**:
   - If `view >= view_number`:
     - Merge received log with local log (take highest op_number entries)
     - Update `view_number = view`
     - Update `log = merged_log`
     - Update `op_number = max(op_number, received_op_number)`
     - Update `commit_number = max(commit_number, received_commit_number)`
     - Set `status = :normal`
     - Send `START-VIEW(view, log, op_number, commit_number)` to all other replicas

#### Start View Phase

**Message**: `START-VIEW(view, log, op_number, commit_number)` sent from new primary
**Internal State Changes**:
1. **Replica receives START-VIEW**:
   - If `view >= view_number`:
     - Update `view_number = view`
     - Replace `log = received_log`
     - Update `op_number = received_op_number`
     - Update `commit_number = received_commit_number`
     - Set `status = :normal`
     - Update `primary = configuration[view % length(configuration)]`
     - Apply all committed operations to state machine
     - Send `VIEW-CHANGE-OK(view, replica-id)` to new primary

#### View Change Completion

**Message**: `VIEW-CHANGE-OK(view, replica-id)` sent to new primary
**Internal State Changes**:
1. **New primary receives VIEW-CHANGE-OK**:
   - Set `view_change_votes[sender_id] = true`
   - If `count(view_change_votes) > majority`:
     - Clear `view_change_votes = %{}`
     - Set `last_normal_view = view`
     - Resume normal operation

### 3. State Transfer Phase

#### Requesting State

**Message**: Lagging replica sends `GET-STATE(view, op_number, replica-id)` to primary
**Internal State Changes**:
1. **Lagging replica initiates**:
   - Detect it's behind (lower op_number or view_number)
   - Send `GET-STATE(view_number, op_number, replica_id)` to primary

2. **Primary receives GET-STATE**:
   - Package current state: `{view_number, log, op_number, commit_number}`
   - Send `NEW-STATE(view, log, op_number, commit_number)` to requester

#### Receiving State

**Message**: `NEW-STATE(view, log, op_number, commit_number)` sent from primary
**Internal State Changes**:
1. **Lagging replica receives NEW-STATE**:
   - If `view >= view_number OR op_number > local_op_number`:
     - Update `view_number = received_view`
     - Replace `log = received_log`
     - Update `op_number = received_op_number`
     - Update `commit_number = received_commit_number`
     - Set `status = :normal`
     - Apply all committed operations to state machine
     - Resume normal operation

## Message Types

### Normal Operation Messages
- `PREPARE(view, op-num, operation, commit-num)`
- `PREPARE-OK(view, op-num, replica-id)`
- `COMMIT(view, commit-num)`

### View Change Messages
- `START-VIEW-CHANGE(view, replica-id)`
- `START-VIEW-CHANGE-ACK(view, replica-id)`
- `DO-VIEW-CHANGE(view, log, last_normal_view, op_number, commit_number, replica-id)`
- `START-VIEW(view, log, op_number, commit_number)`
- `VIEW-CHANGE-OK(view, replica-id)`

### State Transfer Messages
- `GET-STATE(view, op_number, replica-id)`
- `NEW-STATE(view, log, op_number, commit_number)`

### Client Messages
- `REQUEST(operation, client-id, request-id)`
- `REPLY(request-id, result)`

## Safety Properties

1. **Agreement**: All replicas execute the same operations in the same order
2. **Integrity**: A replica executes an operation at most once
3. **Validity**: Only proposed operations are executed

## Liveness Properties

1. **Termination**: Every operation eventually executes (assuming eventual synchrony)
2. **View Change**: System eventually selects a new primary when current primary fails

## State Machine Integration

The VSR protocol is agnostic to the underlying state machine. Operations are applied in order to maintain consistency:

```elixir
defprotocol Vsr.StateMachine do
  @doc "Apply an operation to the state machine"
  def apply_operation(state_machine, operation)
  
  @doc "Get current state for state transfer"
  def get_state(state_machine)
  
  @doc "Set state during state transfer"
  def set_state(state_machine, state)
end
```

## Log Storage Abstraction

The operation log can be implemented with different backends:

```elixir
defprotocol Vsr.Log do
  @doc "Append operation to log"
  def append(log, view, op_number, operation, sender_id)
  
  @doc "Get operation at index"
  def get(log, index)
  
  @doc "Get all operations"
  def get_all(log)
  
  @doc "Get operations from index onwards"
  def get_from(log, index)
  
  @doc "Get log length"
  def length(log)
end
```

## Correctness Conditions

1. **View Synchronization**: All replicas agree on current view
2. **Log Consistency**: Replica logs are consistent up to commit point
3. **Primary Completeness**: New primary has all committed operations
4. **Monotonicity**: View numbers and operation numbers never decrease

This specification provides the foundation for implementing a correct and efficient VSR-based distributed system with clear understanding of internal state transitions.
