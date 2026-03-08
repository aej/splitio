defmodule Splitio.Engine.SplitterTest do
  use ExUnit.Case, async: true

  alias Splitio.Engine.Splitter
  alias Splitio.Models.Partition

  describe "calculate_bucket/3" do
    test "returns value between 1 and 100" do
      for _ <- 1..100 do
        key = "user_#{:rand.uniform(1_000_000)}"
        seed = :rand.uniform(1_000_000_000)
        bucket = Splitter.calculate_bucket(key, seed, :murmur)
        assert bucket >= 1 and bucket <= 100
      end
    end

    test "is deterministic" do
      bucket1 = Splitter.calculate_bucket("user123", 12345, :murmur)
      bucket2 = Splitter.calculate_bucket("user123", 12345, :murmur)
      assert bucket1 == bucket2
    end

    test "different keys get different buckets (usually)" do
      buckets =
        for i <- 1..1000 do
          Splitter.calculate_bucket("user#{i}", 12345, :murmur)
        end

      # Should have decent distribution
      unique_buckets = Enum.uniq(buckets) |> length()
      assert unique_buckets > 50
    end
  end

  describe "select_treatment/2" do
    test "selects from partitions based on bucket" do
      partitions = [
        %Partition{treatment: "on", size: 50},
        %Partition{treatment: "off", size: 50}
      ]

      assert Splitter.select_treatment(partitions, 1) == "on"
      assert Splitter.select_treatment(partitions, 50) == "on"
      assert Splitter.select_treatment(partitions, 51) == "off"
      assert Splitter.select_treatment(partitions, 100) == "off"
    end

    test "handles uneven partitions" do
      partitions = [
        %Partition{treatment: "a", size: 10},
        %Partition{treatment: "b", size: 20},
        %Partition{treatment: "c", size: 70}
      ]

      assert Splitter.select_treatment(partitions, 1) == "a"
      assert Splitter.select_treatment(partitions, 10) == "a"
      assert Splitter.select_treatment(partitions, 11) == "b"
      assert Splitter.select_treatment(partitions, 30) == "b"
      assert Splitter.select_treatment(partitions, 31) == "c"
      assert Splitter.select_treatment(partitions, 100) == "c"
    end

    test "handles single partition" do
      partitions = [%Partition{treatment: "only", size: 100}]

      for bucket <- 1..100 do
        assert Splitter.select_treatment(partitions, bucket) == "only"
      end
    end
  end

  describe "get_treatment/4" do
    test "combines bucket calculation and treatment selection" do
      partitions = [
        %Partition{treatment: "on", size: 50},
        %Partition{treatment: "off", size: 50}
      ]

      treatment = Splitter.get_treatment("user123", 12345, partitions, :murmur)
      assert treatment in ["on", "off"]
    end
  end
end
