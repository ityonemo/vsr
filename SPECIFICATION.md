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

### Operation Log
Each replica maintains an ordered log of operations. Operations are identified by:
- **View number**: The view in which the operation was proposed
- **Operation number**: Sequential number within the view

## Algorithm Phases

### 1. Normal Operation
When the system is stable with an active primary:

1. **Client Request**: Client sends operation to primary
2. **Prepare**: Primary assigns op-number, sends `PREPARE(view, op-num, operation, commit-num)` to all backups
3. **Prepare OK**: Backups append operation to log, send `PREPARE-OK(view, op-num)` to primary
4. **Commit**: When primary receives majority of PREPARE-OK, sends `COMMIT(view, commit-num)` to backups
5. **Execute**: Backups execute committed operations and update state

### 2. View Change
When primary fails or becomes unresponsive:

1. **Timeout**: Backup detects primary failure, increments view number
2. **Start View Change**: Sends `START-VIEW-CHANGE(view, replica-id)` to all replicas
3. **Do View Change**: When replica receives majority START-VIEW-CHANGE, sends `DO-VIEW-CHANGE(view, log, last-normal-view, op-num, commit-num)` to new primary
4. **Start View**: New primary receives majority DO-VIEW-CHANGE, sends `START-VIEW(view, log, op-num, commit-num)` to all replicas
5. **View Change OK**: Replicas update to new view, send `VIEW-CHANGE-OK(view)` to new primary

### 3. State Transfer
When a replica falls behind:

1. **Get State**: Lagging replica sends `GET-STATE(view, op-num)` to primary
2. **New State**: Primary responds with `NEW-STATE(view, log, op-num, commit-num)`
3. **Update**: Lagging replica updates its state to match

## Message Types

### Normal Operation
- `PREPARE(view, op-num, operation, commit-num)`
- `PREPARE-OK(view, op-num, replica-id)`
- `COMMIT(view, commit-num)`

### View Change
- `START-VIEW-CHANGE(view, replica-id)`
- `DO-VIEW-CHANGE(view, log, last-normal-view, op-num, commit-num, replica-id)`
- `START-VIEW(view, log, op-num, commit-num)`
- `VIEW-CHANGE-OK(view, replica-id)`

### State Transfer
- `GET-STATE(view, op-num, replica-id)`
- `NEW-STATE(view, log, op-num, commit-num)`

### Client Operations
- `REQUEST(operation, client-id, request-id)`
- `REPLY(request-id, result)`

## Safety Properties

1. **Agreement**: All replicas execute the same operations in the same order
2. **Integrity**: A replica executes an operation at most once
3. **Validity**: Only proposed operations are executed

## Liveness Properties

1. **Termination**: Every operation eventually executes (assuming eventual synchrony)
2. **View Change**: System eventually selects a new primary when current primary fails

## Implementation Notes

### Key-Value Store Operations
- `GET(key)`: Retrieve value for key
- `PUT(key, value)`: Store key-value pair
- `DELETE(key)`: Remove key

### Replica State
Each replica maintains:
- **view_number**: Current view
- **status**: `:normal`, `:view_change`, or `:recovering`
- **op_number**: Highest operation number
- **commit_number**: Highest committed operation number
- **log**: Ordered list of operations
- **replica_id**: Unique identifier
- **configuration**: List of all replica IDs
- **store**: ETS table for key-value storage

### Failure Handling
- Replicas use timeouts to detect primary failures
- View changes require majority participation
- State transfer handles replicas that fall behind

### Optimizations
- Batching: Group multiple operations in single PREPARE message
- Pipelining: Allow multiple outstanding operations
- Read optimization: Reads can be served locally if replica is up-to-date

## Correctness Conditions

1. **View Synchronization**: All replicas agree on current view
2. **Log Consistency**: Replica logs are consistent up to commit point
3. **Primary Completeness**: New primary has all committed operations
4. **Monotonicity**: View numbers and operation numbers never decrease

This specification provides the foundation for implementing a correct and efficient VSR-based distributed key-value store.
