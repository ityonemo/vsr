defmodule VsrKvTest do
  use ExUnit.Case
  doctest VsrKv

  test "greets the world" do
    assert VsrKv.hello() == :world
  end
end
