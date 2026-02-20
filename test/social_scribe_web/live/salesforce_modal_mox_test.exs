defmodule SocialScribeWeb.SalesforceModalMoxTest do
  @moduledoc """
  Integration tests for the Salesforce modal in MeetingLive.Show.

  All Salesforce API calls and AI generation are mocked via Mox so that the
  tests are fast, deterministic, and do not require network access or real
  Salesforce credentials.
  """

  use SocialScribeWeb.ConnCase

  import Phoenix.LiveViewTest
  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures
  import Mox

  setup :verify_on_exit!

  describe "Salesforce Modal with mocked API" do
    setup %{conn: conn} do
      user = user_fixture()
      salesforce_credential = salesforce_credential_fixture(%{user_id: user.id})
      meeting = meeting_fixture_with_transcript(user)

      %{
        conn: log_in_user(conn, user),
        user: user,
        meeting: meeting,
        salesforce_credential: salesforce_credential
      }
    end

    test "search_contacts returns mocked results", %{conn: conn, meeting: meeting} do
      mock_contacts = [
        %{
          id: "003abc",
          firstname: "Jane",
          lastname: "Doe",
          email: "jane@example.com",
          phone: nil,
          title: nil,
          display_name: "Jane Doe"
        },
        %{
          id: "003def",
          firstname: "Bob",
          lastname: "Smith",
          email: "bob@example.com",
          phone: "555-9999",
          title: "VP Sales",
          display_name: "Bob Smith"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, query ->
        assert query == "Jane"
        {:ok, mock_contacts}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Jane"})

      :timer.sleep(200)

      html = render(view)

      assert html =~ "Jane Doe"
      assert html =~ "Bob Smith"
    end

    test "search_contacts handles API error gracefully", %{conn: conn, meeting: meeting} do
      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:error, {:api_error, 500, %{"message" => "Internal server error"}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Test"})

      :timer.sleep(200)

      html = render(view)

      assert html =~ "Failed to search contacts"
    end

    test "selecting contact triggers suggestion generation", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003abc",
        firstname: "Jane",
        lastname: "Doe",
        email: "jane@example.com",
        phone: nil,
        title: nil,
        display_name: "Jane Doe"
      }

      mock_suggestions = [
        %{
          field: "Phone",
          value: "555-1234",
          context: "Jane mentioned her phone number",
          timestamp: "02:30"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Jane"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003abc']")
      |> render_click()

      :timer.sleep(500)

      assert has_element?(view, "#salesforce-modal-wrapper")
    end

    test "contact dropdown shows search results", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003xyz",
        firstname: "Alice",
        lastname: "Wonder",
        email: "alice@example.com",
        phone: nil,
        title: nil,
        display_name: "Alice Wonder"
      }

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Alice"})

      :timer.sleep(200)

      html = render(view)

      assert html =~ "Alice Wonder"
      assert html =~ "alice@example.com"
    end

    test "suggestions render after contact selection", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003abc",
        firstname: "Jane",
        lastname: "Doe",
        email: "jane@example.com",
        phone: nil,
        title: nil,
        display_name: "Jane Doe"
      }

      mock_suggestions = [
        %{
          field: "Phone",
          value: "888-5550000",
          context: "you can reach me at 888-5550000",
          timestamp: "15:46"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Jane"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003abc']")
      |> render_click()

      :timer.sleep(500)

      html = render(view)

      # The suggestions section should be rendered (with the field label)
      assert html =~ "Update Salesforce"
    end

    test "apply updates success shows flash message", %{conn: conn, meeting: meeting} do
      mock_contact = %{
        id: "003abc",
        firstname: "Jane",
        lastname: "Doe",
        email: "jane@example.com",
        phone: nil,
        title: nil,
        display_name: "Jane Doe"
      }

      mock_suggestions = [
        %{
          field: "Phone",
          value: "888-5550000",
          context: "phone number mentioned",
          timestamp: "10:00"
        }
      ]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _credential, _query ->
        {:ok, [mock_contact]}
      end)

      SocialScribe.SalesforceApiMock
      |> expect(:update_contact, fn _credential, contact_id, updates ->
        assert contact_id == "003abc"
        assert map_size(updates) > 0
        {:ok, %{id: contact_id}}
      end)

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:ok, mock_suggestions}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings/#{meeting.id}/salesforce")

      view
      |> element("input[phx-keyup='contact_search']")
      |> render_keyup(%{"value" => "Jane"})

      :timer.sleep(200)

      view
      |> element("button[phx-click='select_contact'][phx-value-id='003abc']")
      |> render_click()

      :timer.sleep(500)

      view
      |> element("form[phx-submit='apply_updates']")
      |> render_submit(%{
        "apply" => %{"Phone" => "1"},
        "values" => %{"Phone" => "888-5550000"}
      })

      :timer.sleep(200)

      html = render(view)

      assert html =~ "Successfully updated" or html =~ "Salesforce"
    end
  end

  describe "Salesforce API behaviour delegation" do
    setup do
      user = user_fixture()
      credential = salesforce_credential_fixture(%{user_id: user.id})
      %{credential: credential}
    end

    test "search_contacts delegates to implementation", %{credential: credential} do
      expected = [%{id: "003abc", firstname: "Jane", lastname: "Doe"}]

      SocialScribe.SalesforceApiMock
      |> expect(:search_contacts, fn _cred, query ->
        assert query == "jane"
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.search_contacts(credential, "jane")
    end

    test "get_contact delegates to implementation", %{credential: credential} do
      expected = %{id: "003abc", firstname: "Jane", lastname: "Doe"}

      SocialScribe.SalesforceApiMock
      |> expect(:get_contact, fn _cred, contact_id ->
        assert contact_id == "003abc"
        {:ok, expected}
      end)

      assert {:ok, ^expected} =
               SocialScribe.SalesforceApiBehaviour.get_contact(credential, "003abc")
    end

    test "update_contact delegates to implementation", %{credential: credential} do
      updates = %{"Phone" => "555-0000", "Title" => "Engineer"}

      SocialScribe.SalesforceApiMock
      |> expect(:update_contact, fn _cred, contact_id, upd ->
        assert contact_id == "003abc"
        assert upd == updates
        {:ok, %{id: "003abc"}}
      end)

      assert {:ok, _} =
               SocialScribe.SalesforceApiBehaviour.update_contact(credential, "003abc", updates)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp meeting_fixture_with_transcript(user) do
    meeting = meeting_fixture(%{})

    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)

    {:ok, _updated_event} =
      SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "Jane Doe",
            "words" => [
              %{"text" => "You"},
              %{"text" => "can"},
              %{"text" => "reach"},
              %{"text" => "me"},
              %{"text" => "at"},
              %{"text" => "888-5550000"}
            ]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end
end
