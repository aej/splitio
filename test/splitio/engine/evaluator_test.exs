defmodule Splitio.Engine.EvaluatorTest do
  use ExUnit.Case

  alias Splitio.Engine.Evaluator
  alias Splitio.Models.{Split, Condition, MatcherGroup, Matcher, Partition}
  alias Splitio.Storage

  setup do
    # Clear any existing test splits
    :ok
  end

  describe "evaluate/3" do
    test "returns control for missing split" do
      result = Evaluator.evaluate("user123", "nonexistent_split_#{:rand.uniform(1_000_000)}")
      assert result.treatment == "control"
      assert result.label == "definition not found"
    end

    test "returns default treatment for killed split" do
      split = %Split{
        name: "killed_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123,
        killed: true,
        conditions: []
      }

      Storage.put_split(split)
      result = Evaluator.evaluate("user123", split.name)
      assert result.treatment == "off"
      assert result.label == "killed"
    end

    test "evaluates ALL_KEYS condition" do
      split = %Split{
        name: "all_keys_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "control",
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
              %Partition{treatment: "on", size: 100}
            ],
            label: "all keys"
          }
        ]
      }

      Storage.put_split(split)
      result = Evaluator.evaluate("user123", split.name)
      assert result.treatment == "on"
      assert result.label == "all keys"
    end

    test "evaluates whitelist condition" do
      split = %Split{
        name: "whitelist_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123,
        seed: 12345,
        algo: :murmur,
        traffic_allocation: 100,
        conditions: [
          %Condition{
            condition_type: :whitelist,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :whitelist, whitelist: ["vip_user", "admin"]}]
            },
            partitions: [%Partition{treatment: "premium", size: 100}],
            label: "whitelisted"
          },
          %Condition{
            condition_type: :rollout,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :all_keys}]
            },
            partitions: [%Partition{treatment: "standard", size: 100}],
            label: "default"
          }
        ]
      }

      Storage.put_split(split)

      # Whitelisted user
      result = Evaluator.evaluate("vip_user", split.name)
      assert result.treatment == "premium"
      assert result.label == "whitelisted"

      # Non-whitelisted user
      result = Evaluator.evaluate("regular_user", split.name)
      assert result.treatment == "standard"
      assert result.label == "default"
    end

    test "respects traffic allocation" do
      split = %Split{
        name: "traffic_alloc_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123,
        seed: 12345,
        algo: :murmur,
        traffic_allocation: 0,
        traffic_allocation_seed: 67890,
        conditions: [
          %Condition{
            condition_type: :rollout,
            matcher_group: %MatcherGroup{
              combiner: :and,
              matchers: [%Matcher{matcher_type: :all_keys}]
            },
            partitions: [%Partition{treatment: "on", size: 100}],
            label: "rollout"
          }
        ]
      }

      Storage.put_split(split)
      result = Evaluator.evaluate("user123", split.name)

      # With 0% traffic allocation, user should get default treatment
      assert result.treatment == "off"
      assert result.label == "not in split"
    end

    test "includes config in result" do
      split = %Split{
        name: "config_split_#{:rand.uniform(1_000_000)}",
        default_treatment: "off",
        change_number: 123,
        seed: 12345,
        algo: :murmur,
        traffic_allocation: 100,
        configurations: %{"on" => "{\"color\":\"blue\"}"},
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

      Storage.put_split(split)
      result = Evaluator.evaluate("user123", split.name)
      assert result.config == "{\"color\":\"blue\"}"
    end
  end
end
