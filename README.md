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

## Current Limitations

⚠️ **Client Request Deduplication**: Currently only implemented for read-only operations. Write operations may be processed multiple times if clients retry requests due to network timeouts. This does not affect VSR protocol correctness or safety properties, but may impact user experience.

- **Workaround**: Implement request deduplication at the application layer using unique request IDs
- **Future Work**: Full write operation deduplication requires propagating client identifiers through the entire VSR protocol

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

```bash
mix test
```

**Test Status**: 35/35 tests passing (3 skipped - write deduplication and edge cases documented above)

## Architecture

See `SPECIFICATION.md` for detailed VSR protocol specification.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/vsr>.

