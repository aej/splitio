defmodule Splitio.Integration.ManagerTest do
  use Splitio.Integration.Case, async: false

  alias Splitio.Integration.{AdminApi, Helpers}

  @moduletag :integration

  describe "Manager API" do
    test "splits/0 returns all feature flags", %{admin: admin, test_id: test_id} do
      flags =
        for i <- 1..3 do
          name = "manager_flag_#{test_id}_#{i}"
          definition = AdminApi.simple_rollout("on")
          :ok = AdminApi.create_flag_with_definition(admin, name, definition)
          name
        end

      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        splits = Splitio.Manager.splits()

        # Verify our flags are present
        split_names = Enum.map(splits, & &1.name)

        for flag <- flags do
          assert flag in split_names
        end

        # Verify split structure
        our_splits = Enum.filter(splits, &(&1.name in flags))

        for split <- our_splits do
          assert is_binary(split.name)
          assert split.traffic_type_name == "user"
          assert is_list(split.treatments)
        end
      after
        Helpers.stop_sdk()

        for flag <- flags do
          AdminApi.remove_flag_definition(admin, flag)
          AdminApi.delete_flag(admin, flag)
        end
      end
    end

    test "split/1 returns specific flag details", %{admin: admin, test_id: test_id} do
      flag_name = "manager_single_#{test_id}"

      config = ~s({"feature":"enabled"})

      definition =
        AdminApi.simple_rollout("enabled", config: config, default_treatment: "disabled")

      :ok = AdminApi.create_flag_with_definition(admin, flag_name, definition)
      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        split = Splitio.Manager.split(flag_name)

        assert split != nil
        assert split.name == flag_name
        assert split.traffic_type_name == "user"
        assert "enabled" in split.treatments
        assert split.default_treatment == "disabled"
        assert split.configs["enabled"] == config
      after
        Helpers.stop_sdk()
        AdminApi.remove_flag_definition(admin, flag_name)
        AdminApi.delete_flag(admin, flag_name)
      end
    end

    test "split/1 returns nil for non-existent flag", %{admin: _admin, test_id: test_id} do
      flag_name = "nonexistent_manager_#{test_id}"

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        assert Splitio.Manager.split(flag_name) == nil
      after
        Helpers.stop_sdk()
      end
    end

    test "split_names/0 returns all flag names", %{admin: admin, test_id: test_id} do
      flags =
        for i <- 1..3 do
          name = "manager_names_#{test_id}_#{i}"
          definition = AdminApi.simple_rollout("on")
          :ok = AdminApi.create_flag_with_definition(admin, name, definition)
          name
        end

      Process.sleep(3000)

      try do
        {:ok, _} = Helpers.start_sdk(streaming_enabled: false)

        names = Splitio.Manager.split_names()

        for flag <- flags do
          assert flag in names
        end
      after
        Helpers.stop_sdk()

        for flag <- flags do
          AdminApi.remove_flag_definition(admin, flag)
          AdminApi.delete_flag(admin, flag)
        end
      end
    end
  end
end
