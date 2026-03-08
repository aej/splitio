defmodule Splitio.Engine.MatchersTest do
  use ExUnit.Case

  alias Splitio.Engine.Matchers
  alias Splitio.Models.{Matcher, KeySelector, Segment}
  alias Splitio.Storage

  # Mock evaluator for dependency and rule-based segment tests
  defmodule MockEvaluator do
    def evaluate_dependency("feature_on", _ctx), do: %{treatment: "on"}
    def evaluate_dependency("feature_off", _ctx), do: %{treatment: "off"}
    def evaluate_dependency(_, _ctx), do: %{treatment: "control"}

    def evaluate_rule_based_segment("active_users", ctx) do
      ctx.key in ["user1", "user2"]
    end

    def evaluate_rule_based_segment(_, _), do: false
  end

  defp base_context(key, attrs \\ %{}) do
    %{
      key: key,
      bucketing_key: key,
      attributes: attrs,
      evaluator: MockEvaluator
    }
  end

  describe "ALL_KEYS matcher" do
    test "always matches" do
      matcher = %Matcher{matcher_type: :all_keys}
      assert Matchers.evaluate(matcher, base_context("any_user"))
      assert Matchers.evaluate(matcher, base_context(""))
    end
  end

  describe "WHITELIST matcher" do
    test "matches keys in list" do
      matcher = %Matcher{
        matcher_type: :whitelist,
        whitelist: ["user1", "user2", "admin"]
      }

      assert Matchers.evaluate(matcher, base_context("user1"))
      assert Matchers.evaluate(matcher, base_context("admin"))
      refute Matchers.evaluate(matcher, base_context("user3"))
    end

    test "handles empty whitelist" do
      matcher = %Matcher{matcher_type: :whitelist, whitelist: []}
      refute Matchers.evaluate(matcher, base_context("anyone"))
    end
  end

  describe "IN_SEGMENT matcher" do
    setup do
      segment = %Segment{
        name: "beta_users",
        keys: MapSet.new(["beta1", "beta2", "beta3"]),
        change_number: 1
      }

      Storage.put_segment(segment)

      on_exit(fn ->
        # Segment cleanup not implemented, but ok for tests
        :ok
      end)

      :ok
    end

    test "matches keys in segment" do
      matcher = %Matcher{matcher_type: :in_segment, segment_name: "beta_users"}

      assert Matchers.evaluate(matcher, base_context("beta1"))
      assert Matchers.evaluate(matcher, base_context("beta2"))
      refute Matchers.evaluate(matcher, base_context("not_beta"))
    end

    test "returns false for non-existent segment" do
      matcher = %Matcher{matcher_type: :in_segment, segment_name: "nonexistent"}
      refute Matchers.evaluate(matcher, base_context("anyone"))
    end
  end

  describe "EQUAL_TO_BOOLEAN matcher" do
    test "matches boolean attribute" do
      matcher = %Matcher{
        matcher_type: :equal_to_boolean,
        value: true,
        key_selector: %KeySelector{attribute: "premium"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"premium" => true}))
      refute Matchers.evaluate(matcher, base_context("user", %{"premium" => false}))
    end

    test "coerces string to boolean" do
      matcher = %Matcher{
        matcher_type: :equal_to_boolean,
        value: true,
        key_selector: %KeySelector{attribute: "enabled"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"enabled" => "true"}))
      assert Matchers.evaluate(matcher, base_context("user", %{"enabled" => "TRUE"}))
      refute Matchers.evaluate(matcher, base_context("user", %{"enabled" => "false"}))
    end

    test "returns false for missing attribute" do
      matcher = %Matcher{
        matcher_type: :equal_to_boolean,
        value: true,
        key_selector: %KeySelector{attribute: "missing"}
      }

      refute Matchers.evaluate(matcher, base_context("user", %{}))
    end
  end

  describe "numeric matchers" do
    test "EQUAL_TO matches numbers" do
      matcher = %Matcher{
        matcher_type: :equal_to,
        value: 100,
        data_type: :number,
        key_selector: %KeySelector{attribute: "age"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 100}))
      refute Matchers.evaluate(matcher, base_context("user", %{"age" => 99}))
    end

    test "GREATER_THAN_OR_EQUAL_TO" do
      matcher = %Matcher{
        matcher_type: :greater_than_or_equal_to,
        value: 18,
        data_type: :number,
        key_selector: %KeySelector{attribute: "age"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 18}))
      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 25}))
      refute Matchers.evaluate(matcher, base_context("user", %{"age" => 17}))
    end

    test "LESS_THAN_OR_EQUAL_TO" do
      matcher = %Matcher{
        matcher_type: :less_than_or_equal_to,
        value: 65,
        data_type: :number,
        key_selector: %KeySelector{attribute: "age"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 65}))
      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 30}))
      refute Matchers.evaluate(matcher, base_context("user", %{"age" => 66}))
    end

    test "BETWEEN" do
      matcher = %Matcher{
        matcher_type: :between,
        start_value: 18,
        end_value: 65,
        data_type: :number,
        key_selector: %KeySelector{attribute: "age"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 18}))
      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 40}))
      assert Matchers.evaluate(matcher, base_context("user", %{"age" => 65}))
      refute Matchers.evaluate(matcher, base_context("user", %{"age" => 17}))
      refute Matchers.evaluate(matcher, base_context("user", %{"age" => 66}))
    end

    test "handles float values" do
      matcher = %Matcher{
        matcher_type: :equal_to,
        value: 100,
        data_type: :number,
        key_selector: %KeySelector{attribute: "score"}
      }

      # Float gets truncated to integer
      assert Matchers.evaluate(matcher, base_context("user", %{"score" => 100.9}))
    end

    test "datetime EQUAL_TO truncates to day" do
      # Jan 1, 2024 12:30:45 UTC
      timestamp = 1_704_111_045_000
      # Jan 1, 2024 00:00:00 UTC (start of day)
      day_start = 1_704_067_200_000

      matcher = %Matcher{
        matcher_type: :equal_to,
        value: day_start,
        data_type: :datetime,
        key_selector: %KeySelector{attribute: "created_at"}
      }

      assert Matchers.evaluate(matcher, base_context("user", %{"created_at" => timestamp}))
    end
  end

  describe "string matchers" do
    test "STARTS_WITH" do
      matcher = %Matcher{
        matcher_type: :starts_with,
        whitelist: ["http://", "https://"],
        key_selector: %KeySelector{attribute: "url"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"url" => "https://example.com"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"url" => "http://test.com"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"url" => "ftp://server.com"}))
    end

    test "ENDS_WITH" do
      matcher = %Matcher{
        matcher_type: :ends_with,
        whitelist: [".com", ".org"],
        key_selector: %KeySelector{attribute: "email"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"email" => "user@example.com"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"email" => "user@example.org"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"email" => "user@example.net"}))
    end

    test "CONTAINS_STRING" do
      matcher = %Matcher{
        matcher_type: :contains_string,
        whitelist: ["admin", "root"],
        key_selector: %KeySelector{attribute: "role"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"role" => "super_admin"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"role" => "root_user"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"role" => "user"}))
    end

    test "MATCHES_STRING regex" do
      matcher = %Matcher{
        matcher_type: :matches_string,
        value: "^[a-z]+@[a-z]+\\.[a-z]{2,}$",
        key_selector: %KeySelector{attribute: "email"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"email" => "test@example.com"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"email" => "INVALID@EMAIL"}))
    end

    test "MATCHES_STRING handles invalid regex" do
      matcher = %Matcher{
        matcher_type: :matches_string,
        value: "[invalid(regex",
        key_selector: %KeySelector{attribute: "data"}
      }

      refute Matchers.evaluate(matcher, base_context("u", %{"data" => "anything"}))
    end
  end

  describe "set matchers" do
    test "EQUAL_TO_SET" do
      matcher = %Matcher{
        matcher_type: :equal_to_set,
        whitelist: ["a", "b", "c"],
        key_selector: %KeySelector{attribute: "tags"}
      }

      # Order doesn't matter for set equality
      assert Matchers.evaluate(matcher, base_context("u", %{"tags" => ["c", "b", "a"]}))
      assert Matchers.evaluate(matcher, base_context("u", %{"tags" => ["a", "b", "c"]}))
      refute Matchers.evaluate(matcher, base_context("u", %{"tags" => ["a", "b"]}))
      refute Matchers.evaluate(matcher, base_context("u", %{"tags" => ["a", "b", "c", "d"]}))
    end

    test "CONTAINS_ANY_OF_SET" do
      matcher = %Matcher{
        matcher_type: :contains_any_of_set,
        whitelist: ["premium", "vip"],
        key_selector: %KeySelector{attribute: "plans"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"plans" => ["basic", "premium"]}))
      assert Matchers.evaluate(matcher, base_context("u", %{"plans" => ["vip"]}))
      refute Matchers.evaluate(matcher, base_context("u", %{"plans" => ["basic", "standard"]}))
    end

    test "CONTAINS_ALL_OF_SET" do
      matcher = %Matcher{
        matcher_type: :contains_all_of_set,
        whitelist: ["read", "write"],
        key_selector: %KeySelector{attribute: "permissions"}
      }

      assert Matchers.evaluate(
               matcher,
               base_context("u", %{"permissions" => ["read", "write", "delete"]})
             )

      assert Matchers.evaluate(matcher, base_context("u", %{"permissions" => ["read", "write"]}))
      refute Matchers.evaluate(matcher, base_context("u", %{"permissions" => ["read"]}))
    end

    test "PART_OF_SET" do
      matcher = %Matcher{
        matcher_type: :part_of_set,
        whitelist: ["us", "uk", "ca", "au"],
        key_selector: %KeySelector{attribute: "countries"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"countries" => ["us", "uk"]}))
      assert Matchers.evaluate(matcher, base_context("u", %{"countries" => ["us"]}))
      refute Matchers.evaluate(matcher, base_context("u", %{"countries" => ["us", "fr"]}))
    end
  end

  describe "semver matchers" do
    test "EQUAL_TO_SEMVER" do
      matcher = %Matcher{
        matcher_type: :equal_to_semver,
        value: "2.0.0",
        key_selector: %KeySelector{attribute: "version"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.1"}))
    end

    test "GREATER_THAN_OR_EQUAL_TO_SEMVER" do
      matcher = %Matcher{
        matcher_type: :greater_than_or_equal_to_semver,
        value: "2.0.0",
        key_selector: %KeySelector{attribute: "version"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.0"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "3.0.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "1.9.9"}))
    end

    test "LESS_THAN_OR_EQUAL_TO_SEMVER" do
      matcher = %Matcher{
        matcher_type: :less_than_or_equal_to_semver,
        value: "2.0.0",
        key_selector: %KeySelector{attribute: "version"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.0"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "1.5.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.1"}))
    end

    test "BETWEEN_SEMVER" do
      matcher = %Matcher{
        matcher_type: :between_semver,
        start_value: "1.0.0",
        end_value: "2.0.0",
        key_selector: %KeySelector{attribute: "version"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "1.0.0"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "1.5.0"}))
      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "0.9.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.1"}))
    end

    test "IN_LIST_SEMVER" do
      matcher = %Matcher{
        matcher_type: :in_list_semver,
        whitelist: ["1.0.0", "2.0.0", "3.0.0"],
        key_selector: %KeySelector{attribute: "version"}
      }

      assert Matchers.evaluate(matcher, base_context("u", %{"version" => "2.0.0"}))
      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "2.5.0"}))
    end

    test "handles invalid semver" do
      matcher = %Matcher{
        matcher_type: :equal_to_semver,
        value: "2.0.0",
        key_selector: %KeySelector{attribute: "version"}
      }

      refute Matchers.evaluate(matcher, base_context("u", %{"version" => "invalid"}))
    end
  end

  describe "IN_SPLIT_TREATMENT (dependency) matcher" do
    test "matches when dependency returns expected treatment" do
      matcher = %Matcher{
        matcher_type: :in_split_treatment,
        dependency_split: "feature_on",
        dependency_treatments: ["on", "enabled"]
      }

      assert Matchers.evaluate(matcher, base_context("user"))
    end

    test "does not match when dependency returns unexpected treatment" do
      matcher = %Matcher{
        matcher_type: :in_split_treatment,
        dependency_split: "feature_off",
        dependency_treatments: ["on", "enabled"]
      }

      refute Matchers.evaluate(matcher, base_context("user"))
    end
  end

  describe "IN_RULE_BASED_SEGMENT matcher" do
    test "matches when rule-based segment evaluates to true" do
      matcher = %Matcher{
        matcher_type: :in_rule_based_segment,
        segment_name: "active_users"
      }

      assert Matchers.evaluate(matcher, base_context("user1"))
      assert Matchers.evaluate(matcher, base_context("user2"))
      refute Matchers.evaluate(matcher, base_context("user3"))
    end
  end

  describe "matcher negation" do
    test "negates ALL_KEYS" do
      matcher = %Matcher{matcher_type: :all_keys, negate: true}
      refute Matchers.evaluate(matcher, base_context("anyone"))
    end

    test "negates WHITELIST" do
      matcher = %Matcher{
        matcher_type: :whitelist,
        whitelist: ["blocked"],
        negate: true
      }

      assert Matchers.evaluate(matcher, base_context("allowed"))
      refute Matchers.evaluate(matcher, base_context("blocked"))
    end

    test "negates numeric matcher" do
      matcher = %Matcher{
        matcher_type: :greater_than_or_equal_to,
        value: 18,
        data_type: :number,
        key_selector: %KeySelector{attribute: "age"},
        negate: true
      }

      # Negated: NOT >= 18, i.e., < 18
      assert Matchers.evaluate(matcher, base_context("u", %{"age" => 17}))
      refute Matchers.evaluate(matcher, base_context("u", %{"age" => 18}))
    end
  end

  describe "attribute-based matching" do
    test "numeric matcher uses attribute" do
      matcher = %Matcher{
        matcher_type: :equal_to,
        value: 100,
        data_type: :number,
        key_selector: %KeySelector{attribute: "score"}
      }

      assert Matchers.evaluate(matcher, base_context("user123", %{"score" => 100}))
      refute Matchers.evaluate(matcher, base_context("user123", %{"score" => 50}))
    end

    test "returns false for missing attribute" do
      matcher = %Matcher{
        matcher_type: :equal_to,
        value: 100,
        data_type: :number,
        key_selector: %KeySelector{attribute: "score"}
      }

      refute Matchers.evaluate(matcher, base_context("user", %{}))
      refute Matchers.evaluate(matcher, base_context("user", %{"other" => 100}))
    end

    test "uses key when no attribute specified" do
      # nil key_selector means use the key itself
      matcher = %Matcher{
        matcher_type: :whitelist,
        whitelist: ["special_user"],
        key_selector: %KeySelector{attribute: nil}
      }

      assert Matchers.evaluate(matcher, base_context("special_user"))
      refute Matchers.evaluate(matcher, base_context("regular_user"))
    end
  end

  describe "unknown matcher type" do
    test "returns false and logs warning" do
      matcher = %Matcher{matcher_type: :unknown_type}
      refute Matchers.evaluate(matcher, base_context("user"))
    end
  end
end
