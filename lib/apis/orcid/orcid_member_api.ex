defmodule Bonfire.OpenScience.ORCID.MemberAPI do
  @moduledoc """
  Simple ORCID Works API client for adding DOIs to ORCID profiles.

  Note: This uses the ORCID Member API which requires write scopes.

  **Important**: The current OAuth flow may only have read scopes (/read-public).
  To add works to ORCID profiles, users need to authenticate with write scopes:
  - /activities/update (to add works/publications)

  If the OAuth scope is insufficient, this will fail gracefully and log the error.

  """

  use Bonfire.Common.Utils
  import Untangle

  alias Bonfire.OpenScience
  alias Bonfire.OpenScience.ORCID
  alias Bonfire.Common.HTTP

  @member_api_url "https://api.orcid.org/v3.0"
  @sandbox_api_url "https://api.sandbox.orcid.org/v3.0"

  @doc """
  Adds a work with DOI to user's ORCID profile.

  ## Parameters
  - user: The user whose ORCID profile to update
  - doi: The DOI (with or without https://doi.org/ prefix)
  - metadata: Full metadata map from Zenodo
  - creators: List of creators/contributors

  ## Returns
  {:ok, put_code} on success, {:error, reason} on failure
  """
  def add_doi_to_orcid(user, doi, metadata, creators \\ []) do
    debug(user, "ORCID publishing for user")

    with %{} = orcid_meta <- ORCID.user_orcid_meta(user),
         {:ok, orcid_id} <- ORCID.orcid_id(orcid_meta),
         {:ok, token} <- ORCID.orcid_write_token(orcid_meta),
         work_json <- build_work_record(doi, metadata, creators) do
      debug(work_json, "ORCID work JSON being sent")

      case post_work_to_orcid(orcid_id, token, work_json) do
        {:ok, response} ->
          put_code = e(response, "put-code", nil)
          info("Successfully added work to ORCID profile #{orcid_id}, put-code: #{put_code}")
          {:ok, put_code}

        e ->
          error(e, "Failed to add work to ORCID")
      end
    end
  end

  @doc """
  Builds comprehensive ORCID work JSON with rich metadata.
  """
  def build_work_record(doi, metadata, creators \\ []) do
    title = e(metadata, "title", "Untitled Work")
    work_type = OpenScience.map_zenodo_type_to_orcid(e(metadata, "upload_type", "other"))
    # Clean DOI (remove https://doi.org/ if present)
    clean_doi =
      doi
      |> String.replace(~r{^https?://doi\.org/}, "")
      |> String.trim()

    # Parse publication date from metadata
    pub_date = parse_publication_date(e(metadata, "publication_date", nil))

    # Build base work record
    work_record = %{
      "title" => %{
        "title" => %{
          "value" => title
        }
      },
      "type" => work_type,
      "external-ids" => %{
        "external-id" => [
          %{
            "external-id-type" => "doi",
            "external-id-value" => clean_doi,
            "external-id-relationship" => "self"
          }
        ]
      },
      "url" => %{
        "value" => "https://doi.org/#{clean_doi}"
      }
    }

    # Add optional fields when available
    work_record
    |> add_publication_date(pub_date)
    |> add_short_description(metadata)
    |> add_contributors(creators)
    |> add_language_code(metadata)
    |> add_license_info(metadata)
  end

  @doc """
  Posts work to ORCID API.
  """
  def post_work_to_orcid(orcid_id, access_token, work_json) do
    api_url = get_api_url()
    url = "#{api_url}/#{orcid_id}/work"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/vnd.orcid+json"},
      {"Accept", "application/vnd.orcid+json"}
    ]

    debug({url, work_json, headers}, "ORCID API request details")

    with {:ok, encoded_json} <- Jason.encode(work_json),
         {:ok, %{status: 201, body: body}} <- HTTP.post(url, encoded_json, headers) do
      case Jason.decode(body) do
        {:ok, response} ->
          debug(response, "ORCID work created successfully")
          {:ok, response}

        {:error, _} ->
          {:ok, %{"put-code" => "unknown"}}
      end
    else
      {:error, %Jason.EncodeError{} = e} ->
        error(e, l("Failed to encode ORCID work record."))

      {:ok, %{status: 409}} ->
        error(l("Work already exists in ORCID profile."))

      {:ok, %{status: status, body: body}} ->
        error(body, l("ORCID API error %{code}.", code: status))

      {:error, reason} ->
        error(reason, "ORCID API request failed")
    end
  end

  @doc """
  Simple function to add a published DOI to ORCID with rich metadata.
  This is the main function that gets called after Zenodo publishing.
  """
  def maybe_add_to_orcid(user, doi, metadata, creators \\ []) when is_map(metadata) do
    debug({doi, metadata, creators}, "ORCID publishing attempt with data")

    case add_doi_to_orcid(user, doi, metadata, creators) do
      {:ok, put_code} ->
        info("Added DOI #{doi} to ORCID profile, put-code: #{put_code}")
        {:ok, put_code}

      {:error, e} ->
        {:error, e}

      e ->
        error(e, "Failed to add to ORCID.")
    end
  end

  def maybe_add_to_orcid(_, _, _, _), do: :skipped

  # Helper functions for building work record fields

  defp parse_publication_date(nil), do: {to_string(DateTime.utc_now().year), nil, nil}

  defp parse_publication_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        {to_string(date.year),
         if(date.month, do: String.pad_leading(to_string(date.month), 2, "0")),
         if(date.day, do: String.pad_leading(to_string(date.day), 2, "0"))}

      _ ->
        {to_string(DateTime.utc_now().year), nil, nil}
    end
  end

  defp parse_publication_date(_), do: {to_string(DateTime.utc_now().year), nil, nil}

  defp add_publication_date(work_record, {year, month, day}) do
    pub_date = %{"year" => %{"value" => year}}
    pub_date = if month, do: Map.put(pub_date, "month", %{"value" => month}), else: pub_date
    pub_date = if day, do: Map.put(pub_date, "day", %{"value" => day}), else: pub_date
    Map.put(work_record, "publication-date", pub_date)
  end

  defp add_short_description(work_record, metadata) do
    description = e(metadata, "description", nil)

    if description && String.length(String.trim(description)) > 0 do
      # Truncate to reasonable length for ORCID (max ~5000 chars)
      clean_desc =
        description
        # Remove HTML tags
        |> String.replace(~r/<[^>]*>/, " ")
        # Normalize whitespace
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 4500)

      if String.length(clean_desc) > 10 do
        Map.put(work_record, "short-description", clean_desc)
      else
        work_record
      end
    else
      work_record
    end
  end

  defp add_contributors(work_record, creators) when is_list(creators) and creators != [] do
    contributors =
      creators
      |> Enum.with_index()
      |> Enum.map(fn {creator, index} ->
        contributor = %{
          "contributor-attributes" => %{
            "contributor-sequence" => if(index == 0, do: "first", else: "additional"),
            "contributor-role" => "author"
          }
        }

        # Add credit name if available
        contributor =
          case e(creator, "name", nil) do
            name when is_binary(name) and name != "" ->
              Map.put(contributor, "credit-name", %{"value" => name})

            _ ->
              contributor
          end

        # Add ORCID if available and valid
        case e(creator, "orcid", nil) do
          orcid when is_binary(orcid) and orcid != "" ->
            if Regex.match?(~r/^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$/, orcid) do
              Map.put(contributor, "contributor-orcid", %{
                "uri" => "https://orcid.org/#{orcid}",
                "path" => orcid,
                "host" => "orcid.org"
              })
            else
              contributor
            end

          _ ->
            contributor
        end
      end)
      |> Enum.reject(&is_nil/1)

    if contributors != [] do
      Map.put(work_record, "contributors", %{"contributor" => contributors})
    else
      work_record
    end
  end

  defp add_contributors(work_record, _), do: work_record

  defp add_language_code(work_record, _metadata) do
    # Default to English, could be enhanced to detect from content
    Map.put(work_record, "language-code", "en")
  end

  defp add_license_info(work_record, metadata) do
    license = e(metadata, "license", nil)

    if license && license != "" do
      # Add license info as part of short description or URL
      current_desc = e(work_record, "short-description", "")
      license_text = "\n\nLicense: #{license}"

      if String.length(current_desc <> license_text) < 4500 do
        Map.put(work_record, "short-description", current_desc <> license_text)
      else
        work_record
      end
    else
      work_record
    end
  end

  # Private helpers

  defp get_api_url do
    # Use sandbox if explicitly configured or in dev environment
    cond do
      System.get_env("ORCID_ENV") == "sandbox" ->
        @sandbox_api_url

      # Application.get_env(:bonfire, :env) == :dev ->
      #   @sandbox_api_url
      true ->
        @member_api_url
    end
  end
end
