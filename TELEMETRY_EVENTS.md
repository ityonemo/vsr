# Telemetry Events

VSR emits comprehensive telemetry events following Erlang/Elixir telemetry conventions. All events are prefixed with `[:vsr]`.

## Event Categories

- [Leadership Span](#leadership-span)
- [Protocol Events](#protocol-events)
- [State Changes](#state-changes)
- [View Changes](#view-changes)
- [State Machine Operations](#state-machine-operations)
- [Timer Events](#timer-events)

---

## Leadership Span

Tracks when a node is the primary/leader in the VSR cluster.

### `[:vsr, :leadership, :start]`

Emitted when a node becomes the primary.

**Measurements:**
- `system_time` - System time when leadership started
- `monotonic_time` - Monotonic time when leadership started

**Metadata:**
- `telemetry_span_context` - Unique reference for correlating start/stop events
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

**When emitted:**
- During initial startup if the node is primary for view 0
- After completing a view change when becoming the new primary

### `[:vsr, :leadership, :stop]`

Emitted when a node loses leadership.

**Measurements:**
- `monotonic_time` - Monotonic time when leadership ended
- `duration` - Duration of leadership (currently 0, to be calculated in future versions)

**Metadata:**
- `telemetry_span_context` - Same reference from the corresponding `:start` event
- `node_id` - The node's identifier
- `view_number` - View number when leadership was lost
- `status` - Node status when leadership was lost
- `cluster_size` - Total cluster size
- `op_number` - Operation number when leadership was lost
- `commit_number` - Commit number when leadership was lost

**When emitted:**
- During view changes when transitioning from primary to backup

---

## Protocol Events

### `[:vsr, :protocol, :client_request, :start]`

Emitted when a primary node starts processing a client request.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `operation` - String representation of the operation
- `client_id` - Client identifier (if provided for deduplication)
- `request_id` - Request identifier (if provided for deduplication)
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :protocol, :prepare, :sent]`

Emitted when a primary broadcasts PREPARE messages to replicas.

**Measurements:**
- `count` - Number of replicas the prepare was sent to

**Metadata:**
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :protocol, :prepare, :received]`

Emitted when a backup receives a PREPARE message.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `prepare_view` - View number from the prepare message
- `prepare_op_number` - Operation number from the prepare message
- `sender` - Node ID of the sender (leader)
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :protocol, :prepare_ok, :sent]`

Emitted when a backup sends a PREPARE-OK message to the primary.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `prepare_ok_view` - View number in the prepare-ok
- `prepare_ok_op_number` - Operation number in the prepare-ok
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :protocol, :prepare_ok, :received]`

Emitted when a primary receives a PREPARE-OK message.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `prepare_ok_view` - View number from the prepare-ok
- `prepare_ok_op_number` - Operation number from the prepare-ok
- `sender` - Node ID of the sender (backup)
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :protocol, :commit, :sent]`

Emitted when a primary broadcasts COMMIT messages.

**Measurements:**
- `count` - Number of replicas the commit was sent to

**Metadata:**
- `commit_view` - View number in the commit message
- `commit_number` - Commit number in the commit message
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number (before the new commit)

### `[:vsr, :protocol, :commit, :received]`

Emitted when a backup receives a COMMIT message.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `commit_view` - View number from the commit message
- `commit_number` - Commit number from the commit message
- `sender` - Node ID of the sender (primary)
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number (before applying the new commit)

---

## State Changes

### `[:vsr, :state, :status_change]`

Emitted when a node's status changes (e.g., normal ↔ view_change).

**Measurements:**
- `count` - Always 1

**Metadata:**
- `old_status` - Previous status (`:normal`, `:view_change`, or `:uninitialized`)
- `new_status` - New status (`:normal`, `:view_change`, or `:uninitialized`)
- `node_id` - The node's identifier
- `view_number` - Current view number
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :state, :commit_advance]`

Emitted when the commit number advances after operations are committed.

**Measurements:**
- `operations_committed` - Number of operations committed in this batch

**Metadata:**
- `old_commit_number` - Commit number before the advancement
- `new_commit_number` - Commit number after the advancement
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number

---

## View Changes

### `[:vsr, :view_change, :start]`

Emitted when a view change is initiated.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `old_view` - Previous view number
- `new_view` - New view number being transitioned to
- `old_status` - Status before the view change
- `node_id` - The node's identifier
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :view_change, :vote_received]`

Emitted when a START-VIEW-CHANGE-ACK is received.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `vote_view` - View number from the vote
- `voter` - Node ID of the voter
- `total_votes` - Total number of votes collected for this view
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :view_change, :do_view_change, :received]`

Emitted when a DO-VIEW-CHANGE message is received by the new primary.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `do_view_change_view` - View number from the message
- `sender` - Node ID of the sender
- `sender_op_number` - Operation number from the sender's log
- `sender_commit_number` - Commit number from the sender
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :view_change, :complete]`

Emitted when a view change completes and the node transitions back to normal status.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `old_view` - Previous view number
- `new_view` - New view number after completion
- `new_status` - Status after view change (should be `:normal`)
- `node_id` - The node's identifier
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

---

## State Machine Operations

### `[:vsr, :state_machine, :operation, :start]`

Emitted when a committed operation starts execution on the state machine.

**Measurements:**
- `monotonic_time` - Monotonic time when operation execution started
- `system_time` - System time when operation execution started

**Metadata:**
- `telemetry_span_context` - Unique reference for correlating with `:stop` event
- `extra_op_number` - The operation number being executed
- `operation` - String representation of the operation
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number (latest in log)
- `commit_number` - Current commit number

### `[:vsr, :state_machine, :operation, :stop]`

Emitted when a committed operation completes execution on the state machine.

**Measurements:**
- `monotonic_time` - Monotonic time when operation execution completed
- `duration` - Duration of the operation execution in native time units

**Metadata:**
- `telemetry_span_context` - Same reference from the corresponding `:start` event
- `extra_op_number` - The operation number that was executed
- `operation` - String representation of the operation
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

---

## Timer Events

### `[:vsr, :timer, :heartbeat_received]`

Emitted when a backup receives a heartbeat from the primary.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

### `[:vsr, :timer, :primary_timeout]`

Emitted when a backup detects primary inactivity timeout.

**Measurements:**
- `count` - Always 1

**Metadata:**
- `timeout_ms` - The timeout duration in milliseconds
- `node_id` - The node's identifier
- `view_number` - Current view number
- `status` - Current node status
- `cluster_size` - Total cluster size
- `op_number` - Current operation number
- `commit_number` - Current commit number

---

## Common Metadata

All telemetry events include the following common metadata fields (unless otherwise noted):

- `node_id` - The identifier of the node emitting the event
- `view_number` - Current view number
- `status` - Current node status (`:normal`, `:view_change`, or `:uninitialized`)
- `cluster_size` - Total number of nodes in the cluster
- `op_number` - Current operation number (highest in the log)
- `commit_number` - Current commit number (highest committed operation)

## Usage Example

```elixir
# Attach a handler to track leadership changes
:telemetry.attach(
  "leadership-tracker",
  [:vsr, :leadership, :start],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata}, label: "Leadership started")
  end,
  nil
)

# Attach a handler to track committed operations
:telemetry.attach(
  "commit-tracker",
  [:vsr, :state, :commit_advance],
  fn _event, measurements, metadata, _config ->
    IO.puts("Committed #{measurements.operations_committed} operations, " <>
            "commit_number: #{metadata.old_commit_number} -> #{metadata.new_commit_number}")
  end,
  nil
)

# Use telemetry_metrics for aggregation
Telemetry.Metrics.counter("vsr.protocol.prepare.sent.count")
Telemetry.Metrics.distribution("vsr.state_machine.operation.duration",
  unit: {:native, :millisecond}
)
```

## Integration with Monitoring Systems

These telemetry events are designed to integrate with standard Erlang/Elixir monitoring tools:

- **Telemetry.Metrics** - For aggregating and reporting metrics
- **TelemetryMetricsPrometheus** - For Prometheus integration
- **TelemetryMetricsStatsd** - For StatsD integration
- **Phoenix.LiveDashboard** - For real-time monitoring in Phoenix applications
