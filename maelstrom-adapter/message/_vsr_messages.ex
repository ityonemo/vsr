# JSON.Encoder implementations for VSR protocol messages
# This enables VSR messages to be serialized through Maelstrom's JSON protocol

# Normal Operation Messages
defimpl JSON.Encoder, for: Vsr.Message.Prepare do
  def encode(%Vsr.Message.Prepare{} = prepare, opts) do
    prepare
    |> Map.from_struct()
    |> Map.put("type", "prepare")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.PrepareOk do
  def encode(%Vsr.Message.PrepareOk{} = prepare_ok, opts) do
    prepare_ok
    |> Map.from_struct()
    |> Map.put("type", "prepare_ok")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.Commit do
  def encode(%Vsr.Message.Commit{} = commit, opts) do
    commit
    |> Map.from_struct()
    |> Map.put("type", "commit")
    |> JSON.Encoder.encode(opts)
  end
end

# View Change Messages
defimpl JSON.Encoder, for: Vsr.Message.StartViewChange do
  def encode(%Vsr.Message.StartViewChange{} = start_view_change, opts) do
    start_view_change
    |> Map.from_struct()
    |> Map.put("type", "start_view_change")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.StartViewChangeAck do
  def encode(%Vsr.Message.StartViewChangeAck{} = ack, opts) do
    ack
    |> Map.from_struct()
    |> Map.put("type", "start_view_change_ack")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.DoViewChange do
  def encode(%Vsr.Message.DoViewChange{} = do_view_change, opts) do
    do_view_change
    |> Map.from_struct()
    |> Map.put("type", "do_view_change")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.StartView do
  def encode(%Vsr.Message.StartView{} = start_view, opts) do
    start_view
    |> Map.from_struct()
    |> Map.put("type", "start_view")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.ViewChangeOk do
  def encode(%Vsr.Message.ViewChangeOk{} = view_change_ok, opts) do
    view_change_ok
    |> Map.from_struct()
    |> Map.put("type", "view_change_ok")
    |> JSON.Encoder.encode(opts)
  end
end

# State Transfer Messages
defimpl JSON.Encoder, for: Vsr.Message.GetState do
  def encode(%Vsr.Message.GetState{} = get_state, opts) do
    get_state
    |> Map.from_struct()
    |> Map.put("type", "get_state")
    |> JSON.Encoder.encode(opts)
  end
end

defimpl JSON.Encoder, for: Vsr.Message.NewState do
  def encode(%Vsr.Message.NewState{} = new_state, opts) do
    new_state
    |> Map.from_struct()
    |> Map.put("type", "new_state")
    |> JSON.Encoder.encode(opts)
  end
end

# Client Messages  
defimpl JSON.Encoder, for: Vsr.Message.ClientRequest do
  def encode(%Vsr.Message.ClientRequest{} = client_request, opts) do
    client_request
    |> Map.from_struct()
    |> Map.put("type", "client_request")
    |> JSON.Encoder.encode(opts)
  end
end

# Control Messages
defimpl JSON.Encoder, for: Vsr.Message.Heartbeat do
  def encode(%Vsr.Message.Heartbeat{} = heartbeat, opts) do
    heartbeat
    |> Map.from_struct()
    |> Map.put("type", "heartbeat")
    |> JSON.Encoder.encode(opts)
  end
end
