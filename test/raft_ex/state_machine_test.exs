defmodule RaftEx.StateMachineTest do
  use ExUnit.Case, async: true

  alias RaftEx.StateMachine

  describe "new/0 (§5.3)" do
    test "returns empty map" do
      assert StateMachine.new() == %{}
    end
  end

  describe "apply_command — set (§5.3)" do
    test "set stores value and returns {:ok, value}" do
      state = StateMachine.new()
      {new_state, result} = StateMachine.apply_command(state, {:set, "x", 42})
      assert result == {:ok, 42}
      assert new_state["x"] == 42
    end

    test "set overwrites existing value" do
      state = StateMachine.new()
      {state, _} = StateMachine.apply_command(state, {:set, "x", 1})
      {state, result} = StateMachine.apply_command(state, {:set, "x", 99})
      assert result == {:ok, 99}
      assert state["x"] == 99
    end
  end

  describe "apply_command — get (§5.3)" do
    test "get returns {:ok, value} for existing key" do
      state = StateMachine.new()
      {state, _} = StateMachine.apply_command(state, {:set, "y", "hello"})
      {_state, result} = StateMachine.apply_command(state, {:get, "y"})
      assert result == {:ok, "hello"}
    end

    test "get returns {:ok, nil} for missing key" do
      state = StateMachine.new()
      {_state, result} = StateMachine.apply_command(state, {:get, "missing"})
      assert result == {:ok, nil}
    end

    test "get does not modify state" do
      state = %{"a" => 1}
      {new_state, _} = StateMachine.apply_command(state, {:get, "a"})
      assert new_state == state
    end
  end

  describe "apply_command — delete (§5.3)" do
    test "delete removes key and returns :ok" do
      state = StateMachine.new()
      {state, _} = StateMachine.apply_command(state, {:set, "z", 7})
      {new_state, result} = StateMachine.apply_command(state, {:delete, "z"})
      assert result == :ok
      assert Map.has_key?(new_state, "z") == false
    end

    test "delete on missing key returns :ok (idempotent)" do
      state = StateMachine.new()
      {_state, result} = StateMachine.apply_command(state, {:delete, "nonexistent"})
      assert result == :ok
    end
  end

  describe "apply_command — noop (§8)" do
    test "noop does not change state and returns :ok" do
      state = %{"a" => 1, "b" => 2}
      {new_state, result} = StateMachine.apply_command(state, {:noop})
      assert result == :ok
      assert new_state == state
    end
  end

  describe "apply_entries (§5.3)" do
    test "applies entries in order and returns indexed results" do
      state = StateMachine.new()

      entries = [
        {1, 1, {:set, "a", 10}},
        {2, 1, {:set, "b", 20}},
        {3, 1, {:get, "a"}},
        {4, 1, {:delete, "b"}}
      ]

      {final_state, results} = StateMachine.apply_entries(state, entries)

      assert final_state["a"] == 10
      assert Map.has_key?(final_state, "b") == false

      assert results == [
               {1, {:ok, 10}},
               {2, {:ok, 20}},
               {3, {:ok, 10}},
               {4, :ok}
             ]
    end

    test "apply_entries on empty list returns unchanged state" do
      state = %{"x" => 1}
      {new_state, results} = StateMachine.apply_entries(state, [])
      assert new_state == state
      assert results == []
    end
  end

  describe "serialize/deserialize (§7)" do
    test "round-trip preserves state" do
      state = %{"a" => 1, "b" => [1, 2, 3], "c" => %{nested: true}}
      binary = StateMachine.serialize(state)
      assert is_binary(binary)
      assert StateMachine.deserialize(binary) == state
    end

    test "empty state round-trips correctly" do
      state = StateMachine.new()
      assert StateMachine.deserialize(StateMachine.serialize(state)) == state
    end
  end
end
