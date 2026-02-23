defmodule SocialScribe.Salesforce.CapabilityCache do
  @moduledoc """
  ETS-backed cache for per-org Salesforce capability flags.

  Capabilities are cached per `instance_url` with a 1-hour TTL to avoid
  repeated describe/SOQL calls on every contact update operation.

  The GenServer owns the ETS table so the table lives for the lifetime of
  the application.
  """

  use GenServer

  @table :salesforce_capability_cache
  @ttl_ms :timer.hours(1)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc """
  Returns `{:ok, value}` if a non-expired entry exists for `key`,
  otherwise `:miss`.
  """
  @spec get(term()) :: {:ok, term()} | :miss
  def get(key) do
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
  """
  @spec put(term(), term()) :: :ok
  def put(key, value) do
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond)})
    :ok
  end
end
