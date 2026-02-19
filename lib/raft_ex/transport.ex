defmodule RaftEx.Transport do
  @moduledoc """
  Transport endpoint resolution for Raft nodes.

  Provides node_id -> {host, port} lookup with optional app-config overrides.
  """

  @default_host "127.0.0.1"
  @default_port_base 20_000
  @default_port_span 30_000

  @spec ensure_cluster_endpoints([atom()], map()) :: map()
  def ensure_cluster_endpoints(cluster, overrides \\ %{}) do
    existing = Application.get_env(:raft_ex, :node_endpoints, %{})
    merged = Map.merge(existing, normalize_overrides(overrides))

    used_ports = merged |> Map.values() |> Enum.map(fn {_host, port} -> port end) |> MapSet.new()

    {final_map, _used} =
      Enum.reduce(cluster, {merged, used_ports}, fn node_id, {acc_map, acc_used} ->
        if Map.has_key?(acc_map, node_id) do
          {acc_map, acc_used}
        else
          port = allocate_port(node_id, acc_used)
          host = @default_host
          {Map.put(acc_map, node_id, {host, port}), MapSet.put(acc_used, port)}
        end
      end)

    Application.put_env(:raft_ex, :node_endpoints, final_map)
    final_map
  end

  @spec endpoint_for(atom()) :: {String.t(), non_neg_integer()}
  def endpoint_for(node_id) do
    endpoints = Application.get_env(:raft_ex, :node_endpoints, %{})

    case Map.get(endpoints, node_id) do
      {host, port} when is_binary(host) and is_integer(port) -> {host, port}
      _ -> {@default_host, default_port(node_id)}
    end
  end

  @spec default_port(atom()) :: non_neg_integer()
  def default_port(node_id) do
    @default_port_base + :erlang.phash2(node_id, @default_port_span)
  end

  defp normalize_overrides(overrides) do
    Enum.reduce(overrides, %{}, fn
      {node_id, {host, port}}, acc when is_atom(node_id) and is_binary(host) and is_integer(port) ->
        Map.put(acc, node_id, {host, port})

      _, acc ->
        acc
    end)
  end

  defp allocate_port(node_id, used_ports) do
    start = default_port(node_id)

    Enum.find(start..65_535, fn port ->
      not MapSet.member?(used_ports, port) and port_available?(port)
    end) || raise "unable to allocate TCP port for #{inspect(node_id)}"
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end

