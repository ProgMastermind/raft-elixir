defmodule RaftEx.TcpTransport do
  @moduledoc """
  Outbound TCP transport for Raft RPC messages.
  """

  alias RaftEx.TcpConnectionPool

  @spec send(atom(), term()) :: :ok | {:error, term()}
  def send(peer_id, message) do
    payload = :erlang.term_to_binary(message)
    frame = <<byte_size(payload)::32-big, payload::binary>>
    TcpConnectionPool.send_frame(peer_id, frame)
  end
end

