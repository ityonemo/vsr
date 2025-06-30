defmodule Vsr.Message do
  @moduledoc """
  VSR protocol message definitions.

  All VSR protocol messages are defined as structs to provide
  type safety and clear documentation of the protocol.
  """

  # Normal Operation Messages
  defmodule Prepare do
    @moduledoc "PREPARE message sent by primary to backups"
    defstruct [:view, :op_number, :operation, :commit_number, :from]
  end

  defmodule PrepareOk do
    @moduledoc "PREPARE-OK response sent by backups to primary"
    defstruct [:view, :op_number, :replica]
  end

  defmodule Commit do
    @moduledoc "COMMIT message sent by primary to backups"
    defstruct [:view, :commit_number]
  end

  # View Change Messages
  defmodule StartViewChange do
    @moduledoc "START-VIEW-CHANGE message to initiate view change"
    defstruct [:view, :replica]
  end

  defmodule StartViewChangeAck do
    @moduledoc "ACK response to START-VIEW-CHANGE"
    defstruct [:view, :replica]
  end

  defmodule DoViewChange do
    @moduledoc "DO-VIEW-CHANGE message sent to new primary"
    defstruct [:view, :log, :last_normal_view, :op_number, :commit_number, :from]
  end

  defmodule StartView do
    @moduledoc "START-VIEW message from new primary to all replicas"
    defstruct [:view, :log, :op_number, :commit_number]
  end

  defmodule ViewChangeOk do
    @moduledoc "VIEW-CHANGE-OK response to new primary"
    defstruct [:view, :from]
  end

  # State Transfer Messages
  defmodule GetState do
    @moduledoc "GET-STATE request for state transfer"
    defstruct [:view, :op_number, :sender]
  end

  defmodule NewState do
    @moduledoc "NEW-STATE response containing replica state"
    defstruct [:view, :log, :op_number, :commit_number, :state_machine_state]
  end

  # Client Messages
  defmodule ClientRequest do
    @moduledoc "Client request message"
    defstruct [:operation, :from, :read_only]
  end

  # CLIENT-REPLY is ignored since we can directly reply over erlang message bus.

  # Control Messages
  defmodule Heartbeat do
    @moduledoc "Control message for primary to check replica liveness"
    defstruct []
  end

  @doc """
  Send a VSR protocol message to a target replica.

  This function provides a clean interface for sending structured
  VSR messages between replicas with proper error handling.
  """
  def vsr_send(target_pid, message) when is_pid(target_pid) do
    GenServer.cast(target_pid, {:vsr, message})
  end
end
