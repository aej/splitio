defmodule Splitio.Engine.Hash.Legacy do
  @moduledoc """
  Legacy Java-style hash function for Split SDK.

  Used when split.algo == 1 (legacy mode).
  This is the same hash algorithm used by Java's String.hashCode()
  combined with XOR of the seed.
  """

  import Bitwise

  @doc """
  Calculate legacy hash for bucketing.

  The algorithm is:
  1. Calculate Java-style String.hashCode() for the key
  2. XOR the result with the seed
  3. Handle integer overflow (32-bit signed)

  ## Examples

      iex> Splitio.Engine.Hash.Legacy.hash("test", 123)
      3556529

  """
  @spec hash(String.t(), integer()) :: integer()
  def hash(key, seed) when is_binary(key) and is_integer(seed) do
    h = java_string_hash(key)
    xor_with_seed(h, seed)
  end

  # Java String.hashCode() implementation
  # h = 0; for (char c : chars) h = 31 * h + c
  defp java_string_hash(str) do
    str
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, h ->
      # Java uses 32-bit signed integers with overflow
      h = (31 * h + char) |> to_signed_32()
      h
    end)
  end

  defp xor_with_seed(h, seed) do
    bxor(h, seed) |> to_signed_32()
  end

  # Convert to 32-bit signed integer (Java semantics)
  defp to_signed_32(n) do
    # Mask to 32 bits
    n = n &&& 0xFFFFFFFF

    # Convert to signed if high bit is set
    if (n &&& 0x80000000) != 0 do
      n - 0x100000000
    else
      n
    end
  end
end
