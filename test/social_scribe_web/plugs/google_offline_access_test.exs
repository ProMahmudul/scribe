defmodule SocialScribeWeb.Plugs.GoogleOfflineAccessTest do
  use SocialScribeWeb.ConnCase, async: true

  alias SocialScribeWeb.Plugs.GoogleOfflineAccess

  # Shorthand: build a conn with a pre-set params map.
  defp conn_with_params(params) do
    build_conn()
    |> Map.put(:params, params)
  end

  describe "call/2 — Google provider" do
    test "injects access_type=offline when not already set" do
      conn = conn_with_params(%{"provider" => "google"}) |> GoogleOfflineAccess.call([])

      assert conn.params["access_type"] == "offline"
    end

    test "injects prompt=consent select_account when not already set" do
      conn = conn_with_params(%{"provider" => "google"}) |> GoogleOfflineAccess.call([])

      assert conn.params["prompt"] == "consent select_account"
    end

    test "does not overwrite a caller-provided access_type" do
      conn =
        conn_with_params(%{"provider" => "google", "access_type" => "online"})
        |> GoogleOfflineAccess.call([])

      assert conn.params["access_type"] == "online"
    end

    test "does not overwrite a caller-provided prompt" do
      conn =
        conn_with_params(%{"provider" => "google", "prompt" => "none"})
        |> GoogleOfflineAccess.call([])

      assert conn.params["prompt"] == "none"
    end

    test "preserves all existing params alongside injected ones" do
      conn =
        conn_with_params(%{"provider" => "google", "scope" => "email profile"})
        |> GoogleOfflineAccess.call([])

      assert conn.params["scope"] == "email profile"
      assert conn.params["access_type"] == "offline"
      assert conn.params["prompt"] == "consent select_account"
    end
  end

  describe "call/2 — non-Google providers" do
    for provider <- ~w(hubspot salesforce linkedin facebook) do
      test "does not modify conn for #{provider}" do
        original_params = %{"provider" => unquote(provider)}

        conn =
          conn_with_params(original_params)
          |> GoogleOfflineAccess.call([])

        assert conn.params == original_params
      end
    end

    test "does not modify conn when no provider param is present" do
      original_params = %{"state" => "abc123"}

      conn =
        conn_with_params(original_params)
        |> GoogleOfflineAccess.call([])

      assert conn.params == original_params
    end
  end
end
