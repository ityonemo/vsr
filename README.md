# Vsr

**Viewstamped Replication for Elixir**

A distributed consensus system implementing the Viewstamped Replication (VSR) protocol, providing fault-tolerant state machine replication with automatic failure recovery.

## Features

✅ **Core VSR Protocol**
- Primary-backup replication with view changes
- Automatic primary failure detection and recovery
- Log-based operation ordering and consistency
- Quorum-based consensus decisions

✅ **Implemented Components**
- Sequential operation validation with gap detection
- Heartbeat mechanism for failure detection
- Automatic view change triggering on primary timeout
- Memory management (cleanup of committed operation metadata)
- Pluggable state machines, log storage, and communication layers

✅ **Observability**
- Comprehensive telemetry instrumentation following Erlang/Elixir conventions
- Leadership span tracking (when nodes are primary/leader)
- Protocol event tracking (prepare, commit, view changes)
- State machine operation spans with duration metrics
- Timer and heartbeat event tracking
- See [TELEMETRY_EVENTS.md](TELEMETRY_EVENTS.md) for complete event documentation

## Current Limitations

⚠️ **Client Request Deduplication**: Currently only implemented for read-only operations. Write operations may be processed multiple times if clients retry requests due to network timeouts. This does not affect VSR protocol correctness or safety properties, but may impact user experience.

- **Workaround**: Implement request deduplication at the application layer using unique request IDs
- **Future Work**: Full write operation deduplication requires propagating client identifiers through the entire VSR protocol

⚠️ **No Reconfiguration Support**: The implementation assumes a static cluster with fixed membership. Dynamic addition or removal of replicas (reconfiguration protocol from the VSR paper) is not currently supported.

- **Limitation**: Cluster size and membership must be determined at startup and cannot be changed during operation
- **Workaround**: Plan cluster capacity ahead of time to accommodate expected load
- **Future Work**: Implement the reconfiguration protocol described in "Viewstamped Replication Revisited"

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `vsr` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:vsr, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Start a VSR replica with a key-value state machine
{:ok, replica} = Vsr.start_link(
  log: [],
  state_machine: VsrKv,
  cluster_size: 3
)

# Perform operations
VsrKv.put(replica, "key", "value")
result = VsrKv.get(replica, "key")  # Returns "value"
```

## Testing

### Unit Tests

```bash
mix test
```

**Test Status**: 106/106 tests passing

### Jepsen Maelstrom Testing

VSR includes integration with [Jepsen Maelstrom](https://github.com/jepsen-io/maelstrom), a workbench for learning distributed systems by writing your own implementations and testing them against fault injection.

#### Download Maelstrom

1. Download the latest Maelstrom release:
   ```bash
   wget https://github.com/jepsen-io/maelstrom/releases/download/v0.2.3/maelstrom.tar.bz2
   tar -xjf maelstrom.tar.bz2
   ```

2. Or use the provided script to download and extract:
   ```bash
   curl -L https://github.com/jepsen-io/maelstrom/releases/download/v0.2.3/maelstrom.tar.bz2 | tar -xj
   ```

#### Run Maelstrom Tests

The repository includes a convenience script for running linearizable key-value tests:

```bash
./maelstrom-kv
```

This runs the `lin-kv` workload which tests:
- Linearizable key-value operations (read, write, cas)
- Fault tolerance with network partitions
- Consistency under concurrent operations

#### Manual Maelstrom Testing

You can also run Maelstrom tests manually:

```bash
cd maelstrom
java -jar maelstrom.jar test \
  -w lin-kv \
  --bin ../run-vsr-node \
  --node-count 3 \
  --time-limit 10 \
  --concurrency 6
```

**Workload Options:**
- `lin-kv` - Linearizable key-value store (read, write, cas operations)
- `--node-count` - Number of VSR replicas to run
- `--time-limit` - Duration of test in seconds
- `--concurrency` - Number of concurrent client operations

#### Interpreting Results

After a test run, check:

1. **Test results**: Maelstrom will report if linearizability was maintained
2. **Logs**: Found in `store/lin-kv/latest/`
   - `jepsen.log` - Test runner logs and errors
   - `node-logs/n*.log` - Individual node logs

**Success criteria:**
- All operations must satisfy linearizability
- Minimal network timeouts (some expected during partitions)
- No crashes or protocol violations

## Architecture

See `SPECIFICATION.md` for detailed VSR protocol specification.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/vsr>.

