defmodule TelemetryHelper do
  @moduledoc """
  Helper module for testing VSR telemetry events.

  Provides utilities to wait for specific telemetry events instead of using
  `Process.sleep()` with arbitrary delays. This makes tests more reliable
  and faster by waiting only as long as necessary.

  ## Usage

      # Set up expectation before triggering the event
      # Event names automatically have [:vsr] prepended
      ref = TelemetryHelper.expect([:state, :view_change])

      # Trigger the event
      VsrServer.vsr_send(replica, message)

      # Wait for the event
      assert :ok = TelemetryHelper.wait_for(ref)

      # With metadata matcher
      ref = TelemetryHelper.expect(
        [:state, :view_change],
        fn metadata -> metadata.view_number == 1 end
      )
      VsrServer.vsr_send(replica, message)
      assert :ok = TelemetryHelper.wait_for(ref)
  """

  @default_timeout 1000

  @doc """
  Set up expectation for a telemetry event before it occurs.

  The event name will automatically have `[:vsr]` prepended to it.

  Returns a reference that can be passed to `wait_for/2`.

  ## Parameters
  - `event` - The telemetry event name (list of atoms), without [:vsr] prefix

  ## Returns
  - `ref` - Reference to pass to `wait_for/2`
  """
  def expect(event) do
    test_pid = self()
    ref = make_ref()
    full_event = [:vsr | event]

    handler_id = {__MODULE__, ref}

    handler_fun = fn ^full_event, measurements, metadata, _ ->
      send(test_pid, {:event, ref, measurements, metadata})
    end

    :telemetry.attach(handler_id, full_event, handler_fun, nil)

    ref
  end

  @doc """
  Wait for a telemetry event that was set up with `expect/1`.

  Returns the metadata map when the event occurs.
  Raises if timeout elapsed.

  The telemetry handler remains attached after this call, so you can call
  `wait_for` multiple times on the same reference to wait for multiple events.

  ## Parameters
  - `ref` - Reference returned by `expect/1`
  - `filter` - Optional function to filter events based on metadata (default: accept all)
  - `timeout` - Maximum time to wait in milliseconds (default: 1000)

  ## Returns
  - Metadata map

  ## Raises
  - RuntimeError if timeout elapsed
  """
  def wait_for(ref, filter \\ fn _ -> true end, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for(ref, filter, deadline)
  end

  @doc """
  Detach a telemetry handler that was set up with `expect/1`.

  ## Parameters
  - `ref` - Reference returned by `expect/1`
  """
  def detach(ref) do
    handler_id = {__MODULE__, ref}
    :telemetry.detach(handler_id)
  end

  defp do_wait_for(ref, filter, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:event, ^ref, _measurements, metadata} ->
        if filter.(metadata) do
          metadata
        else
          # Event didn't match filter, wait for next one
          do_wait_for(ref, filter, deadline)
        end
    after
      remaining ->
        raise "Telemetry event timeout after waiting for #{inspect(ref)}"
    end
  end
end
