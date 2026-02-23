defmodule SocialScribe.SalesforceSuggestions do
  @moduledoc """
  Generates and formats Salesforce contact update suggestions by combining
  AI-extracted data with existing Salesforce contact information.

  The public API mirrors `SocialScribe.HubspotSuggestions`:

    1. `generate_suggestions_from_meeting/1` — generate raw AI suggestions
       without contact data (used when a contact is selected asynchronously).
    2. `merge_with_contact/2` — merge AI suggestions with the actual contact
       record fetched from Salesforce to compute `current_value` and filter
       out unchanged fields.

  Suggestion map shape:

      %{
        field: "Phone",           # Salesforce API field name
        label: "Phone",           # Human-readable label for the UI
        current_value: nil,       # Existing value from Salesforce (or nil)
        new_value: "555-0000",    # AI-extracted suggested value
        context: "...",           # Quote from transcript
        timestamp: "04:10",       # Transcript timestamp
        apply: true,              # Whether to include in the update
        has_change: true          # Whether new_value differs from current
      }
  """

  alias SocialScribe.AIContentGeneratorApi

  require Logger

  # Maps Salesforce API field names to human-readable labels for the UI.
  @field_labels %{
    "FirstName" => "First Name",
    "LastName" => "Last Name",
    "Email" => "Email",
    "Phone" => "Phone",
    "Title" => "Title",
    "MailingStreet" => "Mailing Street",
    "MailingCity" => "Mailing City",
    "MailingState" => "Mailing State",
    "MailingPostalCode" => "Mailing Postal Code",
    "MailingCountry" => "Mailing Country"
  }

  @doc """
  Generates AI suggestions from a meeting transcript without contact data.

  Returns `{:ok, suggestions}` where each suggestion has `current_value: nil`
  and `has_change: true` (since no contact data is available to compare).
  Call `merge_with_contact/2` after fetching the contact record to fill in
  `current_value` and filter unchanged fields.
  """
  def generate_suggestions_from_meeting(meeting) do
    case AIContentGeneratorApi.generate_salesforce_suggestions(meeting) do
      {:ok, ai_suggestions} ->
        suggestions =
          ai_suggestions
          |> Enum.map(fn suggestion ->
            %{
              field: suggestion.field,
              label: Map.get(@field_labels, suggestion.field, suggestion.field),
              current_value: nil,
              new_value: suggestion.value,
              context: Map.get(suggestion, :context),
              timestamp: Map.get(suggestion, :timestamp),
              apply: true,
              has_change: true
            }
          end)

        {:ok, suggestions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Merges AI suggestions with a Salesforce contact record.

  Sets `current_value` from the contact for each suggested field,
  recalculates `has_change`, and removes suggestions where the value
  already matches what is in Salesforce.

  `contact` must be a map with atom keys as returned by `SalesforceApi.get_contact/2`
  (e.g. `%{firstname: "Jane", phone: "555-0000", ...}`).
  """
  def merge_with_contact(suggestions, contact) when is_list(suggestions) do
    Enum.map(suggestions, fn suggestion ->
      current_value = get_contact_field(contact, suggestion.field)

      %{
        suggestion
        | current_value: current_value,
          has_change: current_value != suggestion.new_value,
          apply: true
      }
    end)
    |> Enum.filter(fn s -> s.has_change end)
  end

  @doc """
  Sanitizes an update payload map before it is sent to the Salesforce API.

  Enforces the Salesforce org requirement that `MailingCountry` must be
  present whenever `MailingState` is set (applies when the org has
  "State and Country Picklists" enabled).

  Rules applied, in order:

  1. If `MailingState` is absent — payload is returned unchanged.
  2. If `MailingCountry` is already present — payload is returned unchanged.
  3. If `default_country` is configured under `:social_scribe → :salesforce` —
     `MailingCountry` is injected with that value.
  4. Otherwise — `MailingState` is removed and a warning is logged.
  """
  def build_update_payload(updates) when is_map(updates) do
    if Map.has_key?(updates, "MailingState") and not Map.has_key?(updates, "MailingCountry") do
      default_country =
        :social_scribe
        |> Application.get_env(:salesforce, [])
        |> Keyword.get(:default_country)

      if default_country do
        Map.put(updates, "MailingCountry", default_country)
      else
        Logger.warning("Skipping MailingState update because Salesforce requires MailingCountry")

        Map.delete(updates, "MailingState")
      end
    else
      updates
    end
  end

  @doc """
  Returns the field label map for use in tests or external callers.
  """
  def field_labels, do: @field_labels

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Maps a Salesforce API field name (e.g. "Phone") to the matching atom key
  # in the formatted contact map returned by SalesforceApi (e.g. :phone).
  # Returns nil gracefully when the field is not in the contact map.
  defp get_contact_field(contact, field) when is_map(contact) do
    atom_key = salesforce_field_to_atom(field)
    Map.get(contact, atom_key)
  end

  defp get_contact_field(_, _), do: nil

  # Mapping from Salesforce PascalCase field names to the atom keys used in
  # the formatted contact map produced by SalesforceApi.format_contact/1.
  defp salesforce_field_to_atom("FirstName"), do: :firstname
  defp salesforce_field_to_atom("LastName"), do: :lastname
  defp salesforce_field_to_atom("Email"), do: :email
  defp salesforce_field_to_atom("Phone"), do: :phone
  defp salesforce_field_to_atom("Title"), do: :title
  defp salesforce_field_to_atom("MailingStreet"), do: :mailing_street
  defp salesforce_field_to_atom("MailingCity"), do: :mailing_city
  defp salesforce_field_to_atom("MailingState"), do: :mailing_state
  defp salesforce_field_to_atom("MailingPostalCode"), do: :mailing_postal_code
  defp salesforce_field_to_atom("MailingCountry"), do: :mailing_country
  defp salesforce_field_to_atom(_), do: nil
end
