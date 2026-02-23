defmodule SocialScribe.Salesforce.AddressNormalizerTest do
  use SocialScribe.DataCase, async: true

  alias SocialScribe.Salesforce.AddressNormalizer

  # ---------------------------------------------------------------------------
  # normalize_country_code/1
  # ---------------------------------------------------------------------------

  describe "normalize_country_code/1" do
    test "maps common US aliases to 'US'" do
      for input <- [
            "USA",
            "US",
            "U.S.",
            "U.S.A.",
            "America",
            "United States",
            "United States of America"
          ] do
        assert {:ok, "US"} = AddressNormalizer.normalize_country_code(input)
      end
    end

    test "is case-insensitive" do
      assert {:ok, "US"} = AddressNormalizer.normalize_country_code("usa")
      assert {:ok, "US"} = AddressNormalizer.normalize_country_code("Usa")
      assert {:ok, "US"} = AddressNormalizer.normalize_country_code("UNITED STATES")
      assert {:ok, "GB"} = AddressNormalizer.normalize_country_code("united kingdom")
    end

    test "maps UK aliases to 'GB'" do
      for input <- ["United Kingdom", "UK", "U.K.", "Great Britain", "England"] do
        assert {:ok, "GB"} = AddressNormalizer.normalize_country_code(input)
      end
    end

    test "accepts valid ISO 3166-1 alpha-2 codes as pass-throughs" do
      assert {:ok, "CA"} = AddressNormalizer.normalize_country_code("CA")
      assert {:ok, "AU"} = AddressNormalizer.normalize_country_code("AU")
      assert {:ok, "DE"} = AddressNormalizer.normalize_country_code("DE")
    end

    test "maps full country names for common countries" do
      assert {:ok, "CA"} = AddressNormalizer.normalize_country_code("Canada")
      assert {:ok, "AU"} = AddressNormalizer.normalize_country_code("Australia")
      assert {:ok, "DE"} = AddressNormalizer.normalize_country_code("Germany")
      assert {:ok, "FR"} = AddressNormalizer.normalize_country_code("France")
    end

    test "returns error for unknown country" do
      assert {:error, {:unmappable_country, "Atlantis"}} =
               AddressNormalizer.normalize_country_code("Atlantis")
    end

    test "returns {:ok, nil} for nil input" do
      assert {:ok, nil} = AddressNormalizer.normalize_country_code(nil)
    end

    test "trims whitespace before lookup" do
      assert {:ok, "US"} = AddressNormalizer.normalize_country_code("  USA  ")
    end
  end

  # ---------------------------------------------------------------------------
  # normalize_state_code/2
  # ---------------------------------------------------------------------------

  describe "normalize_state_code/2" do
    test "maps US state full names to codes" do
      assert {:ok, "UT"} = AddressNormalizer.normalize_state_code("Utah", "US")
      assert {:ok, "CA"} = AddressNormalizer.normalize_state_code("California", "US")
      assert {:ok, "NY"} = AddressNormalizer.normalize_state_code("New York", "US")
      assert {:ok, "TX"} = AddressNormalizer.normalize_state_code("Texas", "US")
    end

    test "maps US state abbreviations (already canonical)" do
      assert {:ok, "UT"} = AddressNormalizer.normalize_state_code("UT", "US")
      assert {:ok, "CA"} = AddressNormalizer.normalize_state_code("CA", "US")
      assert {:ok, "NY"} = AddressNormalizer.normalize_state_code("NY", "US")
    end

    test "is case-insensitive" do
      assert {:ok, "UT"} = AddressNormalizer.normalize_state_code("utah", "US")
      assert {:ok, "CA"} = AddressNormalizer.normalize_state_code("CALIFORNIA", "US")
      assert {:ok, "WA"} = AddressNormalizer.normalize_state_code("wa", "US")
    end

    test "maps DC and territories" do
      assert {:ok, "DC"} = AddressNormalizer.normalize_state_code("District of Columbia", "US")
      assert {:ok, "PR"} = AddressNormalizer.normalize_state_code("Puerto Rico", "US")
      assert {:ok, "GU"} = AddressNormalizer.normalize_state_code("Guam", "US")
    end

    test "returns error for unknown US state" do
      assert {:error, {:unmappable_state, "Neverland"}} =
               AddressNormalizer.normalize_state_code("Neverland", "US")
    end

    test "returns error for non-US country" do
      assert {:error, {:unsupported_country_for_state, "CA"}} =
               AddressNormalizer.normalize_state_code("Ontario", "CA")
    end

    test "returns {:ok, nil} for nil state" do
      assert {:ok, nil} = AddressNormalizer.normalize_state_code(nil, "US")
    end
  end

  # ---------------------------------------------------------------------------
  # build_contact_update_payload/2 — code-field mode (uses_code_fields: true)
  # ---------------------------------------------------------------------------

  describe "build_contact_update_payload/2 with uses_code_fields: true" do
    test "maps MailingCountry + MailingState to code fields" do
      updates = %{"MailingCountry" => "USA", "MailingState" => "Utah", "Phone" => "555-0001"}

      assert {:ok, payload} =
               AddressNormalizer.build_contact_update_payload(updates, true)

      assert payload["MailingCountryCode"] == "US"
      assert payload["MailingStateCode"] == "UT"
      assert payload["Phone"] == "555-0001"
      refute Map.has_key?(payload, "MailingCountry")
      refute Map.has_key?(payload, "MailingState")
    end

    test "handles 'United States' and full state name" do
      updates = %{"MailingCountry" => "United States", "MailingState" => "California"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, true)
      assert payload["MailingCountryCode"] == "US"
      assert payload["MailingStateCode"] == "CA"
    end

    test "injects MailingCountryCode = 'US' when only MailingState is provided" do
      updates = %{"MailingState" => "Utah", "Phone" => "555-0002"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, true)
      assert payload["MailingCountryCode"] == "US"
      assert payload["MailingStateCode"] == "UT"
      assert payload["Phone"] == "555-0002"
    end

    test "never sends MailingStateCode without MailingCountryCode" do
      updates = %{"MailingState" => "Texas"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, true)
      assert Map.has_key?(payload, "MailingCountryCode")
      assert Map.has_key?(payload, "MailingStateCode")
    end

    test "maps only MailingCountry when no state is provided" do
      updates = %{"MailingCountry" => "Canada"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, true)
      assert payload["MailingCountryCode"] == "CA"
      refute Map.has_key?(payload, "MailingStateCode")
    end

    test "passes non-address fields through unchanged" do
      updates = %{"Phone" => "555-9999", "Email" => "x@example.com", "Title" => "Engineer"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, true)
      assert payload == updates
    end

    test "returns error with non-address payload when country cannot be mapped" do
      updates = %{"MailingCountry" => "Atlantis", "MailingState" => "Narnia", "Phone" => "555"}

      assert {:error, {:unmappable_country, "Atlantis"}, rest} =
               AddressNormalizer.build_contact_update_payload(updates, true)

      assert rest == %{"Phone" => "555"}
      refute Map.has_key?(rest, "MailingCountry")
      refute Map.has_key?(rest, "MailingState")
    end

    test "returns error with non-address payload when state cannot be mapped" do
      updates = %{
        "MailingCountry" => "US",
        "MailingState" => "Neverland",
        "Phone" => "555-0003"
      }

      assert {:error, {:unmappable_state, "Neverland"}, rest} =
               AddressNormalizer.build_contact_update_payload(updates, true)

      assert rest == %{"Phone" => "555-0003"}
    end

    test "returns error when state provided for non-US country" do
      updates = %{"MailingCountry" => "Canada", "MailingState" => "Ontario"}

      assert {:error, {:unsupported_country_for_state, "CA"}, _rest} =
               AddressNormalizer.build_contact_update_payload(updates, true)
    end
  end

  # ---------------------------------------------------------------------------
  # build_contact_update_payload/2 — pass-through mode (uses_code_fields: false)
  # ---------------------------------------------------------------------------

  describe "build_contact_update_payload/2 with uses_code_fields: false" do
    setup do
      original = Application.get_env(:social_scribe, :salesforce)

      on_exit(fn ->
        if original,
          do: Application.put_env(:social_scribe, :salesforce, original),
          else: Application.delete_env(:social_scribe, :salesforce)
      end)

      :ok
    end

    test "passes MailingState and MailingCountry through unchanged" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")
      updates = %{"MailingCountry" => "United States", "MailingState" => "Utah"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, false)
      assert payload["MailingCountry"] == "United States"
      assert payload["MailingState"] == "Utah"
    end

    test "injects default_country when MailingState present without MailingCountry" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")
      updates = %{"MailingState" => "Utah"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, false)
      assert payload["MailingCountry"] == "United States"
      assert payload["MailingState"] == "Utah"
    end

    test "drops MailingState when no default_country is configured" do
      Application.put_env(:social_scribe, :salesforce, default_country: nil)
      updates = %{"MailingState" => "Utah", "Phone" => "555-0001"}

      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          assert {:ok, payload} =
                   AddressNormalizer.build_contact_update_payload(updates, false)

          refute Map.has_key?(payload, "MailingState")
          assert payload["Phone"] == "555-0001"
        end)

      assert log =~ "Skipping MailingState update"
    end

    test "does not emit code fields in pass-through mode" do
      Application.put_env(:social_scribe, :salesforce, default_country: "United States")
      updates = %{"MailingCountry" => "USA", "MailingState" => "Utah"}

      assert {:ok, payload} = AddressNormalizer.build_contact_update_payload(updates, false)
      refute Map.has_key?(payload, "MailingCountryCode")
      refute Map.has_key?(payload, "MailingStateCode")
    end
  end
end
