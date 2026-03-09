defmodule Splitio.Integration.EvaluationTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration

  describe "feature flag evaluation" do
    test "simple 100% rollout", %{admin: admin, test_id: test_id} do
      flag_name = "simple_rollout_#{test_id}"

      definition = AdminApi.simple_rollout("on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Any user should get "on"
        assert Splitio.get_treatment("user_1", flag_name) == "on"
        assert Splitio.get_treatment("user_2", flag_name) == "on"
        assert Splitio.get_treatment("random_key", flag_name) == "on"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "percentage rollout distributes treatments", %{admin: admin, test_id: test_id} do
      flag_name = "pct_rollout_#{test_id}"

      # 50/50 split
      definition = AdminApi.percentage_rollout(50)
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Evaluate for many users and check distribution
        results =
          for i <- 1..100 do
            Splitio.get_treatment("user_#{i}", flag_name)
          end

        on_count = Enum.count(results, &(&1 == "on"))
        off_count = Enum.count(results, &(&1 == "off"))

        # Should be roughly 50/50 (allow 20% variance)
        assert on_count > 30, "Expected more 'on' treatments, got #{on_count}"
        assert off_count > 30, "Expected more 'off' treatments, got #{off_count}"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "whitelist matcher", %{admin: admin, test_id: test_id} do
      flag_name = "whitelist_#{test_id}"

      definition = AdminApi.whitelist_rule(["allowed_user_1", "allowed_user_2"], "on")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Whitelisted users get "on"
        assert Splitio.get_treatment("allowed_user_1", flag_name) == "on"
        assert Splitio.get_treatment("allowed_user_2", flag_name) == "on"

        # Non-whitelisted users get default
        assert Splitio.get_treatment("other_user", flag_name) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "segment matcher", %{admin: admin, test_id: test_id} do
      segment_name = "eval_segment_#{test_id}"
      flag_name = "eval_segment_flag_#{test_id}"

      :ok = AdminApi.create_segment_with_keys(admin, segment_name, ["segment_member"])
      definition = AdminApi.segment_rule(segment_name, "premium")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        assert Splitio.get_treatment("segment_member", flag_name) == "premium"
        assert Splitio.get_treatment("non_member", flag_name) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
        AdminApi.deactivate_segment(admin, segment_name)
        AdminApi.delete_segment(admin, segment_name)
      end
    end

    test "string attribute matcher (starts_with)", %{admin: admin, test_id: test_id} do
      flag_name = "string_attr_#{test_id}"

      definition = AdminApi.attribute_rule("plan", :starts_with, "premium", "vip")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Match
        assert Splitio.get_treatment("user", flag_name, %{"plan" => "premium_gold"}) == "vip"
        assert Splitio.get_treatment("user", flag_name, %{"plan" => "premium"}) == "vip"

        # No match
        assert Splitio.get_treatment("user", flag_name, %{"plan" => "basic"}) == "off"
        assert Splitio.get_treatment("user", flag_name, %{}) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "number attribute matcher (gte)", %{admin: admin, test_id: test_id} do
      flag_name = "number_attr_#{test_id}"

      definition = AdminApi.attribute_rule("age", :gte, 18, "adult")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Match
        assert Splitio.get_treatment("user", flag_name, %{"age" => 18}) == "adult"
        assert Splitio.get_treatment("user", flag_name, %{"age" => 25}) == "adult"
        assert Splitio.get_treatment("user", flag_name, %{"age" => 65}) == "adult"

        # No match
        assert Splitio.get_treatment("user", flag_name, %{"age" => 17}) == "off"
        assert Splitio.get_treatment("user", flag_name, %{}) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "killed flag returns default treatment", %{admin: admin, test_id: test_id} do
      flag_name = "killed_flag_#{test_id}"

      definition = AdminApi.simple_rollout("on", default_treatment: "off")
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(2000)

      # Kill the flag
      :ok = AdminApi.kill_flag(admin, flag_name)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Killed flag should return default treatment
        assert Splitio.get_treatment("user", flag_name) == "off"
      after
        Helpers.stop_sdk()
        AdminApi.restore_flag(admin, flag_name)
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "non-existent flag returns control", %{admin: _admin, test_id: test_id} do
      flag_name = "nonexistent_#{test_id}_#{:rand.uniform(100_000)}"

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        # Non-existent flag returns "control"
        assert Splitio.get_treatment("user", flag_name) == "control"
      after
        Helpers.stop_sdk()
      end
    end

    test "treatment with config", %{admin: admin, test_id: test_id} do
      flag_name = "with_config_#{test_id}"

      config_json = ~s({"color":"blue","size":42})
      definition = AdminApi.simple_rollout("on", config: config_json)
      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        {treatment, config} = Splitio.get_treatment_with_config("user", flag_name)
        assert treatment == "on"
        assert config == config_json
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "batch treatments", %{admin: admin, test_id: test_id} do
      flags =
        for i <- 1..3 do
          name = "batch_flag_#{test_id}_#{i}"
          treatment = "treatment_#{i}"
          definition = AdminApi.simple_rollout(treatment)
          :ok = AdminApi.create_flag_with_definition(admin, name, definition)
          {name, treatment}
        end

      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        flag_names = Enum.map(flags, &elem(&1, 0))
        results = Splitio.get_treatments("user", flag_names)

        for {name, expected_treatment} <- flags do
          assert results[name] == expected_treatment
        end
      after
        Helpers.stop_sdk()

        for {name, _} <- flags do
          AdminApi.remove_flag_definition(admin, name)
          AdminApi.delete_flag(admin, name)
        end
      end
    end
  end
end
