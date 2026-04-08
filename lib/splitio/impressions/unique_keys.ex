defmodule Splitio.Impressions.UniqueKeys do
  @moduledoc false

  use GenServer

  defstruct keys: %{}

  @type unique_keys :: %{String.t() => MapSet.t(String.t())}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec record(String.t(), String.t()) :: :ok
  def record(feature, key) when is_binary(feature) and is_binary(key) do
    GenServer.cast(__MODULE__, {:record, feature, key})
  end

  @spec pop_keys() :: unique_keys()
  def pop_keys do
    GenServer.call(__MODULE__, :pop_keys)
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:record, feature, key}, state) do
    keys = Map.update(state.keys, feature, MapSet.new([key]), &MapSet.put(&1, key))
    {:noreply, %{state | keys: keys}}
  end

  @impl true
  def handle_call(:pop_keys, _from, state) do
    {:reply, state.keys, %{state | keys: %{}}}
  end
end
