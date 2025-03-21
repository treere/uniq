defmodule Ecto.TestAdapter do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Transaction

  @impl Ecto.Adapter
  defmacro __before_compile__(_opts), do: :ok

  @impl Ecto.Adapter
  def ensure_all_started(_, _) do
    {:ok, []}
  end

  @impl Ecto.Adapter
  def init(opts) do
    :ecto = opts[:otp_app]
    "user" = opts[:username]
    "pass" = opts[:password]
    "hello" = opts[:database]
    "local" = opts[:hostname]

    {:ok, Supervisor.child_spec({Task, fn -> :timer.sleep(:infinity) end}, []), %{meta: :meta}}
  end

  @impl Ecto.Adapter
  def checkout(mod, _opts, fun) do
    send(self(), {:checkout, fun})
    Process.put({mod, :checked_out?}, true)

    try do
      fun.()
    after
      Process.delete({mod, :checked_out?})
    end
  end

  @impl Ecto.Adapter
  def checked_out?(mod) do
    Process.get({mod, :checked_out?}) || false
  end

  ## Types

  @impl Ecto.Adapter
  def loaders(:binary_id, type), do: [Ecto.UUID, type]
  @impl Ecto.Adapter
  def loaders(_primitive, type), do: [type]

  @impl Ecto.Adapter
  def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  @impl Ecto.Adapter
  def dumpers(_primitive, type), do: [type]

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  @impl Ecto.Adapter.Schema
  def autogenerate(:embed_id), do: Ecto.UUID.autogenerate()
  @impl Ecto.Adapter.Schema
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  ## Queryable
  @impl Ecto.Adapter.Queryable
  def prepare(operation, query), do: {:nocache, {operation, query}}

  @impl Ecto.Adapter.Queryable
  def execute(_, _, {:nocache, {:all, query}}, _, _) do
    send(self(), {:all, query})
    Process.get(:test_repo_all_results) || results_for_all_query(query)
  end

  @impl Ecto.Adapter.Queryable
  def execute(_, _meta, {:nocache, {op, query}}, _params, _opts) do
    send(self(), {op, query})
    {1, nil}
  end

  @impl Ecto.Adapter.Queryable
  def stream(_, _meta, {:nocache, {:all, query}}, _params, _opts) do
    Stream.map([:execute], fn :execute ->
      send(self(), {:stream, query})
      results_for_all_query(query)
    end)
  end

  defp results_for_all_query(%{select: %{fields: [_ | _] = fields}}) do
    values = List.duplicate(nil, length(fields) - 1)
    {1, [[1 | values]]}
  end

  defp results_for_all_query(%{select: %{fields: []}}) do
    {1, [[]]}
  end

  ## Schema
  @impl Ecto.Adapter.Schema
  def insert_all(_, meta, header, rows, on_conflict, returning, placeholders, _opts) do
    meta =
      Map.merge(meta, %{
        header: header,
        on_conflict: on_conflict,
        returning: returning,
        placeholders: placeholders
      })

    send(self(), {:insert_all, meta, rows})
    {1, nil}
  end

  @impl Ecto.Adapter.Schema
  def insert(_, %{context: nil} = meta, fields, on_conflict, returning, _opts) do
    meta = Map.merge(meta, %{fields: fields, on_conflict: on_conflict, returning: returning})
    send(self(), {:insert, meta})
    {:ok, Enum.with_index(returning, 1)}
  end

  @impl Ecto.Adapter.Schema
  def insert(_, %{context: context}, _fields, _on_conflict, _returning, _opts) do
    context
  end

  # Notice the list of changes is never empty.
  @impl Ecto.Adapter.Schema
  def update(_, %{context: nil} = meta, [_ | _] = changes, filters, returning, _opts) do
    meta = Map.merge(meta, %{changes: changes, filters: filters, returning: returning})
    send(self(), {:update, meta})
    {:ok, Enum.zip(returning, 1..length(returning))}
  end

  @impl Ecto.Adapter.Schema
  def update(_, %{context: context}, [_ | _], _filters, _returning, _opts) do
    context
  end

  @impl Ecto.Adapter.Schema
  def delete(_, %{context: nil} = meta, filters, _returning, _opts) do
    meta = Map.merge(meta, %{filters: filters})
    send(self(), {:delete, meta})
    {:ok, []}
  end

  @impl Ecto.Adapter.Schema
  def delete(_, %{context: context}, _filters, _returning, _opts) do
    context
  end

  ## Transactions
  @impl Ecto.Adapter.Transaction
  def transaction(mod, _opts, fun) do
    # Makes transactions "trackable" in tests
    Process.put({mod, :in_transaction?}, true)
    send(self(), {:transaction, fun})

    try do
      {:ok, fun.()}
    catch
      :throw, {:ecto_rollback, value} ->
        {:error, value}
    after
      Process.delete({mod, :in_transaction?})
    end
  end

  @impl Ecto.Adapter.Transaction
  def in_transaction?(mod) do
    Process.get({mod, :in_transaction?}) || false
  end

  @impl Ecto.Adapter.Transaction
  def rollback(_, value) do
    send(self(), {:rollback, value})
    throw({:ecto_rollback, value})
  end
end

Application.put_env(:ecto, Ecto.TestRepo, user: "invalid")

defmodule Ecto.TestRepo do
  use Ecto.Repo, otp_app: :ecto, adapter: Ecto.TestAdapter

  def init(type, opts) do
    opts = [url: "ecto://user:pass@local/hello"] ++ opts
    opts[:parent] && send(opts[:parent], {__MODULE__, type, opts})
    {:ok, opts}
  end
end

Ecto.TestRepo.start_link()
