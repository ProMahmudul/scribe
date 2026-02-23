defmodule SocialScribe.Salesforce.CapabilityCache do
  @moduledoc """
  ETS-backed cache for per-org Salesforce capability flags.

  Capabilities are cached per `instance_url` with a 1-hour TTL to avoid
  repeated describe/SOQL calls on every contact update operation.

  The GenServer owns the ETS table under normal operation, but every public
  function calls `ensure_table!/0` first so that the cache degrades
  gracefully (returns `:miss`, never crashes) even if the GenServer has not
  yet started or has been restarted.
  """

  use GenServer

  @table :salesforce_capability_cache
  @ttl_ms :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    ensure_table!()
    {:ok, %{}}
  end

  @doc """
  Returns `{:ok, value}` if a non-expired entry exists for `key`,
  otherwise `:miss`.  Never raises even if the ETS table is absent.
  """
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
    ensure_table!()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] when now - inserted_at < @ttl_ms ->
        {:ok, value}

      _ ->
        :ets.delete(@table, key)
        :miss
    end
  end

  @doc """
  Stores `value` for `key`, replacing any existing entry.
  Never raises even if the ETS table is absent.
  """
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    ensure_table!()
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond)})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Creates the named ETS table if it does not already exist.
  # Race-safe: if two processes both observe :undefined and race to create the
  # table, the loser's :ets.new/2 raises ArgumentError; we rescue it and
  # continue — the winner's table is ready for use.
  defp ensure_table! do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          {:read_concurrency, true},
          {:write_concurrency, true}
        ])
      rescue
        # Another process created the table between the whereis/1 check and
        # the new/2 call — that's fine, the table now exists.
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
