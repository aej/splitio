defmodule SplitioTest do
  use ExUnit.Case

  alias Splitio.Models.{Split, Condition, MatcherGroup, Matcher, Partition}
  alias Splitio.Storage

  describe "basic functionality" do
    test "ready? returns false when not started" do
      # When no sync manager is running
      refute Splitio.ready?()
    end
  end

  describe "get_treatment/3" do
    setup do
      # Add a test split directly to storage
      split = %Split{
        name: "test_feature",
        default_treatment: "off",
        change_number: 123,
        seed: 12345,
        algo: :murmur,
        traffic_allocation: 100,
        conditions: [
          %Condition{
            condition_type: :rollout,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :all_keys}]
            },
            partitions: [
              %Partition{treatment: "on", size: 50},
              %Partition{treatment: "off", size: 50}
            ],
            label: "default rule"
          }
        ]
      }

      Storage.put_split(split)

      on_exit(fn ->
        Storage.delete_split("test_feature")
      end)

      :ok
    end

    test "returns treatment for existing split" do
      treatment = Splitio.get_treatment("user123", "test_feature")
      assert treatment in ["on", "off"]
    end

    test "returns control for missing split" do
      treatment = Splitio.get_treatment("user123", "nonexistent_feature")
      assert treatment == "control"
    end

    test "is deterministic for same key" do
      t1 = Splitio.get_treatment("user123", "test_feature")
      t2 = Splitio.get_treatment("user123", "test_feature")
      assert t1 == t2
    end
  end

  describe "get_treatments/3" do
    setup do
      split1 = %Split{
        name: "feature_a",
        default_treatment: "off",
        change_number: 1,
        seed: 111,
        algo: :murmur,
        traffic_allocation: 100,
        conditions: [
          %Condition{
            condition_type: :rollout,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :all_keys}]
            },
            partitions: [%Partition{treatment: "on", size: 100}],
            label: "default"
          }
        ]
      }

      split2 = %Split{
        name: "feature_b",
        default_treatment: "control",
        change_number: 1,
        seed: 222,
        algo: :murmur,
        traffic_allocation: 100,
        conditions: [
          %Condition{
            condition_type: :rollout,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :all_keys}]
            },
            partitions: [%Partition{treatment: "enabled", size: 100}],
            label: "default"
          }
        ]
      }

      Storage.put_split(split1)
      Storage.put_split(split2)

      on_exit(fn ->
        Storage.delete_split("feature_a")
        Storage.delete_split("feature_b")
      end)

      :ok
    end

    test "returns treatments for multiple splits" do
      treatments = Splitio.get_treatments("user123", ["feature_a", "feature_b"])
      assert is_map(treatments)
      assert treatments["feature_a"] == "on"
      assert treatments["feature_b"] == "enabled"
    end
  end
end
