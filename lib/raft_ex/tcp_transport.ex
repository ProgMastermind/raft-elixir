defmodule RaftEx.TcpTransport do
  @moduledoc """
  Outbound TCP transport for Raft RPC messages.
  """

  alias RaftEx.Transport

  @connect_timeout_ms 300
  @send_retries 1

  @spec send(atom(), term()) :: :ok | {:error, term()}
  def send(peer_id, message) do
    {host, port} = Transport.endpoint_for(peer_id)
    payload = :erlang.term_to_binary(message)
    frame = <<byte_size(payload)::32-big, payload::binary>>
    do_send(host, port, frame, @send_retries)
  end

  defp do_send(_host, _port, _frame, retries_left) when retries_left < 0 do
    {:error, :tcp_send_failed}
  end

  defp do_send(host, port, frame, retries_left) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout_ms) do
      {:ok, socket} ->
        result = :gen_tcp.send(socket, frame)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        if retries_left > 0 do
          Process.sleep(10)
          do_send(host, port, frame, retries_left - 1)
        else
          {:error, reason}
        end
    end
  end
end

