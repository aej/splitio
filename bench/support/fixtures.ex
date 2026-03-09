defmodule Splitio.Bench.Fixtures do
  @moduledoc """
  Generates realistic split/segment data for load testing.
  """

  alias Splitio.Models.Split
  alias Splitio.Storage

  @doc """
  Populate storage with realistic test data.

  Options:
  - `:num_splits` - Number of feature flags (default: 100)
  - `:num_segments` - Number of segments (default: 10)
  - `:segment_size` - Keys per segment (default: 1000)
  """
  def populate(opts \\ []) do
    num_splits = Keyword.get(opts, :num_splits, 100)
    num_segments = Keyword.get(opts, :num_segments, 10)
    segment_size = Keyword.get(opts, :segment_size, 1000)

    # Create segments first (splits may reference them)
    segments = create_segments(num_segments, segment_size)
    segment_names = Enum.map(segments, & &1.name)

    # Create splits with various matcher types
    create_splits(num_splits, segment_names)

    :ok
  end

  @doc "Generate random user keys for testing"
  def user_keys(count) do
    for i <- 1..count, do: "user_#{i}"
  end

  @doc "Get a random user key"
  def random_user_key(max \\ 10_000) do
    "user_#{:rand.uniform(max)}"
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp create_segments(num_segments, segment_size) do
    for i <- 1..num_segments do
      name = "segment_#{i}"
      keys = for j <- 1..segment_size, do: "user_#{j}"

      Storage.update_segment(name, keys, [], i * 1000)
      %{name: name, keys: keys}
    end
  end

  defp create_splits(num_splits, segment_names) do
    for i <- 1..num_splits do
      split = generate_split(i, segment_names)
      Storage.put_split(split)
    end
  end

  defp generate_split(index, segment_names) do
    # Distribute different matcher types across splits
    type = rem(index, 10)
    name = "feature_#{index}"

    json =
      case type do
        0 -> simple_rollout_split(name)
        1 -> percentage_rollout_split(name, 50)
        2 -> whitelist_split(name, ["user_1", "user_2", "user_3"])
        3 -> segment_split(name, Enum.at(segment_names, rem(index, length(segment_names))))
        4 -> string_matcher_split(name, :starts_with, "premium")
        5 -> number_matcher_split(name, :between, 18, 65)
        6 -> set_matcher_split(name, :contains_all, ["a", "b"])
        7 -> date_matcher_split(name)
        8 -> killed_split(name)
        9 -> multi_condition_split(name, segment_names)
        _ -> simple_rollout_split(name)
      end

    {:ok, split} = Split.from_json(json)
    split
  end

  defp simple_rollout_split(name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{"on" => ~s({"enabled":true})},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp percentage_rollout_split(name, percentage) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [
            %{"treatment" => "on", "size" => percentage},
            %{"treatment" => "off", "size" => 100 - percentage}
          ],
          "label" => "percentage rollout"
        }
      ]
    }
  end

  defp whitelist_split(name, whitelist) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "WHITELIST",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "WHITELIST",
                "negate" => false,
                "whitelistMatcherData" => %{"whitelist" => whitelist}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "whitelisted"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp segment_split(name, segment_name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "IN_SEGMENT",
                "negate" => false,
                "userDefinedSegmentMatcherData" => %{"segmentName" => segment_name}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "in segment"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp string_matcher_split(name, :starts_with, prefix) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "STARTS_WITH",
                "negate" => false,
                "whitelistMatcherData" => %{"whitelist" => [prefix]}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "starts with #{prefix}"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp number_matcher_split(name, :between, min, max) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "BETWEEN",
                "negate" => false,
                "keySelector" => %{"trafficType" => "user", "attribute" => "age"},
                "betweenMatcherData" => %{"dataType" => "NUMBER", "start" => min, "end" => max}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "age between #{min}-#{max}"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp set_matcher_split(name, :contains_all, values) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "CONTAINS_ALL_OF_SET",
                "negate" => false,
                "keySelector" => %{"trafficType" => "user", "attribute" => "tags"},
                "whitelistMatcherData" => %{"whitelist" => values}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "contains all tags"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp date_matcher_split(name) do
    # Match dates >= 2020-01-01 (using supported GREATER_THAN_OR_EQUAL_TO)
    timestamp = 1_577_836_800_000

    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "GREATER_THAN_OR_EQUAL_TO",
                "negate" => false,
                "keySelector" => %{"trafficType" => "user", "attribute" => "created_at"},
                "unaryNumericMatcherData" => %{"dataType" => "DATETIME", "value" => timestamp}
              }
            ]
          },
          "partitions" => [%{"treatment" => "on", "size" => 100}],
          "label" => "created after 2020"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end

  defp killed_split(name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => true,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => []
    }
  end

  defp multi_condition_split(name, segment_names) do
    segment_name = Enum.at(segment_names, 0, "segment_1")

    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_000_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => :rand.uniform(1_000_000),
      "seed" => :rand.uniform(1_000_000),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => [
        # First condition: in segment AND age >= 18
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "IN_SEGMENT",
                "negate" => false,
                "userDefinedSegmentMatcherData" => %{"segmentName" => segment_name}
              },
              %{
                "matcherType" => "GREATER_THAN_OR_EQUAL_TO",
                "negate" => false,
                "keySelector" => %{"trafficType" => "user", "attribute" => "age"},
                "unaryNumericMatcherData" => %{"dataType" => "NUMBER", "value" => 18}
              }
            ]
          },
          "partitions" => [%{"treatment" => "variant_a", "size" => 100}],
          "label" => "segment + age >= 18"
        },
        # Second condition: starts with "vip"
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [
              %{
                "matcherType" => "STARTS_WITH",
                "negate" => false,
                "whitelistMatcherData" => %{"whitelist" => ["vip"]}
              }
            ]
          },
          "partitions" => [%{"treatment" => "variant_b", "size" => 100}],
          "label" => "vip users"
        },
        # Default
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [%{"treatment" => "off", "size" => 100}],
          "label" => "default rule"
        }
      ]
    }
  end
end
