defmodule Splitio.Manager do
  @moduledoc """
  Manager API for inspecting available feature flags.
  """

  alias Splitio.Storage
  alias Splitio.Models.{Split, SplitView}

  @doc """
  Get all split views.
  """
  @spec splits() :: [SplitView.t()]
  def splits do
    Storage.get_splits()
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(&SplitView.from_split/1)
  end

  @doc """
  Get a single split view by name.
  """
  @spec split(String.t()) :: SplitView.t() | nil
  def split(name) do
    case Storage.get_split(name) do
      {:ok, %Split{status: :active} = s} -> SplitView.from_split(s)
      _ -> nil
    end
  end

  @doc """
  Get all split names.
  """
  @spec split_names() :: [String.t()]
  def split_names do
    Storage.get_splits()
    |> Enum.filter(&(&1.status == :active))
    |> Enum.map(& &1.name)
  end
end
