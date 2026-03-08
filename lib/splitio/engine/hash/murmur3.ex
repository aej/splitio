defmodule Splitio.Engine.Hash.Murmur3 do
  @moduledoc """
  Pure Elixir implementation of MurmurHash3 32-bit and 128-bit variants.

  Used for:
  - Bucketing: hash32 with seed for treatment selection
  - Impression deduplication: hash128 for cache key
  """

  import Bitwise

  @c1_32 0xCC9E2D51
  @c2_32 0x1B873593
  @r1_32 15
  @r2_32 13
  @m_32 5
  @n_32 0xE6546B64

  @doc """
  MurmurHash3 32-bit hash.

  ## Examples

      iex> Splitio.Engine.Hash.Murmur3.hash32("test", 0)
      3127628307

  """
  @spec hash32(binary(), integer()) :: non_neg_integer()
  def hash32(data, seed) when is_binary(data) and is_integer(seed) do
    seed = seed &&& 0xFFFFFFFF
    len = byte_size(data)

    # Process body (4-byte chunks)
    {hash, remainder} = process_body_32(data, seed)

    # Process tail (remaining bytes)
    hash = process_tail_32(remainder, hash)

    # Finalization
    finalize_32(hash, len)
  end

  defp process_body_32(data, hash) do
    process_body_32(data, hash, <<>>)
  end

  defp process_body_32(<<k::little-32, rest::binary>>, hash, _acc) do
    k = k * @c1_32 &&& 0xFFFFFFFF
    k = rotl32(k, @r1_32)
    k = k * @c2_32 &&& 0xFFFFFFFF

    hash = bxor(hash, k)
    hash = rotl32(hash, @r2_32)
    hash = hash * @m_32 + @n_32 &&& 0xFFFFFFFF

    process_body_32(rest, hash, <<>>)
  end

  defp process_body_32(remainder, hash, _acc) do
    {hash, remainder}
  end

  defp process_tail_32(<<>>, hash), do: hash

  defp process_tail_32(tail, hash) do
    k =
      case byte_size(tail) do
        3 ->
          <<b0, b1, b2>> = tail
          (b2 <<< 16 ||| b1 <<< 8 ||| b0) &&& 0xFFFFFFFF

        2 ->
          <<b0, b1>> = tail
          (b1 <<< 8 ||| b0) &&& 0xFFFFFFFF

        1 ->
          <<b0>> = tail
          b0
      end

    k = k * @c1_32 &&& 0xFFFFFFFF
    k = rotl32(k, @r1_32)
    k = k * @c2_32 &&& 0xFFFFFFFF
    bxor(hash, k)
  end

  defp finalize_32(hash, len) do
    hash = bxor(hash, len)
    hash = fmix32(hash)
    hash
  end

  defp fmix32(h) do
    h = bxor(h, h >>> 16)
    h = h * 0x85EBCA6B &&& 0xFFFFFFFF
    h = bxor(h, h >>> 13)
    h = h * 0xC2B2AE35 &&& 0xFFFFFFFF
    bxor(h, h >>> 16)
  end

  defp rotl32(x, r) do
    (x <<< r ||| x >>> (32 - r)) &&& 0xFFFFFFFF
  end

  # MurmurHash3 128-bit (x64 variant)
  @c1_128 0x87C37B91114253D5
  @c2_128 0x4CF5AD432745937F

  @doc """
  MurmurHash3 128-bit hash (x64 variant).
  Returns a 128-bit binary.

  ## Examples

      iex> Splitio.Engine.Hash.Murmur3.hash128("test", 0)
      <<...::128>>

  """
  @spec hash128(binary(), integer()) :: binary()
  def hash128(data, seed) when is_binary(data) and is_integer(seed) do
    seed = seed &&& 0xFFFFFFFFFFFFFFFF
    h1 = seed
    h2 = seed
    len = byte_size(data)

    # Process body (16-byte chunks)
    {h1, h2, remainder} = process_body_128(data, h1, h2)

    # Process tail
    {h1, h2} = process_tail_128(remainder, h1, h2)

    # Finalization
    finalize_128(h1, h2, len)
  end

  defp process_body_128(<<k1::little-64, k2::little-64, rest::binary>>, h1, h2) do
    k1 = k1 * @c1_128 &&& 0xFFFFFFFFFFFFFFFF
    k1 = rotl64(k1, 31)
    k1 = k1 * @c2_128 &&& 0xFFFFFFFFFFFFFFFF
    h1 = bxor(h1, k1)
    h1 = rotl64(h1, 27)
    h1 = h1 + h2 &&& 0xFFFFFFFFFFFFFFFF
    h1 = h1 * 5 + 0x52DCE729 &&& 0xFFFFFFFFFFFFFFFF

    k2 = k2 * @c2_128 &&& 0xFFFFFFFFFFFFFFFF
    k2 = rotl64(k2, 33)
    k2 = k2 * @c1_128 &&& 0xFFFFFFFFFFFFFFFF
    h2 = bxor(h2, k2)
    h2 = rotl64(h2, 31)
    h2 = h2 + h1 &&& 0xFFFFFFFFFFFFFFFF
    h2 = h2 * 5 + 0x38495AB5 &&& 0xFFFFFFFFFFFFFFFF

    process_body_128(rest, h1, h2)
  end

  defp process_body_128(remainder, h1, h2) do
    {h1, h2, remainder}
  end

  defp process_tail_128(tail, h1, h2) do
    tail_len = byte_size(tail)
    {k1, k2} = build_tail_keys_128(tail, tail_len)

    h2 =
      if tail_len >= 9 do
        k2 = k2 * @c2_128 &&& 0xFFFFFFFFFFFFFFFF
        k2 = rotl64(k2, 33)
        k2 = k2 * @c1_128 &&& 0xFFFFFFFFFFFFFFFF
        bxor(h2, k2)
      else
        h2
      end

    h1 =
      if tail_len >= 1 do
        k1 = k1 * @c1_128 &&& 0xFFFFFFFFFFFFFFFF
        k1 = rotl64(k1, 31)
        k1 = k1 * @c2_128 &&& 0xFFFFFFFFFFFFFFFF
        bxor(h1, k1)
      else
        h1
      end

    {h1, h2}
  end

  defp build_tail_keys_128(_tail, len) when len == 0 do
    {0, 0}
  end

  defp build_tail_keys_128(tail, len) do
    # Build k1 from first 8 bytes or less
    k1_bytes = min(8, len)
    <<k1_data::binary-size(k1_bytes), k2_data::binary>> = tail
    k1 = bytes_to_int64_le(k1_data, k1_bytes)

    # Build k2 from remaining bytes (9-15)
    k2_len = len - 8

    k2 =
      if k2_len > 0 do
        bytes_to_int64_le(k2_data, k2_len)
      else
        0
      end

    {k1, k2}
  end

  defp bytes_to_int64_le(data, len) do
    data
    |> :binary.bin_to_list()
    |> Enum.take(len)
    |> Enum.with_index()
    |> Enum.reduce(0, fn {byte, idx}, acc ->
      acc ||| byte <<< (idx * 8)
    end)
  end

  defp finalize_128(h1, h2, len) do
    h1 = bxor(h1, len) &&& 0xFFFFFFFFFFFFFFFF
    h2 = bxor(h2, len) &&& 0xFFFFFFFFFFFFFFFF

    h1 = h1 + h2 &&& 0xFFFFFFFFFFFFFFFF
    h2 = h2 + h1 &&& 0xFFFFFFFFFFFFFFFF

    h1 = fmix64(h1)
    h2 = fmix64(h2)

    h1 = h1 + h2 &&& 0xFFFFFFFFFFFFFFFF
    h2 = h2 + h1 &&& 0xFFFFFFFFFFFFFFFF

    <<h1::64, h2::64>>
  end

  defp fmix64(k) do
    k = bxor(k, k >>> 33)
    k = k * 0xFF51AFD7ED558CCD &&& 0xFFFFFFFFFFFFFFFF
    k = bxor(k, k >>> 33)
    k = k * 0xC4CEB9FE1A85EC53 &&& 0xFFFFFFFFFFFFFFFF
    bxor(k, k >>> 33)
  end

  defp rotl64(x, r) do
    (x <<< r ||| x >>> (64 - r)) &&& 0xFFFFFFFFFFFFFFFF
  end

  @doc """
  Get the lower 64 bits of a 128-bit hash as an integer.
  Used for impression deduplication cache keys.
  """
  @spec hash128_lower64(binary(), integer()) :: non_neg_integer()
  def hash128_lower64(data, seed) do
    <<_h1::64, h2::64>> = hash128(data, seed)
    h2
  end
end
