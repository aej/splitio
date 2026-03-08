defmodule Splitio.Test.Fixtures do
  @moduledoc """
  JSON fixtures matching SPEC.md API responses.
  """

  @doc "Split changes response with one split"
  def split_changes_response(opts \\ []) do
    since = Keyword.get(opts, :since, -1)
    till = Keyword.get(opts, :till, 1_704_067_200_000)
    splits = Keyword.get(opts, :splits, [default_split()])

    %{
      "splits" => splits,
      "since" => since,
      "till" => till
    }
  end

  @doc "Empty split changes (up to date)"
  def split_changes_empty(change_number) do
    %{
      "splits" => [],
      "since" => change_number,
      "till" => change_number
    }
  end

  @doc "Default split definition"
  def default_split(opts \\ []) do
    name = Keyword.get(opts, :name, "test_feature")
    treatment = Keyword.get(opts, :treatment, "on")

    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => Keyword.get(opts, :change_number, 1_704_067_200_000),
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => 123_456,
      "seed" => 789_012,
      "configurations" => %{
        treatment => ~s({"color":"blue"})
      },
      "sets" => Keyword.get(opts, :sets, []),
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
            %{"treatment" => treatment, "size" => 100}
          ],
          "label" => "default rule"
        }
      ]
    }
  end

  @doc "Split with segment condition"
  def split_with_segment(name, segment_name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_704_067_200_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => 123_456,
      "seed" => 789_012,
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
                "userDefinedSegmentMatcherData" => %{
                  "segmentName" => segment_name
                }
              }
            ]
          },
          "partitions" => [
            %{"treatment" => "on", "size" => 100}
          ],
          "label" => "in segment #{segment_name}"
        },
        %{
          "conditionType" => "ROLLOUT",
          "matcherGroup" => %{
            "combiner" => "AND",
            "matchers" => [%{"matcherType" => "ALL_KEYS", "negate" => false}]
          },
          "partitions" => [
            %{"treatment" => "off", "size" => 100}
          ],
          "label" => "default rule"
        }
      ]
    }
  end

  @doc "Killed split"
  def killed_split(name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => true,
      "status" => "ACTIVE",
      "defaultTreatment" => "off",
      "changeNumber" => 1_704_067_200_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => 123_456,
      "seed" => 789_012,
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => []
    }
  end

  @doc "Archived split"
  def archived_split(name) do
    %{
      "name" => name,
      "trafficTypeName" => "user",
      "killed" => false,
      "status" => "ARCHIVED",
      "defaultTreatment" => "off",
      "changeNumber" => 1_704_067_200_000,
      "algo" => 2,
      "trafficAllocation" => 100,
      "trafficAllocationSeed" => 123_456,
      "seed" => 789_012,
      "configurations" => %{},
      "sets" => [],
      "impressionsDisabled" => false,
      "prerequisites" => [],
      "conditions" => []
    }
  end

  @doc "Segment changes response"
  def segment_changes_response(opts \\ []) do
    name = Keyword.get(opts, :name, "beta_users")
    added = Keyword.get(opts, :added, ["user1", "user2", "user3"])
    removed = Keyword.get(opts, :removed, [])
    since = Keyword.get(opts, :since, -1)
    till = Keyword.get(opts, :till, 1_704_067_200_000)

    %{
      "name" => name,
      "added" => added,
      "removed" => removed,
      "since" => since,
      "till" => till
    }
  end

  @doc "Empty segment changes (up to date)"
  def segment_changes_empty(name, change_number) do
    %{
      "name" => name,
      "added" => [],
      "removed" => [],
      "since" => change_number,
      "till" => change_number
    }
  end

  @doc "Auth response with JWT token"
  def auth_response(opts \\ []) do
    push_enabled = Keyword.get(opts, :push_enabled, true)
    # Token expires in 1 hour
    exp = System.system_time(:second) + 3600

    # Minimal JWT payload (not cryptographically valid, but structurally correct)
    payload =
      %{
        "x-ably-capability" => ~s({"channel":["subscribe"]}),
        "exp" => exp,
        "iat" => System.system_time(:second)
      }
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    token = "header.#{payload}.signature"

    %{
      "pushEnabled" => push_enabled,
      "token" => token
    }
  end

  @doc "Auth response with push disabled"
  def auth_response_disabled do
    %{
      "pushEnabled" => false,
      "token" => nil
    }
  end

  @doc "Impressions bulk payload (what SDK sends)"
  def impressions_bulk_payload(impressions) do
    impressions
    |> Enum.group_by(& &1.feature)
    |> Enum.map(fn {feature, imps} ->
      %{
        "f" => feature,
        "i" =>
          Enum.map(imps, fn imp ->
            base = %{
              "k" => imp.key,
              "t" => imp.treatment,
              "m" => imp.time,
              "c" => imp.change_number,
              "r" => imp.label
            }

            base
            |> maybe_add("b", imp[:bucketing_key])
            |> maybe_add("pt", imp[:previous_time])
          end)
      }
    end)
  end

  @doc "Events bulk payload (what SDK sends)"
  def events_bulk_payload(events) do
    Enum.map(events, fn event ->
      base = %{
        "key" => event.key,
        "trafficTypeName" => event.traffic_type,
        "eventTypeId" => event.event_type,
        "timestamp" => event.timestamp
      }

      base
      |> maybe_add("value", event[:value])
      |> maybe_add("properties", event[:properties])
    end)
  end

  @doc "Impression counts payload"
  def impression_counts_payload(counts) do
    pf =
      Enum.map(counts, fn {{feature, hour}, count} ->
        %{"f" => feature, "m" => hour, "rc" => count}
      end)

    %{"pf" => pf}
  end

  @doc "Large segment RFD response"
  def large_segment_response(opts \\ []) do
    name = Keyword.get(opts, :name, "large_segment")
    notification_type = Keyword.get(opts, :type, "LS_NEW_DEFINITION")
    change_number = Keyword.get(opts, :change_number, 1_704_067_200_000)

    base = %{
      "n" => name,
      "t" => notification_type,
      "v" => "1.0",
      "cn" => change_number
    }

    if notification_type == "LS_NEW_DEFINITION" do
      Map.put(base, "rfd", %{
        "d" => %{
          "f" => 1,
          "k" => Keyword.get(opts, :total_keys, 1000),
          "s" => Keyword.get(opts, :file_size, 10_000),
          "e" => System.system_time(:millisecond) + 3_600_000
        },
        "p" => %{
          "m" => "GET",
          "u" => Keyword.get(opts, :url, "https://cdn.split.io/large-segments/test.csv"),
          "h" => %{},
          "b" => nil
        }
      })
    else
      Map.put(base, "rfd", nil)
    end
  end

  @doc "Large segment CSV content"
  def large_segment_csv(keys) do
    Enum.join(keys, "\n")
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
