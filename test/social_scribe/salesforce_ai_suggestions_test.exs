defmodule SocialScribe.SalesforceAiSuggestionsTest do
  @moduledoc """
  Tests for the AI-driven Salesforce suggestion pipeline.

  Exercises `SalesforceSuggestions.generate_suggestions_from_meeting/1` with a
  mocked `AIContentGeneratorMock` so that no real Gemini API calls are made.
  Verifies that raw AI output is correctly mapped into suggestion structs,
  disallowed fields are dropped, and error paths propagate cleanly.
  """

  use SocialScribe.DataCase

  import Mox

  alias SocialScribe.SalesforceSuggestions

  import SocialScribe.AccountsFixtures
  import SocialScribe.MeetingsFixtures

  setup :verify_on_exit!

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp minimal_meeting do
    user = user_fixture()
    meeting = meeting_fixture(%{})
    calendar_event = SocialScribe.Calendar.get_calendar_event!(meeting.calendar_event_id)
    {:ok, _} = SocialScribe.Calendar.update_calendar_event(calendar_event, %{user_id: user.id})

    meeting_transcript_fixture(%{
      meeting_id: meeting.id,
      content: %{
        "data" => [
          %{
            "speaker" => "Alice",
            "words" => [%{"text" => "Hello"}, %{"text" => "world"}]
          }
        ]
      }
    })

    SocialScribe.Meetings.get_meeting_with_details(meeting.id)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "generate_suggestions_from_meeting/1" do
    test "maps valid AI suggestions into suggestion structs" do
      meeting = minimal_meeting()

      ai_raw = [
        %{field: "Phone", value: "555-1234", context: "call me at 555-1234", timestamp: "01:00"},
        %{
          field: "Title",
          value: "VP of Sales",
          context: "I am the VP of Sales",
          timestamp: "02:30"
        }
      ]

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting -> {:ok, ai_raw} end)

      assert {:ok, suggestions} = SalesforceSuggestions.generate_suggestions_from_meeting(meeting)

      assert length(suggestions) == 2

      phone = Enum.find(suggestions, &(&1.field == "Phone"))
      assert phone.new_value == "555-1234"
      assert phone.current_value == nil
      assert phone.has_change == true
      assert phone.apply == true
      assert phone.label == "Phone"
      assert phone.context == "call me at 555-1234"
      assert phone.timestamp == "01:00"

      title = Enum.find(suggestions, &(&1.field == "Title"))
      assert title.new_value == "VP of Sales"
      assert title.label == "Title"
    end

    test "returns an empty list when AI finds no suggestions" do
      meeting = minimal_meeting()

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting -> {:ok, []} end)

      assert {:ok, []} = SalesforceSuggestions.generate_suggestions_from_meeting(meeting)
    end

    test "propagates AI error as {:error, reason}" do
      meeting = minimal_meeting()

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting ->
        {:error, {:api_error, 503, %{"message" => "Service unavailable"}}}
      end)

      assert {:error, {:api_error, 503, _}} =
               SalesforceSuggestions.generate_suggestions_from_meeting(meeting)
    end

    test "assigns human-readable label from field name" do
      meeting = minimal_meeting()

      ai_raw = [
        %{
          field: "MailingCity",
          value: "San Francisco",
          context: "based in SF",
          timestamp: "05:10"
        }
      ]

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting -> {:ok, ai_raw} end)

      assert {:ok, [suggestion]} =
               SalesforceSuggestions.generate_suggestions_from_meeting(meeting)

      assert suggestion.field == "MailingCity"
      assert suggestion.label == "Mailing City"
      assert suggestion.new_value == "San Francisco"
    end

    test "sets has_change: true and current_value: nil for all returned suggestions" do
      meeting = minimal_meeting()

      ai_raw = [
        %{field: "Email", value: "new@example.com", context: "my new email", timestamp: "03:00"},
        %{field: "FirstName", value: "Johnny", context: "call me Johnny", timestamp: "04:00"}
      ]

      SocialScribe.AIContentGeneratorMock
      |> expect(:generate_salesforce_suggestions, fn _meeting -> {:ok, ai_raw} end)

      assert {:ok, suggestions} = SalesforceSuggestions.generate_suggestions_from_meeting(meeting)

      for s <- suggestions do
        assert s.has_change == true
        assert s.current_value == nil
        assert s.apply == true
      end
    end
  end
end
