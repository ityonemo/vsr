defmodule Maelstrom.Node.MessageTest do
  use ExUnit.Case, async: true

  @moduletag :maelstrom

  alias Maelstrom.Node.Message
  alias Maelstrom.Node.Init
  alias Maelstrom.Node.Echo
  alias Maelstrom.Node.Read
  alias Maelstrom.Node.Write
  alias Maelstrom.Node.Cas
  alias Maelstrom.Node.Error
  alias Vsr.Message.Prepare
  alias Vsr.Message.PrepareOk
  alias Vsr.Message.Commit
  alias Vsr.Message.ClientRequest
  alias Vsr.Message.Heartbeat

  describe "from_json_map/1" do
    test "converts Maelstrom init message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "init",
          "msg_id" => 1,
          "node_id" => "n0",
          "node_ids" => ["n0", "n1", "n2"]
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %Init{
                 type: :init,
                 msg_id: 1,
                 node_id: "n0",
                 node_ids: ["n0", "n1", "n2"]
               }
             } = result
    end

    test "converts Maelstrom init_ok message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "init_ok",
          "in_reply_to" => 1
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Init.Ok{
                 type: :init_ok,
                 in_reply_to: 1
               }
             } = result
    end

    test "converts Maelstrom echo message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "echo",
          "msg_id" => 1,
          "echo" => "Hello, world!"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %Echo{
                 type: :echo,
                 msg_id: 1,
                 echo: "Hello, world!"
               }
             } = result
    end

    test "converts Maelstrom echo_ok message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "echo_ok",
          "msg_id" => 2,
          "in_reply_to" => 1,
          "echo" => "Hello, world!"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Echo.Ok{
                 type: :echo_ok,
                 msg_id: 2,
                 in_reply_to: 1,
                 echo: "Hello, world!"
               }
             } = result
    end

    test "converts Maelstrom read message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "read",
          "msg_id" => 1,
          "key" => "foo"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %Read{
                 type: :read,
                 msg_id: 1,
                 key: "foo"
               }
             } = result
    end

    test "converts Maelstrom read_ok message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "read_ok",
          "in_reply_to" => 1,
          "value" => 42
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Read.Ok{
                 type: :read_ok,
                 in_reply_to: 1,
                 value: 42
               }
             } = result
    end

    test "converts Maelstrom write message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "write",
          "msg_id" => 1,
          "key" => "foo",
          "value" => "bar"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %Write{
                 type: :write,
                 msg_id: 1,
                 key: "foo",
                 value: "bar"
               }
             } = result
    end

    test "converts Maelstrom write_ok message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "write_ok",
          "in_reply_to" => 1
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Write.Ok{
                 type: :write_ok,
                 in_reply_to: 1
               }
             } = result
    end

    test "converts Maelstrom cas message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "cas",
          "msg_id" => 1,
          "key" => "foo",
          "from" => "old_value",
          "to" => "new_value"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %Cas{
                 type: :cas,
                 msg_id: 1,
                 key: "foo",
                 from: "old_value",
                 to: "new_value"
               }
             } = result
    end

    test "converts Maelstrom cas_ok message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "cas_ok",
          "in_reply_to" => 1
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Cas.Ok{
                 type: :cas_ok,
                 in_reply_to: 1
               }
             } = result
    end

    test "converts Maelstrom error message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "c0",
        "body" => %{
          "type" => "error",
          "in_reply_to" => 1,
          "code" => 20,
          "text" => "key does not exist"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "c0",
               body: %Error{
                 type: :error,
                 in_reply_to: 1,
                 code: 20,
                 text: "key does not exist"
               }
             } = result
    end

    test "converts VSR prepare message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "prepare",
          "view" => 1,
          "op_number" => 5,
          "operation" => ["write", "key", "value"],
          "commit_number" => 4,
          "from" => "client_ref"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "n1",
               body: %Prepare{
                 view: 1,
                 op_number: 5,
                 operation: ["write", "key", "value"],
                 commit_number: 4,
                 from: "client_ref"
               }
             } = result
    end

    test "converts VSR prepare_ok message correctly" do
      json_map = %{
        "src" => "n1",
        "dest" => "n0",
        "body" => %{
          "type" => "prepare_ok",
          "view" => 1,
          "op_number" => 5,
          "replica" => "n1"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n1",
               dest: "n0",
               body: %PrepareOk{
                 view: 1,
                 op_number: 5,
                 replica: "n1"
               }
             } = result
    end

    test "converts VSR commit message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "commit",
          "view" => 1,
          "commit_number" => 5
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "n1",
               body: %Commit{
                 view: 1,
                 commit_number: 5
               }
             } = result
    end

    test "converts VSR client_request message correctly" do
      json_map = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "client_request",
          "operation" => ["read", "key"],
          "from" => "client_ref",
          "read_only" => true,
          "client_key" => "unique_key"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: %ClientRequest{
                 operation: ["read", "key"],
                 from: "client_ref",
                 read_only: true,
                 client_key: "unique_key"
               }
             } = result
    end

    test "converts VSR heartbeat message correctly" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "heartbeat"
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "n1",
               body: %Heartbeat{}
             } = result
    end

    test "handles complex nested data structures" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "prepare",
          "view" => 1,
          "op_number" => 5,
          "operation" => %{"type" => "write", "key" => "foo", "value" => %{"nested" => true}},
          "commit_number" => 4,
          "from" => %{"client" => "test", "ref" => "abc123"}
        }
      }

      result = Message.from_json_map(json_map)

      assert %Message{
               src: "n0",
               dest: "n1",
               body: %Prepare{
                 view: 1,
                 op_number: 5,
                 operation: %{"type" => "write", "key" => "foo", "value" => %{"nested" => true}},
                 commit_number: 4,
                 from: %{"client" => "test", "ref" => "abc123"}
               }
             } = result
    end

    test "raises when message type is unknown" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "unknown_message_type",
          "field" => "value"
        }
      }

      assert_raise KeyError, fn ->
        Message.from_json_map(json_map)
      end
    end

    test "raises when required field is missing" do
      json_map = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "init",
          "msg_id" => 1
          # node_id and node_ids are missing
        }
      }

      assert_raise KeyError, fn ->
        Message.from_json_map(json_map)
      end
    end
  end

  describe "new/3" do
    test "creates message with Maelstrom body" do
      body = %Init{type: :init, msg_id: 1, node_id: "n0", node_ids: ["n0"]}
      message = Message.new("c0", "n0", body)

      assert %Message{
               src: "c0",
               dest: "n0",
               body: ^body
             } = message
    end

    test "creates message with VSR body" do
      body = %Prepare{
        view: 1,
        op_number: 5,
        operation: ["write", "key", "value"],
        commit_number: 4,
        from: "ref"
      }

      message = Message.new("n0", "n1", body)

      assert %Message{
               src: "n0",
               dest: "n1",
               body: ^body
             } = message
    end
  end

  describe "JSON encoding" do
    test "Maelstrom messages can be JSON encoded" do
      init = %Init{type: :init, msg_id: 1, node_id: "n0", node_ids: ["n0", "n1"]}
      message = Message.new("c0", "n0", init)

      json_string = JSON.encode!(message)
      decoded = JSON.decode!(json_string)

      assert %{
               "src" => "c0",
               "dest" => "n0",
               "body" => %{
                 "type" => "init",
                 "msg_id" => 1,
                 "node_id" => "n0",
                 "node_ids" => ["n0", "n1"]
               }
             } = decoded
    end

    test "VSR messages can be JSON encoded" do
      prepare = %Prepare{
        view: 1,
        op_number: 5,
        operation: ["write", "key", "value"],
        commit_number: 4,
        from: "ref"
      }

      message = Message.new("n0", "n1", prepare)

      json_string = JSON.encode!(message)
      decoded = JSON.decode!(json_string)

      assert %{
               "src" => "n0",
               "dest" => "n1",
               "body" => %{
                 "type" => "prepare",
                 "view" => 1,
                 "op_number" => 5,
                 "operation" => ["write", "key", "value"],
                 "commit_number" => 4,
                 "from" => "ref"
               }
             } = decoded
    end
  end

  describe "round-trip conversion" do
    test "Maelstrom init message round-trip" do
      original_json = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{
          "type" => "init",
          "msg_id" => 1,
          "node_id" => "n0",
          "node_ids" => ["n0", "n1", "n2"]
        }
      }

      message = Message.from_json_map(original_json)
      encoded = JSON.encode!(message)
      decoded = JSON.decode!(encoded)

      assert decoded == original_json
    end

    test "VSR prepare message round-trip" do
      original_json = %{
        "src" => "n0",
        "dest" => "n1",
        "body" => %{
          "type" => "prepare",
          "view" => 1,
          "op_number" => 5,
          "operation" => ["write", "key", "value"],
          "commit_number" => 4,
          "from" => "client_ref"
        }
      }

      message = Message.from_json_map(original_json)
      encoded = JSON.encode!(message)
      decoded = JSON.decode!(encoded)

      assert decoded == original_json
    end
  end
end
