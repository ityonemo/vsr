defmodule Vsr.Messages do
  @moduledoc """
  VSR protocol message definitions.

  All VSR protocol messages are defined as structs to provide
  type safety and clear documentation of the protocol.
  """

  # Normal Operation Messages
  defmodule Prepare do
    @moduledoc "PREPARE message sent by primary to backups"
    defstruct [:view, :op_number, :operation, :commit_number, :sender]
  end

  defmodule PrepareOk do
    @moduledoc "PREPARE-OK response sent by backups to primary"
    defstruct [:view, :op_number, :sender]
  end

  defmodule Commit do
    @moduledoc "COMMIT message sent by primary to backups"
    defstruct [:view, :commit_number]
  end

  # View Change Messages
  defmodule StartViewChange do
    @moduledoc "START-VIEW-CHANGE message to initiate view change"
    defstruct [:view, :sender]
  end

  defmodule StartViewChangeAck do
    @moduledoc "ACK response to START-VIEW-CHANGE"
    defstruct [:view, :sender]
  end

  defmodule DoViewChange do
    @moduledoc "DO-VIEW-CHANGE message sent to new primary"
    defstruct [:view, :log, :last_normal_view, :op_number, :commit_number, :sender]
  end

  defmodule StartView do
    @moduledoc "START-VIEW message from new primary to all replicas"
    defstruct [:view, :log, :op_number, :commit_number]
  end

  defmodule ViewChangeOk do
    @moduledoc "VIEW-CHANGE-OK response to new primary"
    defstruct [:view, :sender]
  end

  # State Transfer Messages
  defmodule GetState do
    @moduledoc "GET-STATE request for state transfer"
    defstruct [:view, :op_number, :sender]
  end

  defmodule NewState do
    @moduledoc "NEW-STATE response containing replica state"
    defstruct [:view, :log, :op_number, :commit_number]
  end

  # Client Messages
  defmodule ClientRequest do
    @moduledoc "Client request message"
    defstruct [:operation, :client_id, :request_id]
  end

  defmodule ClientReply do
    @moduledoc "Reply to client request"
    defstruct [:request_id, :result]
  end

  # Control Messages
  defmodule Unblock do
    @moduledoc "Control message to unblock replica"
    defstruct [:id]
  end

  @doc """
  Send a VSR protocol message to a target replica.

  This function provides a clean interface for sending structured
  VSR messages between replicas with proper error handling.
  """
  def vsr_send(target_pid, message) when is_pid(target_pid) do
    send(target_pid, message)
  end

  def vsr_send(target_pid, _message) do
    {:error, {:invalid_target, target_pid}}
  end
end
