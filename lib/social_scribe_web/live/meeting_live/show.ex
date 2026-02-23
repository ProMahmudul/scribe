defmodule SocialScribeWeb.MeetingLive.Show do
  use SocialScribeWeb, :live_view

  import SocialScribeWeb.PlatformLogo
  import SocialScribeWeb.ClipboardButton
  import SocialScribeWeb.ModalComponents, only: [hubspot_modal: 1, salesforce_modal: 1]

  alias SocialScribe.Meetings
  alias SocialScribe.Automations
  alias SocialScribe.Accounts
  alias SocialScribe.HubspotApiBehaviour, as: HubspotApi
  alias SocialScribe.HubspotSuggestions
  alias SocialScribe.SalesforceApiBehaviour, as: SalesforceApi
  alias SocialScribe.SalesforceSuggestions
  alias SocialScribe.Salesforce.AddressNormalizer

  @impl true
  def mount(%{"id" => meeting_id}, _session, socket) do
    meeting = Meetings.get_meeting_with_details(meeting_id)

    user_has_automations =
      Automations.list_active_user_automations(socket.assigns.current_user.id)
      |> length()
      |> Kernel.>(0)

    automation_results = Automations.list_automation_results_for_meeting(meeting_id)

    if meeting.calendar_event.user_id != socket.assigns.current_user.id do
      socket =
        socket
        |> put_flash(:error, "You do not have permission to view this meeting.")
        |> redirect(to: ~p"/dashboard/meetings")

      {:error, socket}
    else
      hubspot_credential = Accounts.get_user_hubspot_credential(socket.assigns.current_user.id)

      salesforce_credential =
        Accounts.get_user_salesforce_credential(socket.assigns.current_user.id)

      salesforce_default_country =
        :social_scribe
        |> Application.get_env(:salesforce, [])
        |> Keyword.get(:default_country)

      socket =
        socket
        |> assign(:page_title, "Meeting Details: #{meeting.title}")
        |> assign(:meeting, meeting)
        |> assign(:automation_results, automation_results)
        |> assign(:user_has_automations, user_has_automations)
        |> assign(:hubspot_credential, hubspot_credential)
        |> assign(:salesforce_credential, salesforce_credential)
        |> assign(:salesforce_default_country, salesforce_default_country)
        |> assign(
          :follow_up_email_form,
          to_form(%{
            "follow_up_email" => ""
          })
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(%{"automation_result_id" => automation_result_id}, _uri, socket) do
    automation_result = Automations.get_automation_result!(automation_result_id)
    automation = Automations.get_automation!(automation_result.automation_id)

    socket =
      socket
      |> assign(:automation_result, automation_result)
      |> assign(:automation, automation)

    {:noreply, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate-follow-up-email", params, socket) do
    socket =
      socket
      |> assign(:follow_up_email_form, to_form(params))

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # HubSpot message handlers (delegated from HubspotModalComponent)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:hubspot_search, query, credential}, socket) do
    case HubspotApi.search_contacts(credential, query) do
      {:ok, contacts} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          contacts: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to search contacts: #{inspect(reason)}",
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generate_suggestions, contact, meeting, _credential}, socket) do
    case HubspotSuggestions.generate_suggestions_from_meeting(meeting) do
      {:ok, suggestions} ->
        merged = HubspotSuggestions.merge_with_contact(suggestions, contact)

        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          step: :suggestions,
          suggestions: merged,
          loading: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to generate suggestions: #{inspect(reason)}",
          loading: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:apply_hubspot_updates, updates, contact, credential}, socket) do
    case HubspotApi.update_contact(credential, contact.id, updates) do
      {:ok, _updated_contact} ->
        socket =
          socket
          |> put_flash(:info, "Successfully updated #{map_size(updates)} field(s) in HubSpot")
          |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")

        {:noreply, socket}

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.HubspotModalComponent,
          id: "hubspot-modal",
          error: "Failed to update contact: #{inspect(reason)}",
          loading: false
        )

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Salesforce message handlers (delegated from SalesforceModalComponent)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:salesforce_search, query, credential}, socket) do
    case SalesforceApi.search_contacts(credential, query) do
      {:ok, contacts} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          contacts: contacts,
          searching: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: "Failed to search contacts: #{inspect(reason)}",
          searching: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:generate_salesforce_suggestions, contact, meeting, _credential}, socket) do
    case SalesforceSuggestions.generate_suggestions_from_meeting(meeting) do
      {:ok, suggestions} ->
        merged = SalesforceSuggestions.merge_with_contact(suggestions, contact)

        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          step: :suggestions,
          suggestions: merged,
          loading: false
        )

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: "Failed to generate suggestions: #{inspect(reason)}",
          loading: false
        )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:apply_salesforce_updates, updates, contact, credential}, socket) do
    uses_code_fields = SalesforceApi.uses_address_code_fields?(credential)

    case AddressNormalizer.build_contact_update_payload(updates, uses_code_fields) do
      {:ok, payload} ->
        do_salesforce_update(credential, contact, payload, socket)

      {:error, reason, non_address_payload} ->
        # Address values couldn't be mapped to Salesforce codes.
        # Submit the non-address fields (Phone, Email, Title, etc.) so they
        # still update, then surface a friendly error in the modal.
        if map_size(non_address_payload) > 0 do
          SalesforceApi.update_contact(credential, contact.id, non_address_payload)
        end

        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: address_normalize_error(reason),
          loading: false
        )

        {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Salesforce address fields (regular and code variants) that can trigger
  # FIELD_INTEGRITY_EXCEPTION when picklists are enabled.
  @sf_address_fields ~w(MailingState MailingCountry MailingStateCode MailingCountryCode)

  # Submits a pre-normalized payload to Salesforce.  On a 400
  # FIELD_INTEGRITY_EXCEPTION for address fields specifically (e.g. if the
  # normalizer succeeded but Salesforce still rejects the code), retries
  # without those fields so non-address updates still land.
  defp do_salesforce_update(credential, contact, payload, socket) do
    case SalesforceApi.update_contact(credential, contact.id, payload) do
      {:ok, _result} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Successfully updated #{map_size(payload)} field(s) in Salesforce"
          )
          |> push_patch(to: ~p"/dashboard/meetings/#{socket.assigns.meeting}")

        {:noreply, socket}

      {:error, {:api_error, 400, body}} when is_list(body) ->
        if address_integrity_error?(body) do
          # Retry without address/code fields so Phone, Email, Title etc. still land.
          non_address = Map.drop(payload, @sf_address_fields)

          if map_size(non_address) > 0 do
            SalesforceApi.update_contact(credential, contact.id, non_address)
          end

          send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
            id: "salesforce-modal",
            error:
              "Address update failed: Salesforce rejected the country or state value. " <>
                "Ensure the values match your org's picklist options.",
            loading: false
          )

          {:noreply, socket}
        else
          send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
            id: "salesforce-modal",
            error: "Failed to update contact: #{inspect(body)}",
            loading: false
          )

          {:noreply, socket}
        end

      {:error, reason} ->
        send_update(SocialScribeWeb.MeetingLive.SalesforceModalComponent,
          id: "salesforce-modal",
          error: "Failed to update contact: #{inspect(reason)}",
          loading: false
        )

        {:noreply, socket}
    end
  end

  defp address_integrity_error?(body) when is_list(body) do
    Enum.any?(body, fn
      %{"errorCode" => "FIELD_INTEGRITY_EXCEPTION", "fields" => fields}
      when is_list(fields) ->
        Enum.any?(fields, &(&1 in @sf_address_fields))

      _ ->
        false
    end)
  end

  defp address_normalize_error({:unmappable_country, value}) do
    "Could not map country \"#{value}\" to a Salesforce country code. " <>
      "Please use a recognized country name (e.g. \"United States\", \"Canada\")."
  end

  defp address_normalize_error({:unmappable_state, value}) do
    "Could not map state \"#{value}\" to a US state code. " <>
      "Use a full name (e.g. \"Utah\") or standard abbreviation (e.g. \"UT\")."
  end

  defp address_normalize_error({:unsupported_country_for_state, country_code}) do
    "State/province codes for country \"#{country_code}\" are not currently supported. " <>
      "Only US states are mapped."
  end

  defp address_normalize_error(_reason) do
    "Could not process the address fields. Please verify the country and state values."
  end

  defp format_duration(nil), do: "N/A"

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)

    cond do
      minutes > 0 && remaining_seconds > 0 -> "#{minutes} min #{remaining_seconds} sec"
      minutes > 0 -> "#{minutes} min"
      seconds > 0 -> "#{seconds} sec"
      true -> "Less than a second"
    end
  end

  attr :meeting_transcript, :map, required: true

  defp transcript_content(assigns) do
    has_transcript =
      assigns.meeting_transcript &&
        assigns.meeting_transcript.content &&
        Map.get(assigns.meeting_transcript.content, "data") &&
        Enum.any?(Map.get(assigns.meeting_transcript.content, "data"))

    assigns =
      assigns
      |> assign(:has_transcript, has_transcript)

    ~H"""
    <div class="bg-white shadow-xl rounded-lg p-6 md:p-8">
      <h2 class="text-2xl font-semibold mb-4 text-slate-700">
        Meeting Transcript
      </h2>
      <div class="prose prose-sm sm:prose max-w-none h-96 overflow-y-auto pr-2">
        <%= if @has_transcript do %>
          <div :for={segment <- @meeting_transcript.content["data"]} class="mb-3">
            <p>
              <span class="font-semibold text-indigo-600">
                {segment_speaker_label(segment)}:
              </span>
              {Enum.map_join(segment["words"] || [], " ", & &1["text"])}
            </p>
          </div>
        <% else %>
          <p class="text-slate-500">
            Transcript not available for this meeting.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # Extracts a display name for a transcript segment speaker.
  # Prefers participant["name"], then participant["email"], then legacy
  # segment["speaker"], falling back to "Unknown Speaker".
  defp segment_speaker_label(segment) do
    participant = segment["participant"] || %{}
    name = participant["name"]
    email = participant["email"]

    cond do
      is_binary(name) and name != "" -> name
      is_binary(email) and email != "" -> email
      is_binary(segment["speaker"]) and segment["speaker"] != "" -> segment["speaker"]
      true -> "Unknown Speaker"
    end
  end
end
