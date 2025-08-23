# VSR Coding Standards

This document outlines the normative coding standards for the VSR (Viewstamped Replication) codebase.

## Module Organization

### Structure
Organize modules with clear sections using comments:

```elixir
defmodule Vsr.ModuleName do
  @moduledoc """
  Clear, concise module documentation.
  
  Explain purpose, usage patterns, and important notes.
  Include examples where helpful.
  """
  
  # Section 0: Types and Constants
  @type t :: %__MODULE__{}
  @default_opts [key: :value]
  
  # Section 1: Public API
  def public_function(args), do: implementation
  
  # Section 2: GenServer callbacks (if applicable)
  def init(opts), do: {:ok, state}
  def handle_call(msg, from, state), do: {:reply, :ok, state}
  
  # Section 3: Private helpers
  defp helper_function(args), do: implementation
end
```

### Documentation Standards
- **All public functions** must have `@doc` strings
- **All modules** must have `@moduledoc` with clear purpose explanation
- **Protocol callbacks** should document expected behavior and return values
- **Complex algorithms** require inline comments explaining the logic
- **Include examples** in documentation where helpful

## Naming Conventions

### Modules
- **PascalCase**: `Vsr.StateMachine`, `VsrKv`
- **Descriptive names**: Module name should clearly indicate purpose
- **Namespace properly**: Use `Vsr.` prefix for core protocol modules

### Functions
- **snake_case**: `client_request_impl`, `increment_op_number`
- **Descriptive names**: Function name should clearly indicate what it does
- **Implementation suffix**: Message handlers use `_impl` suffix (`prepare_impl/2`)
- **Protocol callbacks**: Prefix with `_` (`_apply_operation`, `_get_state`)

### Variables and Atoms
- **snake_case**: `view_number`, `op_number`
- **Descriptive**: Avoid abbreviations unless they're domain-specific (VSR terms)
- **Consistent terminology**: Use VSR specification terms exactly

### Constants
- **Uppercase with underscores**: `@DEFAULT_OPTS`, `@FILTER`
- **Module attributes**: Use `@` for compile-time constants

### Module Aliases
- **Individual alias statements**: Use separate `alias` statements for each module in source files
- **❌ Avoid multi-module aliases in source code**: `alias Module.{A, B, C}`
- **✅ Use individual aliases in source files**: 
  ```elixir
  alias Module.A
  alias Module.B
  alias Module.C
  ```
- **✅ Exception**: Bracketed aliases are acceptable for command-line usage (IEx, `elixir -e "..."`)
- **Reason**: Individual aliases are clearer, easier to grep, and avoid merge conflicts in source files

## Function Patterns

### Function Definitions
```elixir
# Good - descriptive name, clear pattern matching
defp client_request_impl(%ClientRequest{operation: op, from: from}, state) do
  # implementation
end

# Bad - abbreviated name, unclear purpose  
defp handle_cr(msg, state) do
  # implementation
end
```

### Error Handling
- **Let it crash**: Follow Erlang/Elixir philosophy - don't code defensively with excessive try/catch
- **No defensive catch-all branches**: Never use `_ ->` branches in case statements to "handle" unexpected input - let it crash so problems surface in logs
- **Explicit error tuples**: `{:error, :reason}` not just `:error` for expected error conditions
- **Consistent patterns**: Always use same error tuple format
- **Meaningful error reasons**: Use descriptive atoms for error reasons
- **Crash on invalid input**: Let functions crash on invalid input rather than handling every edge case
- **No defensive logging**: Don't log warnings for "unhandled" cases - if it's truly unhandled, it should crash

```elixir
# Good - let it crash on invalid input
def fetch_operation(log, op_number) when is_integer(op_number) and op_number > 0 do
  case Log.fetch(log, op_number) do
    {:ok, entry} -> {:ok, entry}
    :error -> {:error, :not_found}
  end
end

# Good - crash immediately on invalid JSON rather than defensive error handling
def stdin_impl(stdin, _from, state) do
  json_map = JSON.decode!(stdin)  # Let it crash if invalid JSON
  message = Message.from_json_map(json_map)  # Let it crash if invalid message
  # ... process message
end

# Bad - overly defensive
def fetch_operation(log, op_number) do
  try do
    case Log.fetch(log, op_number) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :unknown}
  end
end
```

**When to let it crash:**
- Invalid JSON input
- Missing required fields in messages  
- Type mismatches (string passed where integer expected)
- Programming errors (calling undefined functions)
- Contract violations (guards should enforce contracts)

**When to use error tuples:**
- Expected business logic failures (key not found, insufficient permissions)
- Network failures that should be retried
- Resource unavailability that can be handled gracefully

### Pattern Matching
- **Match in function heads** when possible
- **Use guards** for simple validations
- **Use `with`** for complex validation chains

```elixir
# Good - pattern matching in function head
defp prepare_impl(%Prepare{view: view} = prepare, %{view_number: current_view} = state) 
  when view >= current_view do
  # implementation
end

# Good - with statement for complex validation
defp validate_prepare(prepare, state) do
  with {:view, view} when view >= state.view_number <- {:view, prepare.view},
       {:op, op} when op > Log.length(state.log) <- {:op, prepare.op_number} do
    {:ok, prepare}
  else
    {:view, _} -> {:error, :stale_view}
    {:op, _} -> {:error, :duplicate_operation}
  end
end
```

## Code Style and Syntax

### Keyword Lists
- **Remove unnecessary brackets**: When keyword lists are the last argument to a function, omit the brackets
- **❌ Avoid**: `start_supervised!({Module, [option: value, other: data]})`
- **✅ Use**: `start_supervised!({Module, option: value, other: data})`
- **Exception**: Brackets are required when the keyword list is not the last argument

```elixir
# Good - no brackets around keyword list as last argument
start_supervised!({Vsr.ListKv, node_id: :replica1, cluster_size: 3})

# Good - brackets required when not last argument
some_function([option: value], other_arg)

# Bad - unnecessary brackets around keyword list
start_supervised!({Vsr.ListKv, [node_id: :replica1, cluster_size: 3]})
```

### Module Aliases
- **Never use `as:`**: Always use individual alias statements without renaming
- **❌ Avoid**: `alias Some.Long.Module, as: Module`
- **✅ Use**: `alias Some.Long.Module`
- **Reasoning**: The `as:` pattern obscures the actual module name and makes code harder to follow

```elixir
# Good - clear module aliasing
alias Maelstrom.Message
alias Maelstrom.Message.Init
alias Maelstrom.Message.Echo

# Bad - using as: for aliasing
alias Maelstrom.Message, as: Message
alias Some.Long.Module, as: Short

# Exception: Only use full module names when there would be naming conflicts
defmodule MyApp.Message do
  # Here we'd need to use full names to avoid conflicts with our own Message
  # But prefer restructuring modules to avoid this situation
end
```

## Protocol Implementation with Protoss

### Understanding Protoss Framework
**CRITICAL**: VSR uses the Protoss framework for colocated protocol implementations. This is NOT standard Elixir protocols or behaviours.

### Protoss Protocol Definition
```elixir
use Protoss  # MUST be at the top of protocol files

defprotocol Vsr.ProtocolName do
  @moduledoc """
  Clear protocol documentation explaining purpose.
  """
  
  @doc """
  Function documentation with expected behavior.
  """
  def callback_name(implementer, args)
after
  # Protoss callback specification (like @behaviour)
  @callback _new(vsr :: term, options :: keyword) :: t
end
```

### Protoss Protocol Implementation
```elixir
defmodule MyImplementation do
  use Vsr.ProtocolName  # Use the Protoss protocol (NOT defimpl!)
  
  # Implementation callbacks - these are called by Protoss
  def _new(vsr_instance, opts) do
    # Initialize the implementation
    %__MODULE__{...}
  end
  
  # Protocol function implementations
  def callback_name(implementer, args) do
    # implementation
  end
end
```

### Key Protoss Patterns

#### State Machine Implementation
```elixir
defmodule MyStateMachine do
  use Vsr.StateMachine  # Use Protoss protocol
  
  def _new(_vsr_pid, _opts), do: %__MODULE__{state: %{}}
  def _apply_operation(sm, op), do: {new_sm, result}  
  def _read_only?(_sm, _op), do: false
  def _require_linearized?(_sm, _op), do: true
  def _get_state(sm), do: sm.state
  def _set_state(sm, new_state), do: %{sm | state: new_state}
end
```

#### Log Implementation  
```elixir
defmodule MyLog do
  use Vsr.Log  # Use Protoss protocol
  
  def _new(node_id, opts), do: %__MODULE__{...}
  def append(log, entry), do: updated_log
  def fetch(log, op_number), do: {:ok, entry} | {:error, :not_found}
  def get_all(log), do: [entries...]
  def get_from(log, op_number), do: [entries...]  
  def length(log), do: integer()
  def replace(log, entries), do: updated_log
  def clear(log), do: cleared_log
end
```

### Protoss vs Standard Elixir Protocols

#### WRONG - Standard Elixir Protocol
```elixir
defimpl Vsr.Log, for: MyLog do
  def append(log, entry), do: ...
end
```

#### CORRECT - Protoss Protocol
```elixir
defmodule MyLog do
  use Vsr.Log  # This is the Protoss way
  
  def append(log, entry), do: ...
end
```

### VSR Initialization Patterns

#### Using Protoss Specs (Recommended)
```elixir
# VSR will call Module._new(args...) via Protoss
vsr_opts = [
  log: {MyLog, [node_id, [dets_file: "log.dets"]]},
  state_machine: {MyStateMachine, []}
]
```

#### Direct Instance (When Needed)
```elixir
# Only use this when you need to pre-configure the instance
log = MyLog._new(node_id, [dets_file: "log.dets"])
vsr_opts = [log: log, ...]
```

### Common Protoss Mistakes to Avoid

1. **Using `defimpl` instead of `use`**
   - ❌ `defimpl Vsr.Log, for: MyLog`
   - ✅ `defmodule MyLog do use Vsr.Log`

2. **Missing `_new` callback**
   - ❌ No `_new` function defined
   - ✅ `def _new(args...), do: %__MODULE__{...}`

3. **Wrong initialization pattern**
   - ❌ `MyLog.new(args...)`  
   - ✅ `MyLog._new(args...)` or `{MyLog, [args...]}`

4. **Mixing standard protocols with Protoss**
   - ❌ Using both `use` and `defimpl` for same protocol
   - ✅ Use only `use` for Protoss protocols

### Behaviour Implementation (Non-Protoss)
```elixir
defmodule MyBehaviour do
  @behaviour Vsr.BehaviourName
  
  @impl Vsr.BehaviourName
  def callback_function(args) do
    # implementation
  end
end
```

## Type Specifications

### Struct Types
```elixir
defmodule Vsr.Message.Prepare do
  @type t :: %__MODULE__{
    view: non_neg_integer(),
    op_number: non_neg_integer(), 
    operation: term(),
    commit_number: non_neg_integer(),
    from: GenServer.from()
  }
  
  defstruct [:view, :op_number, :operation, :commit_number, :from]
end
```

### Function Specs
```elixir
@spec client_request(pid(), term()) :: term()
def client_request(pid, operation) do
  # implementation
end
```

## GenServer Patterns

### handle_call vs handle_cast Guidelines
- **PREFER handle_call**: Always use `handle_call` by default for synchronous operations
- **AVOID handle_cast**: Only use `handle_cast` when there is a specific performance or deadlock reason
- **Performance reasons**: High-throughput scenarios where immediate response is not needed
- **Deadlock reasons**: When synchronous calls would create circular dependencies
- **Code clarity**: `handle_call` makes control flow explicit and easier to debug
- **Error handling**: `handle_call` allows proper error propagation to callers

### Client/Server Separation
```elixir
# Client API
def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
def client_request(pid, op), do: GenServer.call(pid, {:client_request, op})

# Server callbacks  
def handle_call({:client_request, op}, from, state) do
  client_request_impl(op, from, state)
end

# Implementation functions
defp client_request_impl(operation, from, state) do
  # actual logic here
  {:reply, result, new_state}
end
```

### Router Pattern
The Router pattern (as exemplified in VsrServer) separates message routing from message processing:

```elixir
# ROUTER - Only routes messages to handlers, no processing
def handle_call({:message, message}, _from, state) do
  case message.body do
    %Init{} = init ->
      do_init(init, message, state)
      
    %Echo{} = echo ->
      do_echo(echo, message, state)
      
    # No defensive _ -> branch - let it crash on unexpected input
  end
end

# HANDLERS - Do the actual work and return proper GenServer tuples
defp do_init(init, message, state) do
  # Process the init message
  send_reply_if_needed()
  {:noreply, new_state}
end

defp do_echo(echo, message, state) do
  # Process the echo message  
  send_reply_immediately()
  {:noreply, new_state}
end
```

**Router Pattern Rules:**
- **Router only routes**: `handle_call` should only pattern match and delegate
- **Handlers return GenServer tuples**: `{:noreply, state}`, `{:noreply, state, {:client_request, op}}`, etc.
- **No processing in router**: All business logic goes in `do_*` functions
- **Let it crash**: No defensive `_ ->` branches in routers
- **Consistent naming**: Use `do_*` prefix for message handlers

### State Management
- **Use structs** for GenServer state with clear field definitions
- **Immutable updates**: Always return new state, never mutate existing
- **Helper functions**: Use private helpers for state transformations

## Testing Standards

### Test Organization
```elixir
defmodule ModuleTest do
  use ExUnit.Case
  
  setup do
    # Common setup
    {:ok, fixtures}
  end
  
  test "descriptive test name explaining scenario", %{fixtures: fixtures} do
    # Test implementation
  end
end
```

### Test Patterns
- **Descriptive test names**: Explain what scenario is being tested
- **Proper fixtures**: Use setup blocks for common test data
- **Avoid hardcoded delays**: Use proper synchronization mechanisms
- **Test error cases**: Include tests for both success and failure paths
- **Diagnostic tests**: Include tests that help debug complex distributed scenarios
- **NEVER use GenServer.* functions in tests**: Tests should only use the public API functions provided by modules, not internal GenServer functions like `GenServer.call`, `GenServer.cast`, `GenServer.reply`, etc.
- **ALL TESTS MUST BE ASYNC**: Never use `async: false` - all tests must run concurrently. Use unique node IDs and proper test isolation instead of serializing tests.
- **Do not check process alive status**: Tests should not include `Process.alive?/1` assertions - processes being alive is handled by the supervision tree and is not a meaningful test assertion
- **NEVER use :sys.get_state or :sys.replace_state**: These functions break encapsulation and create brittle tests. Instead use `dump_state/1` for state inspection or proper public APIs for state modification. Tests using :sys functions are fragile and can break with internal implementation changes.

### Test Configuration
```elixir
# Explicit configuration in tests
{:ok, replica} = GenServer.start_link(Vsr, 
  log: [],  # Use List log for testing
  state_machine: TestStateMachine,
  comms_module: TestComms,  # Use test comms implementation
  cluster_size: 3
)
```

## Code Quality

### General Principles
- **Single responsibility**: Each module should have one clear purpose
- **Functional programming**: Prefer immutable data and pure functions
- **Explicit over implicit**: Make dependencies and configurations explicit
- **Consistent terminology**: Use VSR specification terms exactly

### Common Patterns
```elixir
# Pipeline operations for data transformation
new_state =
  state
  |> increment_op_number()
  |> append_new_log(from, operation)
  |> maybe_commit_operation(op_number)

# Pattern matching with guards
defp primary_for_view(view, replicas) when is_integer(view) and view >= 0 do
  # implementation
end

# Consistent error handling
case result do
  {:ok, value} -> handle_success(value)
  {:error, reason} -> handle_error(reason)
end
```

### Avoiding Common Issues
- **No unused aliases or imports**
- **No hardcoded values** - use module attributes or configuration  
- **No TODO comments** in production code
- **Proper error propagation** - don't swallow errors silently
- **Clear variable names** - avoid single letter variables except for very short scopes

## VSR-Specific Guidelines

### Message Handling
- **Struct-based messages**: All VSR messages should be defined as structs
- **Type-based routing**: Use pattern matching on message types in handle_cast
- **Validation first**: Always validate message fields before processing

### State Transitions
- **Follow specification**: Implement exactly as described in SPECIFICATION.md
- **Atomic updates**: State changes should be atomic within a single function
- **Consistent ordering**: Apply state changes in the order specified by the protocol

### Protocol Compliance
- **Exact field names**: Use field names exactly as specified in the VSR protocol
- **Proper sequencing**: Implement message sequences as described in the specification
- **Safety properties**: Ensure all safety properties are maintained

## Build and Development

### Compilation
- Code must compile without warnings when using `--warnings-as-errors`
- All tests must pass before committing changes
- Use `mix format` for consistent code formatting

### Dependencies
- Minimize external dependencies
- Use only well-maintained, stable libraries
- Document any new dependency requirements

## Maelstrom Integration Guidelines

### JSON Message Protocol

**CRITICAL**: All VSR protocol messages (except Init) sent over Maelstrom are generated by VSR itself, not by external sources.

#### Message Generation and Parsing Rules

1. **VSR generates all VSR protocol messages**: Prepare, PrepareOk, Heartbeat, Commit, etc. are all created by our VSR code
2. **Init is the only exception**: This is the only message Maelstrom generates for us
3. **All other messages are VSR-to-VSR**: They must contain all required fields

#### JSON Decoding Standards
```elixir
# CORRECT - Use Map.fetch!/2 for all VSR protocol messages
%Prepare{
  view: Map.fetch!(json_map, "view"),
  op_number: Map.fetch!(json_map, "op_number"),
  leader_id: Map.fetch!(json_map, "leader_id")  # Must be present
}

# WRONG - Don't use Map.get/3 with defaults for VSR messages
%Prepare{
  leader_id: Map.get(json_map, "leader_id", nil)  # Hides bugs in message generation
}
```

**Rationale**: If a required field is missing, it means we have a bug in our message generation code, not a compatibility issue. Let it crash to surface the bug immediately.

#### Test Message Generation
- **Tests should generate JSON by encoding structs**: Don't hand-write JSON maps
- **Use proper struct creation**: Ensure all required fields are present
- **Example**:
  ```elixir
  # CORRECT - Generate JSON from struct
  prepare = %Prepare{view: 1, op_number: 1, leader_id: "n0", ...}
  json = Message.to_json_map(prepare)
  
  # WRONG - Hand-written JSON that might miss fields
  json = %{"type" => "prepare", "view" => 1}  # Missing leader_id!
  ```

### Key Architectural Principles

1. **Durability Strategy**: Log is durable (DETS), state machine is in-memory cache
   - ❌ Making state machine persistent with DETS  
   - ✅ DETS log + in-memory state machine that can be reconstructed from log

2. **Node Communication**: Maelstrom uses string node IDs, not Erlang PIDs
   - ❌ Using PIDs for dest_pid in communications
   - ✅ Using string node IDs like "n1", "n2", "n3" 

3. **JSON Protocol**: Use built-in `JSON` module, not external libraries
   - ❌ `{:jason, "~> 1.0"}` or other JSON libraries
   - ✅ Built-in `JSON.encode!/1` and `JSON.decode/1`

### Environment Configuration
```elixir
# mix.exs - Maelstrom environment setup
def elixirc_paths(:maelstrom), do: ["lib", "maelstrom", "test/_support"]
def elixirc_paths(:test), do: ["lib", "test/_support", "maelstrom"]

def application do
  case Mix.env() do
    :maelstrom -> [extra_applications: [:logger], mod: {Maelstrom.Application, []}]
    _ -> [extra_applications: [:logger]]
  end
end
```

### Testing Command Patterns
```bash
# Use these exact commands for testing Maelstrom integration
MIX_ENV=maelstrom elixir simple_test.exs
MIX_ENV=maelstrom elixir debug_test.exs

# For regular tests, NEVER use MIX_ENV=test - it's the default
# ❌ MIX_ENV=test mix test
# ✅ mix test
```

### Common Maelstrom Mistakes to Avoid

1. **Wrapper Pattern Overuse**
   - ❌ Creating wrapper modules when not needed
   - ✅ Use wrappers only when you need to adapt interfaces (e.g., PID vs string node_id)

2. **Wrong Persistence Layer**
   - ❌ Persisting state machine state directly 
   - ✅ Persist operations in log, reconstruct state from log

3. **Communication Assumptions**
   - ❌ Assuming Erlang distribution is available
   - ✅ Use Maelstrom's JSON protocol over STDIN/STDOUT

4. **Environment Mixing**
   - ❌ Loading wrong modules for different environments
   - ✅ Proper `elixirc_paths` configuration for each environment

### VSR + Maelstrom Integration Pattern
```elixir
# Correct Maelstrom VSR setup
vsr_opts = [
  log: {Maelstrom.DetsLog, [node_id, [dets_file: "#{node_id}_log.dets"]]},
  state_machine: {Maelstrom.Kv, []},  # Simple in-memory state machine
  cluster_size: length(node_ids),
  comms_module: Maelstrom.Comms
]
```

## Debugging and Error Analysis Guidelines

### Post-Test Analysis Workflow

**CRITICAL**: After every Maelstrom test run, ALWAYS check these files in order:

1. **First: Check `jepsen.log`** - Contains Maelstrom's network-level errors
   ```bash
   cat store/lin-kv/latest/jepsen.log
   ```
   - Look for "Malformed network message" errors
   - Look for "missing-required-key" errors  
   - Look for process startup/teardown issues
   - **This file reveals network-level problems that node logs might miss**

2. **Second: Check individual node logs** - Contains our application errors
   ```bash
   cat store/lin-kv/latest/node-logs/n0.log
   cat store/lin-kv/latest/node-logs/n1.log  
   cat store/lin-kv/latest/node-logs/n2.log
   ```
   - Look for GenServer crashes and stack traces
   - Look for "Sending Maelstrom message" vs "Decoded Maelstrom message" patterns
   - Look for missing expected messages (e.g., if n1 sends prepare_ok to n0, does n0 receive it?)

3. **Pattern Analysis**: Compare what was sent vs received across nodes
   - If node A sends a message to node B, check if node B received it
   - Look for gaps in message delivery patterns
   - Check if crashes occur during message processing

### Understanding Error Messages

1. **Language Context in Error Messages**
   - ❌ Assuming `{:body {}}` is Elixir tuple syntax
   - ✅ Recognize `{:body {}}` is **Clojure** syntax from Maelstrom's Java process
   - **Key insight**: Error messages may come from different languages in the stack

2. **Maelstrom Error Interpretation**
   ```
   Malformed network message. Node n0 tried to send the following message via STDOUT:
   {:body {}}
   This is malformed because: {:src missing-required-key, :dest missing-required-key}
   ```
   - **Meaning**: Our VSR node sent an empty/incomplete message to Maelstrom
   - **Not**: Elixir code outputting tuples to stdout
   - **Cause**: Message construction failure, empty maps, or process crashes during send

3. **Stdout vs Stderr Confusion**
   - ❌ Debugging stdout issues by adding more stdout logging
   - ✅ Use Logger (goes to stderr) to debug stdout JSON messages
   - **Key insight**: Maelstrom reads structured JSON from stdout, logs go to stderr

### Systematic Debugging Approach

1. **Start Simple, Build Complexity**
   - ❌ Jump to complex scenarios when basic communication fails
   - ✅ Test basic echo/init messages first before VSR integration
   - **Rule**: If init fails, don't test VSR operations

2. **Isolate the Problem Layer**
   - ❌ Assume the problem is in the most recently changed code
   - ✅ Consider all layers: JSON encoding, message construction, protocol handling
   - **Process**: 
     1. Test message construction in isolation
     2. Test JSON encoding/decoding
     3. Test protocol message flow
     4. Test VSR integration

3. **Let it crash**
  avoid try/do blocks, and just let it crash instead of coding defensively.

### Common Debugging Mistakes

1. **Expensive Trial-and-Error Loops**
   - ❌ Making multiple changes without understanding the root cause
   - ❌ Adding debug code that interferes with the actual protocol
   - ✅ Make minimal, targeted changes to isolate the issue
   - ✅ Use proper debugging tools (Logger to stderr, not stdout)

2. **Misinterpreting Cross-Language Error Messages**
   - ❌ Thinking Clojure error syntax indicates Elixir code problems
   - ✅ Understand which process/language generated the error message
   - **Tool**: Check process boundaries - Java/Clojure (Maelstrom) vs Elixir (VSR)

3. **Debugging the Wrong Layer**
   - ❌ Debugging VSR logic when the problem is in basic JSON communication
   - ✅ Start with the simplest possible test case
   - **Rule**: Fix lower layers before debugging higher layers

### Running Maelstrom Tests

**Primary Command**: Use the `maelstrom-kv` script for all testing:
```bash
./maelstrom-kv
```

This script runs the lin-kv workload with the following configuration:
- 3 nodes (n0, n1, n2)
- 10 second time limit
- 6 concurrent operations
- Tests linearizable key-value operations

**Alternative manual command** (for reference only):
```bash
lein run test -w lin-kv --bin ./run-vsr-node --node-count 3 --time-limit 10 --concurrency 6
```

### Post-Test Analysis Workflow

**CRITICAL**: After every Maelstrom test run, ALWAYS check these files in order:

1. **First: Check `jepsen.log`** - Contains Maelstrom's network-level errors
   ```bash
   cat store/lin-kv/latest/jepsen.log | grep -i error
   cat store/lin-kv/latest/jepsen.log | grep -i malformed
   ```

2. **Second: Check individual node logs** - Contains our application errors  
   ```bash
   cat store/lin-kv/latest/node-logs/n0.log
   cat store/lin-kv/latest/node-logs/n1.log  
   cat store/lin-kv/latest/node-logs/n2.log
   ```

3. **Third: CRITICAL Message Flow Verification**
   
   **ESSENTIAL**: Always verify that messages are both SENT and RECEIVED correctly:

   a) **Check Message Sending**:
      ```bash
      # Look for "Sending Maelstrom message" in each node log
      grep "Sending.*MESSAGE_TYPE" store/lin-kv/latest/node-logs/n*.log
      ```

   b) **Check Message Receiving**:
      ```bash
      # Look for "Received Maelstrom message" in each node log  
      grep "Received.*MESSAGE_TYPE" store/lin-kv/latest/node-logs/n*.log
      ```

   c) **❌ CRITICAL PATTERN**: Messages sent but never received
      - If node A shows "Sending" but node B never shows "Received"
      - This indicates a message delivery failure in Maelstrom
      - Check jepsen.log for malformed message errors
      - Verify message format has proper `src`, `dest`, and `body` fields

   d) **VSR Protocol Flow Example**:
      ```bash
      # Check complete prepare/prepare_ok cycle
      grep -E "(prepare|commit)" store/lin-kv/latest/node-logs/n*.log | grep -E "(Sending|Received)"
      ```

4. **Fourth: Look for other patterns**
   - Malformed message errors: `{:body {}}`
   - Missing required keys: `:src missing-required-key`
   - Client timeouts: `Client read timeout`
   - GenServer timeouts: `time out`

### Maelstrom-Specific Debugging

1. **Log File Analysis**
   ```bash
   # Check actual Maelstrom logs, not just our stderr
   cat store/lin-kv/latest/jepsen.log | grep -i error
   cat store/lin-kv/latest/node-logs/n0.log
   ```

2. **Protocol Isolation Testing**
   ```bash
   # Test basic node communication without VSR
   echo '{"src":"c0","dest":"n0","body":{"type":"init","msg_id":1,"node_id":"n0","node_ids":["n0"]}}' | ./run-vsr-node
   ```

3. **Message Format Validation**
   - ✅ All Maelstrom messages must have `src`, `dest`, and `body` fields
   - ✅ The `body` must contain `type` field
   - ❌ Sending incomplete or empty maps

### Learning from Mistakes Pattern

When debugging fails repeatedly:

1. **Document the error pattern** in CLAUDE.md
2. **Identify the root misconception** that led to the wrong approach
3. **Create systematic debugging steps** to avoid the same mistake
4. **Update coding standards** to prevent similar issues in future

## VSR + Maelstrom Synchronous Operation Flow

**CRITICAL**: All Maelstrom operations (read, write, cas) must be synchronous, following the same pattern as ListKv operations.

### Correct MaelstromKv Operation Flow

1. **do_write/do_cas functions**: 
   ```elixir
   defp do_write(%Write{key: key, value: value}, message, genserver_from, state) do
     operation = ["write", key, value]
     
     # Store GenServer from in ETS and create encoded from for VSR
     from_hash = store_from(state, genserver_from)
     encoded_from = %{"node" => state.node_id, "from" => from_hash}
     
     # Store message for Maelstrom JSON reply later
     :ets.insert(state.from_table, {"message_#{from_hash}", message})
     
     {:noreply, state, {:client_request, encoded_from, operation}}
   end
   ```
   - Store GenServer `from` tuple in ETS table with hash
   - Create JSON-encoded `from` as `%{"node" => node_id, "from" => from_hash}`
   - Store Maelstrom message separately for JSON reply generation
   - Use `{:client_request, encoded_from, operation}` pattern

2. **handle_commit function**:
   ```elixir
   def handle_commit(["write", key, value], state, _vsr_state) do
     new_data = Map.put(state.data, key, value)
     new_state = %{state | data: new_data}
     {new_state, :ok}  # VSR handles reply via send_reply callback
   end
   ```
   - Apply operation to state machine
   - Return `{new_state, result}`
   - VSR automatically calls `send_reply(from, result, vsr_state)`

3. **send_reply function**: `send_reply(from, reply, vsr_state)`
   ```elixir
   def send_reply(%{"node" => node_id, "from" => from_hash} = from, reply, vsr_state) do
     if node_id == vsr_state.inner.node_id do
       # Local: retrieve GenServer from and Maelstrom message from ETS
       {:ok, genserver_from} = fetch_from(vsr_state.inner, from_hash)
       [{_, message}] = :ets.lookup(vsr_state.inner.from_table, "message_#{from_hash}")
       
       # Send Maelstrom JSON reply
       Message.reply(message.body, to: message, ...)
       # Send GenServer reply to unblock {:message, message} call  
       GenServer.reply(genserver_from, :ok)
     else
       # Remote: send ForwardedReply across Maelstrom bus
       send_forwarded_reply(node_id, from_hash, reply)
     end
   end
   ```
   - **If local**: Lookup both GenServer.from tuple and Maelstrom message from ETS
   - **Send both replies**: Maelstrom JSON response + GenServer reply to unblock call
   - **If remote**: Send ForwardedReply message across Maelstrom bus

### Key Insights

- **Synchronous at GenServer level**: The `{:message, message}` call blocks until VSR consensus completes
- **Maelstrom message is the `from`**: Pass the entire Maelstrom message as `from` parameter to VSR
- **No separate request tracking**: Don't use `pending_requests` - let VSR handle the flow
- **send_reply handles distribution**: Translates between GenServer.from tuples and Maelstrom ForwardedReply messages
- **Signature**: `send_reply(from, reply, vsr_state)` NOT `send_reply(from, reply, inner_state)`

This document serves as the normative standard for all code contributions to the VSR codebase.