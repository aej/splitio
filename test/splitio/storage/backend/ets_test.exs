defmodule Splitio.Storage.Backend.ETSTest do
  use ExUnit.Case

  alias Splitio.Storage.Backend.ETS
  alias Splitio.Models.{Split, Segment}

  setup do
    # Ensure tables exist (application should be started)
    :ok
  end

  describe "splits" do
    test "put and get split" do
      split = %Split{
        name: "test_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123
      }

      assert :ok = ETS.put_split(split)
      assert {:ok, retrieved} = ETS.get_split(split.name)
      assert retrieved.name == split.name
    end

    test "get_split returns :not_found for missing" do
      assert :not_found = ETS.get_split("nonexistent_split_#{:rand.uniform(1_000_000)}")
    end

    test "delete_split" do
      split = %Split{
        name: "delete_test_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123
      }

      ETS.put_split(split)
      assert {:ok, _} = ETS.get_split(split.name)
      ETS.delete_split(split.name)
      assert :not_found = ETS.get_split(split.name)
    end

    test "change number operations" do
      ETS.set_splits_change_number(999)
      assert ETS.get_splits_change_number() == 999
    end
  end

  describe "segments" do
    test "segment_contains?" do
      segment = %Segment{
        name: "test_segment_#{:rand.uniform(1_000_000)}",
        keys: MapSet.new(["user1", "user2"]),
        change_number: 100
      }

      ETS.put_segment(segment)
      assert ETS.segment_contains?(segment.name, "user1")
      assert ETS.segment_contains?(segment.name, "user2")
      refute ETS.segment_contains?(segment.name, "user3")
    end

    test "update_segment adds and removes keys" do
      name = "update_segment_#{:rand.uniform(1_000_000)}"
      segment = %Segment{name: name, keys: MapSet.new(["a", "b"]), change_number: 1}
      ETS.put_segment(segment)

      ETS.update_segment(name, ["c", "d"], ["a"], 2)

      assert ETS.segment_contains?(name, "b")
      assert ETS.segment_contains?(name, "c")
      assert ETS.segment_contains?(name, "d")
      refute ETS.segment_contains?(name, "a")
      assert ETS.get_segment_change_number(name) == 2
    end
  end

  describe "flag sets" do
    test "get_splits_by_flag_set" do
      split1 = %Split{
        name: "flagset_test1_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 1,
        sets: MapSet.new(["frontend"])
      }

      split2 = %Split{
        name: "flagset_test2_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 1,
        sets: MapSet.new(["backend"])
      }

      ETS.put_split(split1)
      ETS.put_split(split2)

      frontend_splits = ETS.get_splits_by_flag_set("frontend")
      assert Enum.any?(frontend_splits, &(&1.name == split1.name))
      refute Enum.any?(frontend_splits, &(&1.name == split2.name))
    end
  end
end
