# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2025-01-01

### Added
- Initial release of VSR (Viewstamped Replication) protocol implementation
- Core VSR protocol with primary-backup replication and view changes
- Automatic primary failure detection and recovery via heartbeat mechanism
- Log-based operation ordering and consistency
- Quorum-based consensus decisions
- Sequential operation validation with gap detection
- Memory management with cleanup of committed operation metadata
- Pluggable state machines, log storage, and communication layers
- Comprehensive telemetry instrumentation following Erlang/Elixir conventions
  - Leadership span tracking (when nodes are primary/leader)
  - Protocol event tracking (prepare, commit, view changes)
  - State machine operation spans with duration metrics
  - Timer and heartbeat event tracking
- Client request deduplication with waiter list for duplicate requests
- Simplified view change protocol (counts StartViewChange messages directly)
- Jepsen Maelstrom integration for distributed systems testing
- Example key-value state machine implementations (in-memory and DETS)

### Documentation
- Comprehensive README with usage examples and testing instructions
- SPECIFICATION.md with detailed VSR protocol specification
- TELEMETRY_EVENTS.md with complete telemetry event documentation
- Review documentation showing all safety issues addressed

### Testing
- 106 unit tests covering all protocol operations
- Maelstrom linearizability testing integration
- Zero network timeout validation

### Known Limitations
- Client request deduplication only implemented for read operations on write paths
- No reconfiguration support (static cluster membership)

[0.1.0]: https://github.com/ityonemo/vsr/releases/tag/v0.1.0
