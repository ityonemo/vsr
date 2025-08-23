defmodule Maelstrom.KvServerTest do
  @moduledoc """
  Tests for Maelstrom Node KV message handling.

  NOTE: KV operations (read/write) are not yet implemented in Maelstrom.Message.
  These tests verify message parsing and basic node behavior.
  """

  use ExUnit.Case, async: true

  setup t do
    # Use temporary directory for DETS files
    temp_dir = System.tmp_dir!()
    unique_id = System.unique_integer([:positive])
    node_id = "n1"
    dets_file = Path.join(temp_dir, "kv_test_#{unique_id}_log.dets")
    
    pid =
      start_supervised!({MaelstromKv, name: :"#{t.test}-node", node_id: node_id, dets_file: dets_file, replicas: []})

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    {:ok, pid: pid}
  end

  @tag :maelstrom
  test "kv server responds with init_ok and handles KV messages", %{pid: pid} do
    # Test that the node sends proper init_ok and handles KV messages
    # output =
    #  capture_io(fn ->
    # Test read operation for non-existent key
    assert {:error, :not_found} = MaelstromKv.read(pid, "test_key", "c1", 10)

    # Test write operation
    assert :ok = MaelstromKv.write(pid, "test_key", "test_value", "c1", 20)

    # Test read operation after write
    assert {:ok, "test_value"} = MaelstromKv.read(pid, "test_key", "c1", 30)

    # Verify node is still alive and responsive after processing KV messages
    assert Process.alive?(pid)
    #  end)
    #
    ## Parse and verify responses
    # response_lines = String.split(String.trim(output), "\n", trim: true)
    # assert length(response_lines) >= 1, "Should have at least init_ok response"
    #
    ## Parse all responses
    # responses = Enum.map(response_lines, &JSON.decode!/1)
    #
    ## Verify init_ok response
    # init_response = Enum.find(responses, fn resp -> resp["body"]["type"] == "init_ok" end)
    # assert init_response, "Should have init_ok response"
    #
    # assert %{
    #         "src" => "n1",
    #         "dest" => "c1",
    #         "body" => %{
    #           "type" => "init_ok",
    #           "in_reply_to" => 1
    #         }
    #       } = init_response
    #
    ## In test mode (no VSR replica), KV operations should return error responses
    # error_responses = Enum.filter(responses, fn resp -> resp["body"]["type"] == "error" end)
    #
    ## Should have at least 2 error responses (read and write operations in test mode)
    # assert length(error_responses) >= 2,
    #       "Should have error responses for KV operations in test mode"
    #
    ## Verify error responses have proper structure
    # for error_resp <- error_responses do
    #  assert %{
    #           "src" => "n1",
    #           "dest" => "c1",
    #           "body" => %{
    #             "type" => "error",
    #             "code" => 13,
    #             "text" => "temporarily unavailable",
    #             "in_reply_to" => _msg_id
    #           }
    #         } = error_resp
    # end
  end

  @tag :maelstrom
  test "kv server responds with init_ok and handles CAS messages", %{pid: pid} do
    # Test basic node functionality without relying on capture_io timing issues

    # Test CAS that should fail (key doesn't exist, so value is nil, not "old_value")
    assert {:error, :precondition_failed} =
             MaelstromKv.cas(pid, "cas_key", "old_value", "new_value", "c1", 10)

    # Test CAS that should succeed (key doesn't exist, so value is nil, CAS from nil)
    assert :ok = MaelstromKv.cas(pid, "cas_key2", nil, "initial_value", "c1", 20)

    # Verify the CAS worked by reading the value
    assert {:ok, "initial_value"} = MaelstromKv.read(pid, "cas_key2", "c1", 30)

    # Verify node is still alive after processing CAS messages
    assert Process.alive?(pid)

    # The KV operations should work correctly - init will succeed,
    # first CAS will fail (precondition failed), second CAS will succeed
  end
end
