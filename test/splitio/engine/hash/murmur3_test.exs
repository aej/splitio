defmodule Splitio.Engine.Hash.Murmur3Test do
  use ExUnit.Case, async: true

  alias Splitio.Engine.Hash.Murmur3

  describe "hash32/2" do
    test "produces consistent results" do
      assert Murmur3.hash32("test", 0) == Murmur3.hash32("test", 0)
      assert Murmur3.hash32("hello", 123) == Murmur3.hash32("hello", 123)
    end

    test "different inputs produce different hashes" do
      assert Murmur3.hash32("test1", 0) != Murmur3.hash32("test2", 0)
    end

    test "different seeds produce different hashes" do
      assert Murmur3.hash32("test", 0) != Murmur3.hash32("test", 1)
    end

    test "handles empty string" do
      result = Murmur3.hash32("", 0)
      assert is_integer(result)
    end

    test "handles various lengths" do
      for len <- [1, 2, 3, 4, 5, 10, 100] do
        input = String.duplicate("a", len)
        result = Murmur3.hash32(input, 0)
        assert is_integer(result)
        assert result >= 0
      end
    end

    # Known test vectors for MurmurHash3 32-bit
    test "known vectors" do
      # These values should match reference implementations
      assert Murmur3.hash32("", 0) == 0
      assert Murmur3.hash32("", 1) == 0x514E28B7
    end
  end

  describe "hash128/2" do
    test "produces 128-bit binary" do
      result = Murmur3.hash128("test", 0)
      assert byte_size(result) == 16
    end

    test "produces consistent results" do
      assert Murmur3.hash128("test", 0) == Murmur3.hash128("test", 0)
    end

    test "different inputs produce different hashes" do
      assert Murmur3.hash128("test1", 0) != Murmur3.hash128("test2", 0)
    end
  end

  describe "hash128_lower64/2" do
    test "returns lower 64 bits as integer" do
      result = Murmur3.hash128_lower64("test", 0)
      assert is_integer(result)
      assert result >= 0
    end
  end
end
