defmodule RaftEx.TcpListener do
  @moduledoc """
  Per-node inbound TCP listener for Raft RPC messages.
  """

  require Logger

  alias RaftEx.Transport

  @accept_timeout_ms 1_000
  @recv_timeout_ms 1_000

  @spec start_link(atom()) :: {:ok, pid()} | {:error, term()}
  def start_link(node_id) do
    parent = self()

    pid =
      spawn_link(fn ->
        run(node_id, parent)
      end)

    receive do
      {:tcp_listener_started, ^pid} -> {:ok, pid}
      {:tcp_listener_error, ^pid, reason} -> {:error, reason}
    after
      2_000 -> {:error, :listener_start_timeout}
    end
  end

  defp run(node_id, parent) do
    {host, port} = Transport.endpoint_for(node_id)

    with {:ok, host_addr} <- parse_host(host),
         {:ok, listen_socket} <- :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: host_addr]) do
      send(parent, {:tcp_listener_started, self()})
      accept_loop(node_id, listen_socket)
    else
      {:error, reason} ->
        send(parent, {:tcp_listener_error, self(), reason})
    end
  end

  defp parse_host(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_loop(node_id, listen_socket) do
    case :gen_tcp.accept(listen_socket, @accept_timeout_ms) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(node_id, socket) end)
        accept_loop(node_id, listen_socket)

      {:error, :timeout} ->
        accept_loop(node_id, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[#{node_id}] tcp accept failed: #{inspect(reason)}")
        accept_loop(node_id, listen_socket)
    end
  end

  defp handle_connection(node_id, socket) do
    result =
      with {:ok, <<len::32-big>>} <- :gen_tcp.recv(socket, 4, @recv_timeout_ms),
           {:ok, payload} <- :gen_tcp.recv(socket, len, @recv_timeout_ms),
           {:ok, msg} <- safe_decode(payload) do
        dispatch_to_server(node_id, msg)
      end

    case result do
      :ok -> :ok
      {:error, :closed} -> :ok
      {:error, :timeout} -> :ok
      {:error, reason} ->
        Logger.warning("[#{node_id}] tcp connection handling failed: #{inspect(reason)}")
    end

    :gen_tcp.close(socket)
  end

  defp safe_decode(payload) do
    try do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    rescue
      _ -> {:error, :invalid_payload}
    end
  end

  defp dispatch_to_server(node_id, msg) do
    case Process.whereis(:"raft_server_#{node_id}") do
      nil -> :ok
      pid ->
        :gen_statem.cast(pid, msg)
        :ok
    end
  end
end

