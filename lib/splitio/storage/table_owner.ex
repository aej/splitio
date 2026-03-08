defmodule Splitio.Storage.TableOwner do
  @moduledoc """
  GenServer that owns ETS tables.

  ETS tables are tied to the process that creates them - if that process
  dies, the table is deleted. This GenServer owns the tables and survives
  crashes of other processes, ensuring data persistence within the node.
  """

  use GenServer

  @tables [
    :splitio_splits,
    :splitio_segments,
    :splitio_large_segments,
    :splitio_rule_based_segments,
    :splitio_metadata,
    :splitio_impressions_cache
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    tables = create_tables()
    {:ok, %{tables: tables}}
  end

  defp create_tables do
    Enum.map(@tables, fn table_name ->
      opts = table_options(table_name)
      table = :ets.new(table_name, opts)
      {table_name, table}
    end)
  end

  defp table_options(:splitio_impressions_cache) do
    # Public for high-frequency reads/writes from impression observer
    [:set, :public, :named_table, read_concurrency: true, write_concurrency: true]
  end

  defp table_options(_table) do
    # Protected tables - only owner can write, anyone can read
    [:set, :public, :named_table, read_concurrency: true]
  end

  @doc "Check if all tables exist"
  @spec tables_ready?() :: boolean()
  def tables_ready? do
    Enum.all?(@tables, fn table ->
      :ets.whereis(table) != :undefined
    end)
  end

  @doc "Get list of table names"
  @spec table_names() :: [atom()]
  def table_names, do: @tables
end
