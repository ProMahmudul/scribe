defmodule SocialScribe.SalesforceSuggestionsTest do
  use SocialScribe.DataCase

  alias SocialScribe.SalesforceSuggestions

  describe "merge_with_contact/2" do
    test "sets current_value from contact and filters unchanged suggestions" do
      suggestions = [
        %{
          field: "Phone",
          label: "Phone",
          current_value: nil,
          new_value: "555-1234",
          context: "Mentioned in call",
          timestamp: "01:23",
          apply: true,
          has_change: true
        },
        %{
          field: "Title",
          label: "Title",
          current_value: nil,
          new_value: "VP of Sales",
          context: "She said she is VP of Sales",
          timestamp: "03:10",
          apply: true,
          has_change: true
        }
      ]

      # Contact already has the title — only phone should remain.
      contact = %{
        id: "003abc",
        firstname: "Jane",
        lastname: "Doe",
        email: "jane@example.com",
        phone: nil,
        title: "VP of Sales"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      [phone_suggestion] = result
      assert phone_suggestion.field == "Phone"
      assert phone_suggestion.new_value == "555-1234"
      assert phone_suggestion.current_value == nil
      assert phone_suggestion.has_change == true
    end

    test "returns empty list when all suggestions match current contact values" do
      suggestions = [
        %{
          field: "Email",
          label: "Email",
          current_value: nil,
          new_value: "jane@example.com",
          context: "Email was mentioned",
          timestamp: "00:45",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003abc",
        email: "jane@example.com"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert result == []
    end

    test "handles empty suggestions list" do
      contact = %{id: "003abc", email: "jane@example.com"}

      result = SalesforceSuggestions.merge_with_contact([], contact)

      assert result == []
    end

    test "sets current_value for mailing address fields" do
      suggestions = [
        %{
          field: "MailingCity",
          label: "Mailing City",
          current_value: nil,
          new_value: "San Francisco",
          context: "We are based in San Francisco",
          timestamp: "07:30",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003xyz",
        mailing_city: nil
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 1
      assert hd(result).field == "MailingCity"
      assert hd(result).current_value == nil
    end

    test "filters out suggestion when mailing city already matches" do
      suggestions = [
        %{
          field: "MailingCity",
          label: "Mailing City",
          current_value: nil,
          new_value: "Austin",
          context: "office is in Austin",
          timestamp: "05:00",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003xyz",
        mailing_city: "Austin"
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert result == []
    end

    test "all suggestions kept when contact has no matching data" do
      suggestions = [
        %{
          field: "Phone",
          label: "Phone",
          current_value: nil,
          new_value: "555-0000",
          context: "test",
          timestamp: "01:00",
          apply: true,
          has_change: true
        },
        %{
          field: "Title",
          label: "Title",
          current_value: nil,
          new_value: "Engineer",
          context: "test",
          timestamp: "02:00",
          apply: true,
          has_change: true
        }
      ]

      contact = %{
        id: "003abc",
        phone: nil,
        title: nil
      }

      result = SalesforceSuggestions.merge_with_contact(suggestions, contact)

      assert length(result) == 2
    end
  end

  describe "field_labels/0" do
    test "returns a map of Salesforce field names to human-readable labels" do
      labels = SalesforceSuggestions.field_labels()

      assert labels["Phone"] == "Phone"
      assert labels["FirstName"] == "First Name"
      assert labels["LastName"] == "Last Name"
      assert labels["Email"] == "Email"
      assert labels["Title"] == "Title"
      assert labels["MailingStreet"] == "Mailing Street"
      assert labels["MailingCity"] == "Mailing City"
      assert labels["MailingState"] == "Mailing State"
      assert labels["MailingPostalCode"] == "Mailing Postal Code"
      assert labels["MailingCountry"] == "Mailing Country"
    end
  end

  describe "build_update_payload/1" do
    # Restore whatever salesforce config was present before each test.
    setup do
      original = Application.get_env(:social_scribe, :salesforce)

      on_exit(fn ->
        if original do
          Application.put_env(:social_scribe, :salesforce, original)
        else
          Application.delete_env(:social_scribe, :salesforce)
        end
      end)

      :ok
    end

    test "injects MailingCountry from config when MailingState is present but MailingCountry is not" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")

      payload = %{"MailingState" => "CA", "Phone" => "555-0001"}
      result = SalesforceSuggestions.build_update_payload(payload)

      assert result["MailingCountry"] == "United States"
      assert result["MailingState"] == "CA"
      assert result["Phone"] == "555-0001"
    end

    test "drops MailingState and logs a warning when no default_country is configured" do
      Application.put_env(:social_scribe, :salesforce, default_country: nil)

      payload = %{"MailingState" => "TX", "Phone" => "555-0002"}

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          result = SalesforceSuggestions.build_update_payload(payload)

          refute Map.has_key?(result, "MailingState")
          assert result["Phone"] == "555-0002"
        end)

      assert log =~ "Skipping MailingState update"
    end

    test "returns payload unchanged when MailingCountry is already present" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")

      payload = %{"MailingState" => "NY", "MailingCountry" => "Canada"}
      result = SalesforceSuggestions.build_update_payload(payload)

      assert result == payload
    end

    test "returns payload unchanged when MailingState is absent" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")

      payload = %{"Phone" => "555-0003", "Email" => "a@example.com"}
      result = SalesforceSuggestions.build_update_payload(payload)

      assert result == payload
    end

    test "returns empty map unchanged" do
      result = SalesforceSuggestions.build_update_payload(%{})

      assert result == %{}
    end
  end
end
