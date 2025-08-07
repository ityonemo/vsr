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

## Protocol Implementation

### Protocol Definition
```elixir
defprotocol Vsr.ProtocolName do
  @moduledoc """
  Clear protocol documentation explaining purpose.
  """
  
  @doc """
  Function documentation with expected behavior.
  """
  def callback_name(implementer, args)
end
```

### Protocol Implementation
```elixir
defmodule MyImplementation do
  use Vsr.ProtocolName  # Use the protocol
  
  @impl Vsr.ProtocolName
  def callback_name(implementer, args) do
    # implementation
  end
end
```

### Behaviour Implementation
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

This document serves as the normative standard for all code contributions to the VSR codebase.