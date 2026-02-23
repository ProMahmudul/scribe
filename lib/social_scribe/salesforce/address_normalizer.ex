defmodule SocialScribe.Salesforce.AddressNormalizer do
  @moduledoc """
  Normalizes and maps Salesforce contact address fields before a PATCH update.

  ## Why this exists

  When a Salesforce org has **State and Country/Territory Picklists** enabled,
  the standard `MailingState` and `MailingCountry` fields become read-only and
  the API requires `MailingStateCode` (ISO 3166-2 subdivision code) and
  `MailingCountryCode` (ISO 3166-1 alpha-2 code) instead.  Sending the
  human-readable names produces `FIELD_INTEGRITY_EXCEPTION`.

  This module handles both cases transparently:
  - `uses_code_fields: true`  → maps names/aliases to ISO codes, emits
    `MailingCountryCode` / `MailingStateCode` (never state without country).
  - `uses_code_fields: false` → passes values through unchanged, with the
    existing rule that `MailingCountry` must accompany `MailingState`
    (injecting the configured `default_country` or dropping the state field
    and logging a warning).

  ## Public API

      build_contact_update_payload(updates, uses_code_fields)
      # {:ok, payload_map}
      # {:error, reason, non_address_payload}

  The `{:error, reason, non_address_payload}` tuple is returned when an
  address value cannot be mapped to a code.  Callers should submit
  `non_address_payload` to update non-address fields (Phone, Email, …) and
  surface a friendly message to the user for the address portion.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Country → ISO 3166-1 alpha-2 code
  # Keys are UPPERCASED for case-insensitive lookups.
  # ---------------------------------------------------------------------------
  @country_to_code %{
    # United States
    "UNITED STATES" => "US",
    "UNITED STATES OF AMERICA" => "US",
    "USA" => "US",
    "US" => "US",
    "U.S." => "US",
    "U.S.A." => "US",
    "AMERICA" => "US",
    # United Kingdom
    "UNITED KINGDOM" => "GB",
    "UK" => "GB",
    "U.K." => "GB",
    "GREAT BRITAIN" => "GB",
    "BRITAIN" => "GB",
    "ENGLAND" => "GB",
    # Common ISO codes as self-mappings
    "GB" => "GB",
    "CA" => "CA",
    "AU" => "AU",
    "DE" => "DE",
    "FR" => "FR",
    "IN" => "IN",
    "JP" => "JP",
    "CN" => "CN",
    "BR" => "BR",
    "MX" => "MX",
    "NL" => "NL",
    "SE" => "SE",
    "NO" => "NO",
    "DK" => "DK",
    "FI" => "FI",
    "NZ" => "NZ",
    "ZA" => "ZA",
    "SG" => "SG",
    "IE" => "IE",
    "CH" => "CH",
    "AT" => "AT",
    "BE" => "BE",
    "PT" => "PT",
    "PL" => "PL",
    "ES" => "ES",
    "IT" => "IT",
    "RU" => "RU",
    # Full names for common countries
    "CANADA" => "CA",
    "AUSTRALIA" => "AU",
    "GERMANY" => "DE",
    "FRANCE" => "FR",
    "INDIA" => "IN",
    "JAPAN" => "JP",
    "CHINA" => "CN",
    "BRAZIL" => "BR",
    "MEXICO" => "MX",
    "NETHERLANDS" => "NL",
    "SWEDEN" => "SE",
    "NORWAY" => "NO",
    "DENMARK" => "DK",
    "FINLAND" => "FI",
    "NEW ZEALAND" => "NZ",
    "SOUTH AFRICA" => "ZA",
    "SINGAPORE" => "SG",
    "IRELAND" => "IE",
    "SWITZERLAND" => "CH",
    "AUSTRIA" => "AT",
    "BELGIUM" => "BE",
    "PORTUGAL" => "PT",
    "POLAND" => "PL",
    "SPAIN" => "ES",
    "ITALY" => "IT",
    "RUSSIA" => "RU"
  }

  # ---------------------------------------------------------------------------
  # US state / territory → 2-letter abbreviation
  # Keys are LOWERCASED for case-insensitive lookups.
  # ---------------------------------------------------------------------------
  @us_state_to_code %{
    # Full names
    "alabama" => "AL",
    "alaska" => "AK",
    "arizona" => "AZ",
    "arkansas" => "AR",
    "california" => "CA",
    "colorado" => "CO",
    "connecticut" => "CT",
    "delaware" => "DE",
    "florida" => "FL",
    "georgia" => "GA",
    "hawaii" => "HI",
    "idaho" => "ID",
    "illinois" => "IL",
    "indiana" => "IN",
    "iowa" => "IA",
    "kansas" => "KS",
    "kentucky" => "KY",
    "louisiana" => "LA",
    "maine" => "ME",
    "maryland" => "MD",
    "massachusetts" => "MA",
    "michigan" => "MI",
    "minnesota" => "MN",
    "mississippi" => "MS",
    "missouri" => "MO",
    "montana" => "MT",
    "nebraska" => "NE",
    "nevada" => "NV",
    "new hampshire" => "NH",
    "new jersey" => "NJ",
    "new mexico" => "NM",
    "new york" => "NY",
    "north carolina" => "NC",
    "north dakota" => "ND",
    "ohio" => "OH",
    "oklahoma" => "OK",
    "oregon" => "OR",
    "pennsylvania" => "PA",
    "rhode island" => "RI",
    "south carolina" => "SC",
    "south dakota" => "SD",
    "tennessee" => "TN",
    "texas" => "TX",
    "utah" => "UT",
    "vermont" => "VT",
    "virginia" => "VA",
    "washington" => "WA",
    "west virginia" => "WV",
    "wisconsin" => "WI",
    "wyoming" => "WY",
    # DC and territories
    "district of columbia" => "DC",
    "washington dc" => "DC",
    "washington d.c." => "DC",
    "puerto rico" => "PR",
    "guam" => "GU",
    "us virgin islands" => "VI",
    "u.s. virgin islands" => "VI",
    "american samoa" => "AS",
    "northern mariana islands" => "MP",
    # Two-letter abbreviations (already canonical)
    "al" => "AL",
    "ak" => "AK",
    "az" => "AZ",
    "ar" => "AR",
    "ca" => "CA",
    "co" => "CO",
    "ct" => "CT",
    "de" => "DE",
    "fl" => "FL",
    "ga" => "GA",
    "hi" => "HI",
    "id" => "ID",
    "il" => "IL",
    "in" => "IN",
    "ia" => "IA",
    "ks" => "KS",
    "ky" => "KY",
    "la" => "LA",
    "me" => "ME",
    "md" => "MD",
    "ma" => "MA",
    "mi" => "MI",
    "mn" => "MN",
    "ms" => "MS",
    "mo" => "MO",
    "mt" => "MT",
    "ne" => "NE",
    "nv" => "NV",
    "nh" => "NH",
    "nj" => "NJ",
    "nm" => "NM",
    "ny" => "NY",
    "nc" => "NC",
    "nd" => "ND",
    "oh" => "OH",
    "ok" => "OK",
    "or" => "OR",
    "pa" => "PA",
    "ri" => "RI",
    "sc" => "SC",
    "sd" => "SD",
    "tn" => "TN",
    "tx" => "TX",
    "ut" => "UT",
    "vt" => "VT",
    "va" => "VA",
    "wa" => "WA",
    "wv" => "WV",
    "wi" => "WI",
    "wy" => "WY",
    "dc" => "DC",
    "pr" => "PR",
    "gu" => "GU",
    "vi" => "VI",
    "as" => "AS",
    "mp" => "MP"
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds a sanitized Salesforce PATCH payload from `updates`.

  Address fields (`MailingState`, `MailingCountry`) are handled based on
  whether the org supports code fields:

  - `uses_code_fields: true`  — normalized to `MailingStateCode` /
    `MailingCountryCode`.  `MailingState` / `MailingCountry` are excluded.
    `MailingStateCode` is never sent without `MailingCountryCode`.
  - `uses_code_fields: false` — passed through as-is; if `MailingState` is
    present without `MailingCountry`, the configured `default_country` is
    injected, or `MailingState` is dropped with a warning if unconfigured.

  ## Return values

  - `{:ok, payload}` — all fields normalized; submit `payload` directly.
  - `{:error, reason, non_address_payload}` — an address value could not be
    mapped to a code.  `non_address_payload` contains the non-address fields
    and should be submitted to ensure Phone / Email / Title etc. still update.
    `reason` is one of:
    - `{:unmappable_country, value}`
    - `{:unmappable_state, value}`
    - `{:unsupported_country_for_state, country_code}`
  """
  @spec build_contact_update_payload(map(), boolean()) ::
          {:ok, map()} | {:error, term(), map()}
  def build_contact_update_payload(updates, uses_code_fields) when is_map(updates) do
    {picklist, rest} = Map.split(updates, ["MailingState", "MailingCountry"])

    if map_size(picklist) == 0 do
      {:ok, rest}
    else
      case normalize_address(picklist, uses_code_fields) do
        {:ok, address_payload} ->
          {:ok, Map.merge(rest, address_payload)}

        {:error, reason} ->
          {:error, reason, rest}
      end
    end
  end

  @doc """
  Normalizes a country name or alias to an ISO 3166-1 alpha-2 code.

  Returns `{:ok, "US"}` for "United States", "USA", "US", "U.S.A.", etc.
  Returns `{:error, {:unmappable_country, value}}` for unknown inputs.
  Returns `{:ok, nil}` when `value` is `nil` (field not in update).
  """
  @spec normalize_country_code(String.t() | nil) :: {:ok, String.t() | nil} | {:error, term()}
  def normalize_country_code(nil), do: {:ok, nil}

  def normalize_country_code(value) when is_binary(value) do
    key = value |> String.trim() |> String.upcase()

    case Map.get(@country_to_code, key) do
      nil -> {:error, {:unmappable_country, value}}
      code -> {:ok, code}
    end
  end

  @doc """
  Normalizes a US state name or abbreviation to the standard 2-letter code.

  Only US states are supported (`country_code` must be `"US"`).
  Returns `{:error, {:unsupported_country_for_state, country_code}}` for
  non-US countries.
  Returns `{:ok, nil}` when `value` is `nil`.
  """
  @spec normalize_state_code(String.t() | nil, String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def normalize_state_code(nil, _country_code), do: {:ok, nil}

  def normalize_state_code(value, "US") when is_binary(value) do
    key = value |> String.trim() |> String.downcase()

    case Map.get(@us_state_to_code, key) do
      nil -> {:error, {:unmappable_state, value}}
      code -> {:ok, code}
    end
  end

  def normalize_state_code(_value, country_code) do
    {:error, {:unsupported_country_for_state, country_code}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Code-field mode: map MailingCountry → MailingCountryCode and
  # MailingState → MailingStateCode.  Never send state without country.
  defp normalize_address(picklist, true) do
    country_value = Map.get(picklist, "MailingCountry")
    state_value = Map.get(picklist, "MailingState")

    with {:ok, country_code} <- normalize_country_code(country_value) do
      # If only state is being updated (no country in payload), default to US
      # so we can look up the state code and still satisfy the
      # "MailingStateCode requires MailingCountryCode" constraint.
      effective_country = country_code || "US"

      with {:ok, state_code} <- normalize_state_code(state_value, effective_country) do
        payload =
          %{}
          |> maybe_put("MailingCountryCode", country_code)
          |> maybe_put("MailingStateCode", state_code)

        # Ensure MailingCountryCode is always present when MailingStateCode is
        payload =
          if state_code && !country_code do
            Map.put(payload, "MailingCountryCode", effective_country)
          else
            payload
          end

        {:ok, payload}
      end
    end
  end

  # Non-code mode: pass MailingState/MailingCountry through unchanged,
  # applying the existing rule that state requires country.
  defp normalize_address(picklist, false) do
    updated =
      if Map.has_key?(picklist, "MailingState") and not Map.has_key?(picklist, "MailingCountry") do
        default_country =
          :social_scribe
          |> Application.get_env(:salesforce, [])
          |> Keyword.get(:default_country)

        if default_country do
          Map.put(picklist, "MailingCountry", default_country)
        else
          Logger.warning(
            "Skipping MailingState update: Salesforce requires MailingCountry " <>
              "(set SALESFORCE_DEFAULT_COUNTRY to enable automatic injection)"
          )

          Map.delete(picklist, "MailingState")
        end
      else
        picklist
      end

    {:ok, updated}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
