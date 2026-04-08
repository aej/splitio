defmodule Splitio.Bench.Fixtures do
  @moduledoc """
  Generates realistic split and segment payloads for load testing.

  These fixtures are served through the mocked HTTP boundary so the SDK
  bootstraps through normal sync code paths instead of seeding ETS directly.
  """

  @default_change_number 1_904_067_200_000

  @doc """
  Build a dataset consumable by `Splitio.Bench.MockServer`.
  """
  def dataset(opts \\ []) do
    num_splits = Keyword.get(opts, :num_splits, 120)
    num_segments = Keyword.get(opts, :num_segments, 12)
    segment_size = Keyword.get(opts, :segment_size, 1_500)
    change_number = Keyword.get(opts, :change_number, @default_change_number)

    segments = create_segments(num_segments, segment_size, change_number)
    segment_names = Enum.map(segments, & &1.name)
    splits = create_splits(num_splits, segment_names, change_number)

    %{
      change_number: change_number,
      splits: splits,
      split_names: Enum.map(splits, & &1["name"]),
      segment_changes: Map.new(segments, &{&1.name, &1.response})
    }
  end

  @doc """
  Deterministic user contexts used by the sustained workload.
  """
  def workload_users(count) do
    now_ms = System.system_time(:millisecond)

    for i <- 1..count do
      %{
        key: user_key(i),
        attrs: %{
          "age" => 16 + rem(i, 55),
          "tags" => tags_for(i),
          "created_at" => now_ms - rem(i * 13_000, 90_000_000),
          "plan" => if(rem(i, 4) == 0, do: "premium_#{rem(i, 20)}", else: "basic_#{rem(i, 20)}")
        }
      }
    end
  end

  @doc "Generate user keys for the workload."
  def user_keys(count) do
    for i <- 1..count, do: user_key(i)
  end

  defp user_key(i), do: "user_#{i}"

  defp tags_for(i) when rem(i, 5) == 0, do: ["a", "b", "c"]
  defp tags_for(i) when rem(i, 3) == 0, do: ["a", "b"]
  defp tags_for(_i), do: ["a"]

  defp create_segments(num_segments, segment_size, change_number) do
    for i <- 1..num_segments do
      name = "segment_#{i}"

      keys =
        for j <- 1..segment_size do
          user_key(((i - 1) * segment_size) + j)
        end

      %{
        name: name,
        response: %{
          "name" => name,
          "added" => keys,
          "removed" => [],
          "since" => -1,
          "till" => change_number
        }
      }
    end
  end

  defp create_splits(num_splits, segment_names, change_number) do
    for i <- 1..num_splits do
      generate_split(i, segment_names, change_number)
    end
  end

  defp generate_split(index, segment_names, change_number) do
    name = "feature_#{index}"

    case rem(index, 10) do
      0 -> simple_rollout_split(name, change_number)
      1 -> percentage_rollout_split(name, 50, change_number)
      2 -> whitelist_split(name, [user_key(1), user_key(2), user_key(3)], change_number)
      3 -> segment_split(name, Enum.at(segment_names, rem(index, length(segment_names))), change_number)
      4 -> string_matcher_split(name, :starts_with, "premium", change_number)
      5 -> number_matcher_split(name, :between, 18, 65, change_number)
      6 -> set_matcher_split(name, :contains_all, ["a", "b"], change_number)
      7 -> date_matcher_split(name, change_number)
      8 -> killed_split(name, change_number)
      9 -> multi_condition_split(name, segment_names, change_number)
    end
  end

  defp simple_rollout_split(name, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp percentage_rollout_split(name, percentage, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp whitelist_split(name, whitelist, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp segment_split(name, segment_name, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp string_matcher_split(name, :starts_with, prefix, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp number_matcher_split(name, :between, min, max, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp set_matcher_split(name, :contains_all, values, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp date_matcher_split(name, change_number) do
    timestamp = 1_577_836_800_000

    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp killed_split(name, change_number) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => true,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => []
    }
  end

  defp multi_condition_split(name, segment_names, change_number) do
    segment_name = Enum.at(segment_names, 0, "segment_1")

    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => change_number,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => seed(),
      "seed" => seed(),
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

  defp seed, do: :rand.uniform(1_000_000)
end
