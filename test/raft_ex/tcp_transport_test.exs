defmodule RaftEx.TcpTransportTest do
  use ExUnit.Case, async: false

  alias RaftEx.RPC.RequestVote

  defp clean_node_files(node_id) do
    tmp = System.tmp_dir!()
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_meta.dets"))
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_log.dets"))
    File.rm(Path.join(tmp, "raft_ex_#{node_id}_snapshot.bin"))
  end

  describe "tcp transport framing and behavior" do
    test "send returns error for unreachable peer" do
      peer = :"unreachable_peer_#{:erlang.unique_integer([:positive])}"

      rpc = %RequestVote{
        term: 1,
        candidate_id: :candidate_a,
        last_log_index: 0,
        last_log_term: 0
      }

      assert match?({:error, _}, RaftEx.TcpTransport.send(peer, rpc))
    end

    test "framed tcp message is decoded and dispatched to local server" do
      node_id = :"tcp_frame_#{:erlang.unique_integer([:positive])}"
      cluster = [node_id]
      clean_node_files(node_id)

      {:ok, _} = RaftEx.start_node(node_id, cluster)

      rpc = %RequestVote{
        term: 9,
        candidate_id: :candidate_frame,
        last_log_index: 0,
        last_log_term: 0
      }

      :ok = RaftEx.TcpTransport.send(node_id, rpc)
      Process.sleep(100)

      status = RaftEx.status(node_id)
      assert status.current_term >= 9

      RaftEx.stop_node(node_id)
      clean_node_files(node_id)
    end

    test "listener handles partial frame reads correctly" do
      node_id = :"tcp_partial_#{:erlang.unique_integer([:positive])}"
      cluster = [node_id]
      clean_node_files(node_id)

      {:ok, _} = RaftEx.start_node(node_id, cluster)

      {host, port} = RaftEx.Transport.endpoint_for(node_id)
      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500)

      rpc = %RequestVote{
        term: 11,
        candidate_id: :candidate_partial,
        last_log_index: 0,
        last_log_term: 0
      }

      payload = :erlang.term_to_binary(rpc)
      frame = <<byte_size(payload)::32-big, payload::binary>>
      <<part1::binary-size(2), part2::binary>> = frame

      :ok = :gen_tcp.send(socket, part1)
      Process.sleep(20)
      :ok = :gen_tcp.send(socket, part2)
      :gen_tcp.close(socket)

      Process.sleep(100)
      status = RaftEx.status(node_id)
      assert status.current_term >= 11

      RaftEx.stop_node(node_id)
      clean_node_files(node_id)
    end

    test "dropped connection with incomplete frame does not crash node" do
      node_id = :"tcp_drop_#{:erlang.unique_integer([:positive])}"
      cluster = [node_id]
      clean_node_files(node_id)

      {:ok, _} = RaftEx.start_node(node_id, cluster)

      {host, port} = RaftEx.Transport.endpoint_for(node_id)
      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500)
      :ok = :gen_tcp.send(socket, <<0, 0>>)
      :gen_tcp.close(socket)

      Process.sleep(80)
      status = RaftEx.status(node_id)
      assert is_map(status)

      RaftEx.stop_node(node_id)
      clean_node_files(node_id)
    end

    test "listener accepts multiple framed messages on reused socket" do
      node_id = :"tcp_reuse_#{:erlang.unique_integer([:positive])}"
      cluster = [node_id]
      clean_node_files(node_id)

      {:ok, _} = RaftEx.start_node(node_id, cluster)

      {host, port} = RaftEx.Transport.endpoint_for(node_id)
      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 500)

      rpc_a = %RequestVote{term: 13, candidate_id: :reuse_a, last_log_index: 0, last_log_term: 0}
      payload_a = :erlang.term_to_binary(rpc_a)
      frame_a = <<byte_size(payload_a)::32-big, payload_a::binary>>

      rpc_b = %RequestVote{term: 14, candidate_id: :reuse_b, last_log_index: 0, last_log_term: 0}
      payload_b = :erlang.term_to_binary(rpc_b)
      frame_b = <<byte_size(payload_b)::32-big, payload_b::binary>>

      :ok = :gen_tcp.send(socket, frame_a)
      :ok = :gen_tcp.send(socket, frame_b)
      :gen_tcp.close(socket)

      Process.sleep(120)
      s = RaftEx.status(node_id)
      assert s.current_term >= 14

      RaftEx.stop_node(node_id)
      clean_node_files(node_id)
    end
  end
end

