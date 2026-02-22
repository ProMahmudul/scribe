defmodule SocialScribeWeb.Plugs.GoogleOfflineAccess do
  @moduledoc """
  Plug that injects Google-specific OAuth params into `conn.params` before
  Ueberauth processes the request phase.

  Ensures every Google authorization request includes:
    - `access_type=offline`  — so Google issues a refresh token
    - `prompt=consent select_account` — forces the consent screen so Google
      actually returns the refresh token even for previously-authorized accounts

  Uses `Map.put_new/3` so that any values already present in `conn.params`
  (e.g., set deliberately by a caller) are preserved rather than overwritten.

  This plug should be placed in `AuthController` **before** `plug Ueberauth`,
  and restricted to the `:request` action so it does not interfere with the
  OAuth callback phase.
  """

  @doc false
  def init(opts), do: opts

  @doc false
  def call(%Plug.Conn{params: %{"provider" => "google"}} = conn, _opts) do
    updated_params =
      conn.params
      |> Map.put_new("access_type", "offline")
      |> Map.put_new("prompt", "consent select_account")

    %{conn | params: updated_params}
  end

  def call(conn, _opts), do: conn
end
