defmodule Ueberauth.Strategy.Salesforce do
  @moduledoc """
  Salesforce strategy for Ueberauth.

  Implements the OAuth2 authorization code flow for Salesforce Connected Apps.
  After token exchange, the strategy fetches basic identity info from Salesforce's
  identity endpoint (`/services/oauth2/userinfo`) to populate `auth.info`.

  The Salesforce `instance_url` (org-specific API base URL) is captured from the
  token response and stored in `auth.extra.raw_info.instance_url`. The
  `AuthController` callback persists it in `user_credentials.metadata`.

  ## Configuration

  See `Ueberauth.Strategy.Salesforce.OAuth` for required env vars:
  `SALESFORCE_CLIENT_ID`, `SALESFORCE_CLIENT_SECRET`, `SALESFORCE_SITE`.

  ## Scopes

  The recommended minimal scope set is: `api refresh_token offline_access`.
  """

  use Ueberauth.Strategy,
    uid_field: :sub,
    default_scope: "api refresh_token offline_access",
    oauth2_module: Ueberauth.Strategy.Salesforce.OAuth

  alias Ueberauth.Auth.Info
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Extra

  @doc """
  Initiates the Salesforce OAuth flow by redirecting to the authorization endpoint.
  """
  def handle_request!(conn) do
    scopes = conn.params["scope"] || option(conn, :default_scope)

    opts =
      [scope: scopes, redirect_uri: callback_url(conn)]
      |> with_optional(:prompt, conn)
      |> with_param(:prompt, conn)
      |> with_state_param(conn)

    redirect!(conn, Ueberauth.Strategy.Salesforce.OAuth.authorize_url!(opts))
  end

  @doc """
  Handles the callback from Salesforce, exchanging the code for tokens
  and fetching user identity.
  """
  def handle_callback!(%Plug.Conn{params: %{"code" => code}} = conn) do
    opts = [redirect_uri: callback_url(conn)]

    case Ueberauth.Strategy.Salesforce.OAuth.get_access_token([code: code], opts) do
      {:ok, token} ->
        fetch_user(conn, token)

      {:error, {error_code, error_description}} ->
        set_errors!(conn, [error(error_code, error_description)])
    end
  end

  def handle_callback!(conn) do
    set_errors!(conn, [error("missing_code", "No code received")])
  end

  @doc """
  Cleans up private Salesforce data from the connection after callback.
  """
  def handle_cleanup!(conn) do
    conn
    |> put_private(:salesforce_token, nil)
    |> put_private(:salesforce_user, nil)
  end

  @doc """
  Returns the unique identifier for the Salesforce user.
  Uses the `sub` field from the identity endpoint (stable Salesforce user ID).
  """
  def uid(conn) do
    conn.private.salesforce_user["sub"] || conn.private.salesforce_user["user_id"]
  end

  @doc """
  Extracts OAuth credentials including tokens and expiry.
  """
  def credentials(conn) do
    token = conn.private.salesforce_token

    %Credentials{
      expires: true,
      expires_at: token.expires_at,
      scopes: String.split(token.other_params["scope"] || "", " "),
      token: token.access_token,
      refresh_token: token.refresh_token,
      token_type: token.token_type
    }
  end

  @doc """
  Populates the `info` struct from the Salesforce identity endpoint response.
  """
  def info(conn) do
    user = conn.private.salesforce_user

    %Info{
      email: user["email"],
      name: user["name"],
      first_name: user["given_name"],
      last_name: user["family_name"],
      nickname: user["preferred_username"]
    }
  end

  @doc """
  Stores the raw token and user info, including `instance_url`, in `extra`.
  The `instance_url` is required by `SalesforceApi` to build API request URLs.
  """
  def extra(conn) do
    token = conn.private.salesforce_token
    instance_url = token.other_params["instance_url"]

    %Extra{
      raw_info: %{
        token: token,
        user: conn.private.salesforce_user,
        instance_url: instance_url
      }
    }
  end

  # Fetches the authenticated user's identity from Salesforce and stores
  # both the token and user map in private conn assigns for later extraction.
  defp fetch_user(conn, token) do
    conn = put_private(conn, :salesforce_token, token)

    instance_url = token.other_params["instance_url"]

    identity_url =
      cond do
        # Salesforce returns an absolute identity URL in the token response
        Map.has_key?(token.other_params, "id") ->
          token.other_params["id"]

        # Fallback: construct from instance_url
        instance_url ->
          "#{instance_url}/services/oauth2/userinfo"

        true ->
          "https://login.salesforce.com/services/oauth2/userinfo"
      end

    case fetch_identity(identity_url, token.access_token) do
      {:ok, user} ->
        put_private(conn, :salesforce_user, user)

      {:error, reason} ->
        set_errors!(conn, [error("identity_error", reason)])
    end
  end

  defp fetch_identity(url, access_token) do
    client = Tesla.client([Tesla.Middleware.JSON])

    case Tesla.get(client, url, headers: [{"Authorization", "Bearer #{access_token}"}]) do
      {:ok, %Tesla.Env{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, "Failed to fetch Salesforce identity: #{status} - #{inspect(body)}"}

      {:error, reason} ->
        {:error, "HTTP error fetching Salesforce identity: #{inspect(reason)}"}
    end
  end

  defp with_param(opts, key, conn) do
    if value = conn.params[to_string(key)], do: Keyword.put(opts, key, value), else: opts
  end

  defp with_optional(opts, key, conn) do
    if option(conn, key), do: Keyword.put(opts, key, option(conn, key)), else: opts
  end

  defp option(conn, key) do
    Keyword.get(options(conn), key, Keyword.get(default_options(), key))
  end
end
