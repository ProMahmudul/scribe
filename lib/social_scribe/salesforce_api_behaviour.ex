defmodule SocialScribe.SalesforceApiBehaviour do
  @moduledoc """
  Behaviour for the Salesforce CRM API client.

  Allows swapping the real implementation for a mock in tests:

      # test/test_helper.exs
      Mox.defmock(SocialScribe.SalesforceApiMock, for: SocialScribe.SalesforceApiBehaviour)
      Application.put_env(:social_scribe, :salesforce_api, SocialScribe.SalesforceApiMock)

  The implementation module is resolved at runtime via application config so
  that it can be overridden in tests without recompilation.
  """

  alias SocialScribe.Accounts.UserCredential

  @doc """
  Searches Salesforce contacts matching `query` using a SOQL LIKE filter.
  Returns up to 10 results formatted as plain maps with atom keys.
  """
  @callback search_contacts(credential :: UserCredential.t(), query :: String.t()) ::
              {:ok, list(map())} | {:error, any()}

  @doc """
  Fetches a single Salesforce contact by its record ID.
  Returns a formatted map with atom keys or `{:error, :not_found}`.
  """
  @callback get_contact(credential :: UserCredential.t(), contact_id :: String.t()) ::
              {:ok, map()} | {:error, any()}

  @doc """
  Patches a Salesforce contact record with the provided field updates.
  `updates` is a map of Salesforce field API names to new values.
  """
  @callback update_contact(
              credential :: UserCredential.t(),
              contact_id :: String.t(),
              updates :: map()
            ) :: {:ok, map()} | {:error, any()}

  @doc """
  Returns `true` if the Salesforce org has State/Country/Territory Picklists
  enabled, meaning `MailingStateCode` and `MailingCountryCode` are valid
  Contact fields.  The result is cached per org for ~1 hour.
  """
  @callback uses_address_code_fields?(credential :: UserCredential.t()) :: boolean()

  # Delegation helpers — call these from application code instead of the
  # behaviour module directly so the implementation is always resolved
  # from config.

  def search_contacts(credential, query) do
    impl().search_contacts(credential, query)
  end

  def get_contact(credential, contact_id) do
    impl().get_contact(credential, contact_id)
  end

  def update_contact(credential, contact_id, updates) do
    impl().update_contact(credential, contact_id, updates)
  end

  def uses_address_code_fields?(credential) do
    impl().uses_address_code_fields?(credential)
  end

  defp impl do
    Application.get_env(:social_scribe, :salesforce_api, SocialScribe.SalesforceApi)
  end
end
