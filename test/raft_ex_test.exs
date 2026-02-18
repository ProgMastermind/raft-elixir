defmodule RaftExTest do
  use ExUnit.Case
  doctest RaftEx

  test "greets the world" do
    assert RaftEx.hello() == :world
  end
end
