defmodule RaftEx.TcpConnectionPool do
  @moduledoc """
  Shared outbound TCP connection pool keyed by Raft node id.
  """

  use GenServer

  alias RaftEx.Transport

  @connect_timeout_ms 300

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec send_frame(atom(), binary()) :: :ok | {:error, term()}
  def send_frame(peer_id, frame) do
    GenServer.call(__MODULE__, {:send_frame, peer_id, frame}, 1_000)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:send_frame, peer_id, frame}, _from, state) do
    {result, new_state} = send_with_reconnect(peer_id, frame, state)
    {:reply, result, new_state}
  end

  defp send_with_reconnect(peer_id, frame, state) do
    case ensure_socket(peer_id, state) do
      {{:ok, socket}, state_with_socket} ->
        case :gen_tcp.send(socket, frame) do
          :ok ->
            {:ok, state_with_socket}

          {:error, reason} ->
            :gen_tcp.close(socket)
            state_without_socket = Map.delete(state_with_socket, peer_id)

            case ensure_socket(peer_id, state_without_socket) do
              {{:ok, retry_socket}, retry_state} ->
                case :gen_tcp.send(retry_socket, frame) do
                  :ok -> {:ok, retry_state}
                  {:error, retry_reason} ->
                    :gen_tcp.close(retry_socket)
                    {{:error, retry_reason}, Map.delete(retry_state, peer_id)}
                end

              {{:error, conn_reason}, retry_state} ->
                {{:error, conn_reason || reason}, retry_state}
            end
        end

      {{:error, reason}, state_after_connect} ->
        {{:error, reason}, state_after_connect}
    end
  end

  defp ensure_socket(peer_id, state) do
    case Map.get(state, peer_id) do
      nil ->
        {connect_socket(peer_id), state}

      socket ->
        {{:ok, socket}, state}
    end
    |> maybe_put_socket(peer_id)
  end

  defp maybe_put_socket({{:ok, socket}, state}, peer_id), do: {{:ok, socket}, Map.put(state, peer_id, socket)}
  defp maybe_put_socket({error, state}, _peer_id), do: {error, state}

  defp connect_socket(peer_id) do
    {host, port} = Transport.endpoint_for(peer_id)
    :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @connect_timeout_ms)
  end
end

