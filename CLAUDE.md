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
- **Explicit error tuples**: `{:error, :reason}` not just `:error`
- **Consistent patterns**: Always use same error tuple format
- **Meaningful error reasons**: Use descriptive atoms for error reasons

```elixir
# Good
def fetch_operation(log, op_number) do
  case Log.fetch(log, op_number) do
    {:ok, entry} -> {:ok, entry}
    :error -> {:error, :not_found}
  end
end

# Bad
def fetch_operation(log, op_number) do
  Log.fetch(log, op_number) || :error
end
```

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

### Test Configuration
```elixir
# Explicit configuration in tests
{:ok, replica} = GenServer.start_link(Vsr, [
  log: [],  # Use List log for testing
  state_machine: TestStateMachine,
  comms_module: TestComms,  # Use test comms implementation
  cluster_size: 3
])
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

This document serves as the normative standard for all code contributions to the VSR codebase.