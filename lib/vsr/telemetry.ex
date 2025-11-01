defmodule Vsr.Telemetry do
  @moduledoc """
  Telemetry instrumentation for VSR protocol operations.

  ## Event Categories

  ### Protocol Operations (`:vsr, :protocol, ...`)
  - `[:vsr, :protocol, :client_request, :start]` - Client request received
  - `[:vsr, :protocol, :client_request, :stop]` - Request completed (committed)
  - `[:vsr, :protocol, :prepare, :sent]` - Prepare message broadcast
  - `[:vsr, :protocol, :prepare, :received]` - Prepare message processed
  - `[:vsr, :protocol, :prepare_ok, :sent]` - PrepareOk ACK sent
  - `[:vsr, :protocol, :prepare_ok, :received]` - PrepareOk ACK received
  - `[:vsr, :protocol, :commit, :sent]` - Commit broadcast
  - `[:vsr, :protocol, :commit, :received]` - Commit processed

  ### State Machine (`:vsr, :state_machine, ...`)
  - `[:vsr, :state_machine, :operation, :start]` - Operation execution started
  - `[:vsr, :state_machine, :operation, :stop]` - Operation completed
  - `[:vsr, :state_machine, :operation, :exception]` - Operation failed

  ### View Changes (`:vsr, :view_change, ...`)
  - `[:vsr, :view_change, :start]` - View change initiated
  - `[:vsr, :view_change, :vote_received]` - StartViewChangeAck received
  - `[:vsr, :view_change, :do_view_change, :sent]` - DoViewChange sent to new primary
  - `[:vsr, :view_change, :do_view_change, :received]` - DoViewChange received by primary
  - `[:vsr, :view_change, :complete]` - StartView processed, view established

  ### State Transitions (`:vsr, :state, ...`)
  - `[:vsr, :state, :status_change]` - Status changed (normal ↔ view_change)
  - `[:vsr, :state, :view_change]` - View number changed
  - `[:vsr, :state, :role_change]` - Primary/replica role changed
  - `[:vsr, :state, :commit_advance]` - Commit number advanced

  ### State Transfer (`:vsr, :state_transfer, ...`)
  - `[:vsr, :state_transfer, :request_sent]` - GetState sent
  - `[:vsr, :state_transfer, :request_received]` - GetState received
  - `[:vsr, :state_transfer, :snapshot_sent]` - NewState sent
  - `[:vsr, :state_transfer, :snapshot_received]` - NewState applied

  ### Replication Metrics (`:vsr, :replication, ...`)
  - `[:vsr, :replication, :log_append]` - Entry appended to log
  - `[:vsr, :replication, :log_conflict]` - Log conflict detected
  - `[:vsr, :replication, :quorum_reached]` - Quorum achieved for operation

  ### Timers (`:vsr, :timer, ...`)
  - `[:vsr, :timer, :heartbeat_sent]` - Heartbeat broadcast
  - `[:vsr, :timer, :heartbeat_received]` - Heartbeat processed
  - `[:vsr, :timer, :primary_timeout]` - Primary inactivity timeout fired

  ## Metadata

  Common metadata included in events:
  - `:node_id` - Node identifier
  - `:view_number` - Current view number
  - `:status` - Current status (:normal, :view_change, etc.)
  - `:is_primary` - Boolean indicating if node is primary
  - `:op_number` - Operation number (when applicable)
  - `:commit_number` - Commit number (when applicable)

  ## Example Usage

  Attach a handler to log all VSR events:

      :telemetry.attach_many(
        "vsr-logger",
        [
          [:vsr, :protocol, :client_request, :start],
          [:vsr, :protocol, :client_request, :stop],
          [:vsr, :state, :commit_advance]
        ],
        fn event, measurements, metadata, _config ->
          Logger.info("VSR Event: \#{inspect(event)}",
            measurements: measurements,
            metadata: metadata
          )
        end,
        nil
      )
  """

  @doc """
  Execute a telemetry event with the given measurements and metadata.

  The event name will automatically have `[:vsr]` prepended to it.

  Common metadata (node_id, view_number, etc.) is automatically extracted
  from the state and merged with any additional metadata provided.

  ## Examples

      # Basic usage
      Vsr.Telemetry.execute(
        [:protocol, :prepare, :sent],
        state,
        %{count: 3}
      )
      # Becomes: [:vsr, :protocol, :prepare, :sent]

      # With extra metadata
      Vsr.Telemetry.execute(
        [:protocol, :prepare, :sent],
        state,
        %{count: 3},
        %{custom_field: "value"}
      )
  """
  @spec execute([atom()], map(), map(), map()) :: :ok
  def execute(event, state, measurements, extra_metadata \\ %{}) do
    metadata = Map.merge(common_metadata(state), extra_metadata)
    :telemetry.execute([:vsr | event], measurements, metadata)
  end

  @doc """
  Execute a telemetry span with proper timing measurements and span context.

  The event name will automatically have `[:vsr]` prepended to it.
  The span will emit both `:start` and `:stop` (or `:exception`) events.

  Common metadata is automatically extracted from state and a unique span context
  is generated using `make_ref()`.

  ## Examples

      # Wrap an operation in a telemetry span
      result = Vsr.Telemetry.span(
        [:protocol, :client_request],
        state,
        %{custom: "metadata"},
        fn ->
          # Do work
          :ok
        end
      )

  ## Events Emitted

  - `[:vsr, :protocol, :client_request, :start]` - When span begins
  - `[:vsr, :protocol, :client_request, :stop]` - When span completes successfully
  - `[:vsr, :protocol, :client_request, :exception]` - When span raises an exception

  ## Measurements

  - `:start` event: `monotonic_time`, `system_time`
  - `:stop` event: `monotonic_time`, `duration`
  - `:exception` event: `monotonic_time`, `duration`

  ## Metadata

  All events include:
  - Common metadata from state (node_id, view_number, etc.)
  - `telemetry_span_context` - Unique reference for correlating start/stop events
  - Any additional metadata provided
  """
  @spec span([atom()], map(), map(), (-> result)) :: result when result: term()
  def span(event, state, extra_metadata \\ %{}, fun) do
    metadata =
      state
      |> common_metadata()
      |> Map.merge(extra_metadata)
      |> Map.put(:telemetry_span_context, make_ref())

    :telemetry.span([:vsr | event], metadata, fn ->
      result = fun.()
      {result, %{}}
    end)
  end

  @doc """
  Build common metadata from VSR state.

  Extracts standard VSR state fields that are commonly included in telemetry events.
  """
  @spec common_metadata(map()) :: map()
  def common_metadata(state) do
    %{
      node_id: state.node_id,
      view_number: state.view_number,
      status: state.status,
      is_primary: is_primary?(state),
      op_number: state.op_number,
      commit_number: state.commit_number
    }
  end

  defp is_primary?(%{view_number: view, cluster_size: size, node_id: node_id, replicas: replicas}) do
    all_nodes = MapSet.put(replicas, node_id)
    sorted_nodes = Enum.sort(all_nodes)
    primary_index = rem(view, size)
    Enum.at(sorted_nodes, primary_index) == node_id
  end
end
