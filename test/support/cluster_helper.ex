defmodule ClusterHelper do
  @moduledoc """
  Helper for distributed node testing using :peer module.

  To run distributed tests:

      elixir --sname test -S mix test --only distributed
  """

  def start_nodes(names) do
    # Start distributed mode if not already active
    unless Node.alive?() do
      # Generate random node name to avoid conflicts
      node_name = :"test_#{:rand.uniform(999_999)}"
      {:ok, _} = :net_kernel.start([node_name, :shortnames])
    end

    # Get current cookie and set on peer nodes
    cookie = Node.get_cookie()

    # Start peer nodes
    Enum.map(names, fn name ->
      cookie_arg = cookie |> Atom.to_charlist()
      {:ok, pid, node} = :peer.start_link(%{name: name, args: [~c"-setcookie", cookie_arg]})

      # Add code paths from current node
      :erpc.call(node, :code, :add_paths, [:code.get_path()])

      # Start application on peer node
      {:ok, _apps} = :erpc.call(node, Application, :ensure_all_started, [:expirable_store])

      {pid, node}
    end)
  end

  def stop_nodes(nodes) do
    Enum.each(nodes, fn {pid, _node} ->
      try do
        :peer.stop(pid)
      catch
        _, _ -> :ok
      end
    end)
  end
end
