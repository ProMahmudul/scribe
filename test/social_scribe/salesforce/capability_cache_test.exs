defmodule SocialScribe.Salesforce.CapabilityCacheTest do
  # Not async: tests that delete the named ETS table must not race with each other.
  use SocialScribe.DataCase, async: false

  alias SocialScribe.Salesforce.CapabilityCache

  @table :salesforce_capability_cache

  # Restore the table after each test so the GenServer (and other tests)
  # continue to work correctly.
  setup do
    on_exit(fn ->
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:set, :public, :named_table])
      end
    end)

    :ok
  end

  describe "get/1" do
    test "returns :miss for an unknown key" do
      key = {:test, System.unique_integer()}
      assert :miss == CapabilityCache.get(key)
    end

    test "does not crash when the ETS table does not exist" do
      # Simulate the table being absent (e.g. GenServer restarted).
      if :ets.whereis(@table) != :undefined do
        :ets.delete(@table)
      end

      # ensure_table!/0 recreates the table; get/1 should return :miss, not crash.
      assert :miss == CapabilityCache.get({:test, System.unique_integer()})

      # Table must have been recreated by ensure_table!/0.
      assert :ets.whereis(@table) != :undefined
    end
  end

  describe "put/1 + get/1" do
    test "round-trips a boolean value" do
      key = {:sf_cap, "https://org.my.salesforce.com"}
      assert :ok == CapabilityCache.put(key, true)
      assert {:ok, true} == CapabilityCache.get(key)
    end

    test "round-trips a false value" do
      key = {:sf_cap, "https://sandbox.my.salesforce.com"}
      assert :ok == CapabilityCache.put(key, false)
      assert {:ok, false} == CapabilityCache.get(key)
    end

    test "overwrites a previous entry" do
      key = {:sf_cap, System.unique_integer()}
      CapabilityCache.put(key, false)
      CapabilityCache.put(key, true)
      assert {:ok, true} == CapabilityCache.get(key)
    end

    test "does not crash when the ETS table does not exist before put" do
      if :ets.whereis(@table) != :undefined do
        :ets.delete(@table)
      end

      key = {:sf_cap, System.unique_integer()}
      assert :ok == CapabilityCache.put(key, true)
      assert {:ok, true} == CapabilityCache.get(key)
    end
  end
end
