defmodule SocialScribe.SalesforceApi do
  @moduledoc """
  Salesforce CRM API client for contact operations.

  Uses the REST API v59.0 and builds the base URL dynamically from the
  credential's `metadata["instance_url"]`, which is captured during OAuth
  and unique per Salesforce org.

  All public functions accept a `%UserCredential{}` and automatically
  handle token validation.  Token refresh is not implemented here because
  Salesforce refresh tokens are long-lived and typically don't expire
  during a user session; the credential is used as-is.

  ## Contact fields

  The minimal set of fields surfaced in the UI:
  `FirstName`, `LastName`, `Email`, `Phone`, `Title`,
  `MailingStreet`, `MailingCity`, `MailingState`, `MailingPostalCode`.
  """

  @behaviour SocialScribe.SalesforceApiBehaviour

  alias SocialScribe.Accounts.UserCredential
  alias SocialScribe.Salesforce.TokenRefresher

  require Logger

  @api_version "v59.0"

  # Salesforce field names to query and return.
  @contact_fields ~w(
    FirstName LastName Email Phone Title
    MailingStreet MailingCity MailingState MailingPostalCode MailingCountry
  )

  # ETS cache key prefix for address-code capability checks.
  @cap_key_prefix "sf_address_code_fields"

  @doc """
  Searches Salesforce contacts whose Name contains `query` (case-insensitive).
  Uses a SOQL query with a LIKE filter; returns up to 10 results.

  ## Return shape

      {:ok, [%{id: "003...", firstname: "Jane", lastname: "Doe", ...}]}
  """
  @impl SocialScribe.SalesforceApiBehaviour
  def search_contacts(%UserCredential{} = credential, query) when is_binary(query) do
    with_sf_token_refresh(credential, fn cred ->
      escaped = String.replace(query, "'", "\\'")
      fields = Enum.join(@contact_fields, ", ")

      soql =
        "SELECT Id, #{fields} FROM Contact " <>
          "WHERE Name LIKE '%#{escaped}%' LIMIT 10"

      url = "/services/data/#{@api_version}/query?q=#{URI.encode(soql)}"

      case Tesla.get(client(cred), url) do
        {:ok, %Tesla.Env{status: 200, body: %{"records" => records}}} ->
          {:ok, Enum.map(records, &format_contact/1)}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          Logger.error("Salesforce search_contacts error #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Salesforce search_contacts HTTP error: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Fetches a single Salesforce contact by record ID.

  ## Return shape

      {:ok, %{id: "003...", firstname: "Jane", ...}}
      {:error, :not_found}
  """
  @impl SocialScribe.SalesforceApiBehaviour
  def get_contact(%UserCredential{} = credential, contact_id) do
    with_sf_token_refresh(credential, fn cred ->
      fields_param = Enum.join(@contact_fields, ",")
      url = "/services/data/#{@api_version}/sobjects/Contact/#{contact_id}?fields=#{fields_param}"

      case Tesla.get(client(cred), url) do
        {:ok, %Tesla.Env{status: 200, body: body}} ->
          {:ok, format_contact(body)}

        {:ok, %Tesla.Env{status: 404}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          Logger.error("Salesforce get_contact error #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Salesforce get_contact HTTP error: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Updates a Salesforce contact record using the PATCH method.
  `updates` is a map of Salesforce field API names to new string values.

  Salesforce PATCH returns HTTP 204 No Content on success.  This function
  returns `{:ok, %{id: contact_id}}` in that case.

  ## Examples

      update_contact(credential, "003...", %{"Phone" => "555-0000"})
  """
  @impl SocialScribe.SalesforceApiBehaviour
  def update_contact(%UserCredential{} = credential, contact_id, updates)
      when is_map(updates) do
    with_sf_token_refresh(credential, fn cred ->
      url = "/services/data/#{@api_version}/sobjects/Contact/#{contact_id}"

      case Tesla.patch(client(cred), url, updates) do
        {:ok, %Tesla.Env{status: status}} when status in [200, 204] ->
          {:ok, %{id: contact_id}}

        {:ok, %Tesla.Env{status: 404}} ->
          {:error, :not_found}

        {:ok, %Tesla.Env{status: status, body: body}} ->
          Logger.error("Salesforce update_contact error #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.error("Salesforce update_contact HTTP error: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end)
  end

  @doc """
  Returns `true` if the Salesforce org has State/Country/Territory Picklists
  enabled — i.e. `MailingStateCode` and `MailingCountryCode` are valid
  Contact API fields.

  The result is cached per org (keyed by `instance_url`) for ~1 hour to avoid
  a redundant API round-trip on every contact update.
  """
  @impl SocialScribe.SalesforceApiBehaviour
  def uses_address_code_fields?(%UserCredential{} = credential) do
    instance_url = (credential.metadata || %{})["instance_url"] || ""
    cache_key = {@cap_key_prefix, instance_url}

    case SocialScribe.Salesforce.CapabilityCache.get(cache_key) do
      {:ok, value} ->
        value

      :miss ->
        value = fetch_address_code_support(credential)
        SocialScribe.Salesforce.CapabilityCache.put(cache_key, value)
        value
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Checks whether the org exposes MailingStateCode / MailingCountryCode by
  # running a zero-row SOQL query.  A 200 response means the fields exist; a
  # 400 with INVALID_FIELD means they don't (picklists not enabled).
  defp fetch_address_code_support(%UserCredential{} = credential) do
    soql = "SELECT MailingStateCode, MailingCountryCode FROM Contact LIMIT 0"
    url = "/services/data/#{@api_version}/query?q=#{URI.encode(soql)}"

    case Tesla.get(client(credential), url) do
      {:ok, %Tesla.Env{status: 200}} ->
        true

      {:ok, %Tesla.Env{status: 400, body: body}} ->
        if address_field_not_found?(body) do
          false
        else
          Logger.warning("Salesforce address capability check: unexpected 400 — #{inspect(body)}")

          false
        end

      {:ok, %Tesla.Env{status: status, body: body}} ->
        Logger.warning(
          "Salesforce address capability check: unexpected #{status} — #{inspect(body)}"
        )

        false

      {:error, reason} ->
        Logger.warning("Salesforce address capability check HTTP error: #{inspect(reason)}")

        false
    end
  end

  defp address_field_not_found?(body) when is_list(body) do
    Enum.any?(body, &match?(%{"errorCode" => "INVALID_FIELD"}, &1))
  end

  defp address_field_not_found?(_), do: false

  # Build a Tesla client that targets the org-specific instance_url.
  # Every Salesforce org has its own subdomain, stored in credential metadata.
  defp client(%UserCredential{token: token, metadata: metadata}) do
    instance_url = (metadata || %{})["instance_url"] || raise_missing_instance_url()

    Tesla.client([
      {Tesla.Middleware.BaseUrl, instance_url},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers,
       [
         {"Authorization", "Bearer #{token}"},
         {"Content-Type", "application/json"}
       ]}
    ])
  end

  defp raise_missing_instance_url do
    raise ArgumentError,
          "Salesforce credential is missing instance_url in metadata. " <>
            "Re-connect the Salesforce account via /auth/salesforce."
  end

  # Normalise a Salesforce REST API contact record into a flat map with atom
  # keys that match the field labels used in SalesforceSuggestions.
  defp format_contact(%{"Id" => id} = record) do
    %{
      id: id,
      firstname: record["FirstName"],
      lastname: record["LastName"],
      email: record["Email"],
      phone: record["Phone"],
      title: record["Title"],
      mailing_street: record["MailingStreet"],
      mailing_city: record["MailingCity"],
      mailing_state: record["MailingState"],
      mailing_postal_code: record["MailingPostalCode"],
      mailing_country: record["MailingCountry"],
      display_name: format_display_name(record)
    }
  end

  defp format_contact(_), do: nil

  defp format_display_name(record) do
    first = record["FirstName"] || ""
    last = record["LastName"] || ""
    email = record["Email"] || ""
    name = String.trim("#{first} #{last}")
    if name == "", do: email, else: name
  end

  # ---------------------------------------------------------------------------
  # Token-refresh wrapper
  # ---------------------------------------------------------------------------

  # Executes `api_call.(credential)`.  If the result is a 401
  # INVALID_SESSION_ID, attempts to refresh the Salesforce access token and
  # retries the call once.  On persistent session failure (or if there is no
  # refresh_token), returns `{:error, :session_expired}` so callers can
  # surface a user-friendly reconnect prompt.
  defp with_sf_token_refresh(%UserCredential{} = credential, api_call) do
    case api_call.(credential) do
      {:error, {:api_error, 401, body}} when is_list(body) ->
        if invalid_session?(body) do
          Logger.info("Salesforce session invalid — attempting token refresh...")
          retry_after_refresh(credential, api_call)
        else
          {:error, {:api_error, 401, body}}
        end

      other ->
        other
    end
  end

  defp retry_after_refresh(credential, api_call) do
    case TokenRefresher.refresh_credential(credential) do
      {:ok, refreshed} ->
        case api_call.(refreshed) do
          {:error, {:api_error, 401, _}} ->
            Logger.warning("Salesforce session still invalid after token refresh")
            {:error, :session_expired}

          result ->
            result
        end

      {:error, reason} ->
        Logger.warning("Salesforce token refresh failed: #{inspect(reason)}")
        {:error, :session_expired}
    end
  end

  defp invalid_session?(errors) when is_list(errors) do
    Enum.any?(errors, &match?(%{"errorCode" => "INVALID_SESSION_ID"}, &1))
  end
end
