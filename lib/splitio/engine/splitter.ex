defmodule Splitio.Engine.Splitter do
  @moduledoc """
  Bucketing and treatment selection logic.

  Handles:
  - Hash-based bucket calculation (1-100)
  - Treatment selection from partitions
  """

  alias Splitio.Engine.Hash.{Murmur3, Legacy}
  alias Splitio.Models.Partition

  @doc """
  Calculate the bucket number (1-100) for a key.

  Uses murmur3 or legacy hash based on the algorithm specified.
  """
  @spec calculate_bucket(String.t(), integer(), :murmur | :legacy) :: 1..100
  def calculate_bucket(key, seed, algo \\ :murmur) do
    hash =
      case algo do
        :murmur -> Murmur3.hash32(key, seed)
        :legacy -> Legacy.hash(key, seed)
      end

    # abs(hash % 100) + 1 gives bucket 1-100
    abs(rem(hash, 100)) + 1
  end

  @doc """
  Select treatment based on bucket and partitions.

  Partitions are processed in order, accumulating sizes until
  the bucket falls within the accumulated range.

  ## Example

      partitions = [%Partition{treatment: "on", size: 50}, %Partition{treatment: "off", size: 50}]
      select_treatment(partitions, 25) # => "on"
      select_treatment(partitions, 75) # => "off"

  """
  @spec select_treatment([Partition.t()], 1..100) :: String.t()
  def select_treatment(partitions, bucket) do
    select_treatment_acc(partitions, bucket, 0)
  end

  defp select_treatment_acc([%Partition{treatment: treatment, size: size} | rest], bucket, acc) do
    new_acc = acc + size

    if bucket <= new_acc do
      treatment
    else
      select_treatment_acc(rest, bucket, new_acc)
    end
  end

  defp select_treatment_acc([], _bucket, _acc) do
    # Should not happen if partitions sum to 100
    # Return control as fallback
    "control"
  end

  @doc """
  Get treatment with all details needed for evaluation.

  Returns the treatment name based on the bucketing key, seed, and partitions.
  """
  @spec get_treatment(String.t(), integer(), [Partition.t()], :murmur | :legacy) :: String.t()
  def get_treatment(bucketing_key, seed, partitions, algo \\ :murmur) do
    bucket = calculate_bucket(bucketing_key, seed, algo)
    select_treatment(partitions, bucket)
  end
end
