defmodule Splitio.Models.SplitTest do
  use ExUnit.Case, async: true

  alias Splitio.Models.Split

  describe "from_json/1" do
    test "parses minimal split" do
      json = %{
        "name" => "test_split",
        "defaultTreatment" => "off",
        "changeNumber" => 123
      }

      assert {:ok, split} = Split.from_json(json)
      assert split.name == "test_split"
      assert split.default_treatment == "off"
      assert split.change_number == 123
      assert split.killed == false
      assert split.status == :active
    end

    test "parses full split" do
      json = %{
        "name" => "full_split",
        "trafficTypeName" => "user",
        "killed" => true,
        "status" => "ACTIVE",
        "defaultTreatment" => "control",
        "changeNumber" => 456,
        "algo" => 2,
        "trafficAllocation" => 80,
        "trafficAllocationSeed" => 111,
        "seed" => 222,
        "configurations" => %{"on" => "{\"color\":\"blue\"}"},
        "sets" => ["frontend", "mobile"],
        "impressionsDisabled" => true,
        "prerequisites" => [
          %{"n" => "other_flag", "ts" => ["on", "enabled"]}
        ],
        "conditions" => [
          %{
            "conditionType" => "ROLLOUT",
            "matcherGroup" => %{
              "combiner" => "AND",
              "matchers" => [%{"matcherType" => "ALL_KEYS"}]
            },
            "partitions" => [
              %{"treatment" => "on", "size" => 50},
              %{"treatment" => "off", "size" => 50}
            ],
            "label" => "default rule"
          }
        ]
      }

      assert {:ok, split} = Split.from_json(json)
      assert split.name == "full_split"
      assert split.traffic_type_name == "user"
      assert split.killed == true
      assert split.status == :active
      assert split.traffic_allocation == 80
      assert split.algo == :murmur
      assert MapSet.member?(split.sets, "frontend")
      assert MapSet.member?(split.sets, "mobile")
      assert split.impressions_disabled == true
      assert length(split.prerequisites) == 1
      assert length(split.conditions) == 1
    end

    test "parses archived status" do
      json = %{
        "name" => "archived_split",
        "status" => "ARCHIVED",
        "defaultTreatment" => "off",
        "changeNumber" => 123
      }

      assert {:ok, split} = Split.from_json(json)
      assert split.status == :archived
    end

    test "parses legacy algo" do
      json = %{
        "name" => "legacy_split",
        "algo" => 1,
        "defaultTreatment" => "off",
        "changeNumber" => 123
      }

      assert {:ok, split} = Split.from_json(json)
      assert split.algo == :legacy
    end

    test "returns error for invalid input" do
      assert {:error, :invalid_split} = Split.from_json(%{})
      assert {:error, :invalid_split} = Split.from_json(nil)
    end
  end

  describe "get_config/2" do
    test "returns config for treatment" do
      split = %Split{
        name: "test",
        default_treatment: "off",
        change_number: 1,
        configurations: %{
          "on" => "{\"color\":\"blue\"}",
          "off" => nil
        }
      }

      assert Split.get_config(split, "on") == "{\"color\":\"blue\"}"
      assert Split.get_config(split, "off") == nil
      assert Split.get_config(split, "unknown") == nil
    end
  end
end
