defmodule SocialScribe.Salesforce.TokenRefresher do
  @moduledoc """
  Refreshes Salesforce OAuth access tokens using the stored refresh_token.

  Salesforce issues long-lived refresh tokens with no built-in expiry, but
  access tokens expire based on the org's Connected App token timeout policy
  (default 2 hours for most orgs).  When an API call receives a 401
  INVALID_SESSION_ID, this module can exchange the refresh_token for a new
  access_token and persist it to the database.

  The token endpoint is `{SALESFORCE_SITE}/services/oauth2/token`
  (e.g. `https://login.salesforce.com/services/oauth2/token` for production
  or `https://test.salesforce.com/services/oauth2/token` for sandboxes).
  """

  alias SocialScribe.Accounts

  require Logger

  @token_path "/services/oauth2/token"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Attempts to refresh the access token for `credential` using its stored
  `refresh_token`.  On success, persists the new token to the database and
  returns `{:ok, updated_credential}`.  Returns `{:error, reason}` if the
  credential has no `refresh_token` or if the Salesforce token endpoint
  rejects the request.
  """
  @spec refresh_credential(UserCredential.t()) ::
          {:ok, UserCredential.t()} | {:error, term()}
  def refresh_credential(credential) do
    case credential.refresh_token do
      nil ->
        {:error, :no_refresh_token}

      refresh_token ->
        do_refresh(credential, refresh_token)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_refresh(credential, refresh_token) do
    site =
      Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
      |> Keyword.get(:site, "https://login.salesforce.com")

    client_id =
      Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
      |> Keyword.get(:client_id)

    client_secret =
      Application.get_env(:ueberauth, Ueberauth.Strategy.Salesforce.OAuth, [])
      |> Keyword.get(:client_secret)

    body = %{
      grant_type: "refresh_token",
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token
    }

    tesla_client =
      Tesla.client([
        {Tesla.Middleware.BaseUrl, site},
        {Tesla.Middleware.FormUrlencoded,
         encode: &Plug.Conn.Query.encode/1, decode: &Plug.Conn.Query.decode/1},
        Tesla.Middleware.JSON
      ])

    case Tesla.post(tesla_client, @token_path, body) do
      {:ok, %Tesla.Env{status: 200, body: response}} ->
        persist_new_token(credential, response)

      {:ok, %Tesla.Env{status: status, body: error_body}} ->
        Logger.warning(
          "Salesforce token refresh failed #{status}: #{inspect(error_body)}"
        )

        {:error, {:refresh_failed, status, error_body}}

      {:error, reason} ->
        Logger.warning("Salesforce token refresh HTTP error: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp persist_new_token(credential, response) do
    new_token = response["access_token"]
    # Salesforce refresh responses may include an updated instance_url.
    new_instance_url = response["instance_url"]

    attrs =
      if new_instance_url && new_instance_url != "" do
        updated_metadata = Map.put(credential.metadata || %{}, "instance_url", new_instance_url)
        %{token: new_token, metadata: updated_metadata}
      else
        %{token: new_token}
      end

    case Accounts.update_user_credential(credential, attrs) do
      {:ok, updated} ->
        Logger.info("Salesforce access token refreshed for credential #{credential.id}")
        {:ok, updated}

      {:error, changeset} ->
        Logger.error("Failed to persist refreshed Salesforce token: #{inspect(changeset)}")
        {:error, {:persist_failed, changeset}}
    end
  end
end
