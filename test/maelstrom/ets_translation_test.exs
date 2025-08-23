defmodule EtsTranslationTest do
  use ExUnit.Case, async: true

  test "ETS translation layer stores and retrieves GenServer.from tuples" do
    unique_id = System.unique_integer([:positive])
    node_id = "test_ets_#{unique_id}"
    temp_dir = System.tmp_dir!()
    dets_file = Path.join(temp_dir, "ets_test_#{unique_id}_log.dets")

    # Start MaelstromKv with ETS table
    {:ok, pid} =
      start_supervised(
        {MaelstromKv,
         [
           node_id: node_id,
           dets_file: dets_file,
           cluster_size: 1,
           replicas: []
         ]},
        id: :"ets_test_#{unique_id}"
      )

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    # Create a fake GenServer.from tuple
    fake_from = {self(), make_ref()}

    # Store the from tuple and get hash via GenServer call
    from_hash = GenServer.call(pid, {:store_from, fake_from})
    assert is_integer(from_hash)

    # Retrieve the from tuple using hash
    assert {:ok, ^fake_from} = GenServer.call(pid, {:fetch_from, from_hash})

    # Test fetching non-existent hash
    assert {:error, :not_found} = GenServer.call(pid, {:fetch_from, 999_999})

    # Delete the from tuple
    assert :ok = GenServer.call(pid, {:delete_from, from_hash})

    # Verify it's deleted
    assert {:error, :not_found} = GenServer.call(pid, {:fetch_from, from_hash})
  end

  test "ETS translation layer handles multiple from tuples" do
    unique_id = System.unique_integer([:positive])
    node_id = "multi_ets_#{unique_id}"
    temp_dir = System.tmp_dir!()
    dets_file = Path.join(temp_dir, "multi_ets_test_#{unique_id}_log.dets")

    # Start MaelstromKv with ETS table
    {:ok, pid} =
      start_supervised(
        {MaelstromKv,
         [
           node_id: node_id,
           dets_file: dets_file,
           cluster_size: 1,
           replicas: []
         ]},
        id: :"multi_ets_test_#{unique_id}"
      )

    # Clean up DETS file on test completion
    on_exit(fn ->
      File.rm(dets_file)
    end)

    # Store multiple from tuples via GenServer calls
    from1 = {self(), make_ref()}
    from2 = {self(), make_ref()}
    from3 = {self(), make_ref()}

    hash1 = GenServer.call(pid, {:store_from, from1})
    hash2 = GenServer.call(pid, {:store_from, from2})
    hash3 = GenServer.call(pid, {:store_from, from3})

    # Verify all are different hashes
    assert hash1 != hash2
    assert hash2 != hash3
    assert hash1 != hash3

    # Retrieve all
    assert {:ok, ^from1} = GenServer.call(pid, {:fetch_from, hash1})
    assert {:ok, ^from2} = GenServer.call(pid, {:fetch_from, hash2})
    assert {:ok, ^from3} = GenServer.call(pid, {:fetch_from, hash3})

    # Delete one and verify others remain
    GenServer.call(pid, {:delete_from, hash2})
    assert {:error, :not_found} = GenServer.call(pid, {:fetch_from, hash2})
    assert {:ok, ^from1} = GenServer.call(pid, {:fetch_from, hash1})
    assert {:ok, ^from3} = GenServer.call(pid, {:fetch_from, hash3})
  end
end
