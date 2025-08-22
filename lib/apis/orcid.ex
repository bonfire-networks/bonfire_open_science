defmodule Bonfire.OpenScience.ORCID do
  @moduledoc """
  ORCID utility functions for validation and extraction.
  """

  use Bonfire.Common.Utils
  alias Bonfire.OpenScience
  alias Bonfire.OpenScience.DOI
  alias Bonfire.Common.Config

  # ORCID format: 0000-0000-0000-0000 (4 groups of 4 digits/X separated by hyphens)
  def orcid_format(), do: ~r/^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$/

  @doc """
  Validates an ORCID identifier format.
  Returns {:ok, orcid_id} if valid, {:error, :invalid_orcid_format} otherwise.
  """
  def validate(orcid_id) when is_binary(orcid_id) do
    if Regex.match?(orcid_format(), orcid_id) do
      {:ok, orcid_id}
    else
      {:error, :invalid_orcid_format}
    end
  end

  def validate(_), do: {:error, :invalid_orcid_format}

  defp is_orcid_work_url?(url) when is_binary(url) do
    String.contains?(url, "orcid.org/") and String.contains?(url, "/work/")
  end

  defp is_orcid_work_url?(_), do: false

  @doc """
  Extracts ORCID ID from a path or URL.
  Handles various formats like full URLs or direct IDs.
  """
  def extract_from_path(path) when is_binary(path) do
    cond do
      # Handle full ORCID URLs
      String.contains?(path, "orcid.org/") ->
        path
        |> String.replace(~r{^https?://(sandbox\.)?orcid\.org/}, "")
        |> String.trim("/")
        |> case do
          "" -> nil
          orcid_id -> orcid_id
        end

      # Handle direct ORCID IDs
      Regex.match?(orcid_format(), path) ->
        path

      # Invalid format
      true ->
        nil
    end
  end

  def extract_from_path(_), do: nil

  def user_orcid_id(user) do
    case OpenScience.user_alias_by_type(user, "orcid")
         |> e(:path, nil)
         |> extract_from_path() do
      nil ->
        {:error, :no_orcid}

      orcid_id ->
        {:ok, orcid_id}
        # validate(orcid_id)
    end
  end

  @doc """
  Gets ORCID OAuth access token for a user from existing OAuth flow.
  This uses the same token from OAuth authentication.
  """
  def get_user_orcid_write_token(user) do
    case OpenScience.user_alias_by_type(user, "orcid") do
      nil ->
        {:error, :no_orcid_profile}

      orcid_media ->
        access_token = e(orcid_media, :metadata, "orcid", "access_token", nil)

        if access_token && access_token != "" do
          {:ok, access_token}
        else
          {:error, :no_write_token}
        end
    end
  end

  @doc """
  Checks if user has ORCID OAuth access token available.
  This means they've authenticated with ORCID and can potentially write to their profile.
  """
  def has_orcid_write_access?(user) do
    case get_user_orcid_write_token(user) do
      {:ok, _token} -> true
      _ -> false
    end
  end

  defp fetch_orcid_data(metadata, type \\ "record")

  defp fetch_orcid_data(%{"sub" => orcid_id, "access_token" => access_token}, type) do
    with {:ok, %{body: body}} <-
           HTTP.get("https://pub.orcid.org/v3.0/#{orcid_id}/#{type}", [
             {"Accept", "application/json"},
             {"Authorization", "Bearer #{access_token}"}
           ])
           |> debug(),
         {:ok, body} <- Jason.decode(body) do
      {:ok, body}
    end
  end

  defp fetch_orcid_data(%{metadata: %{} = metadata}, type), do: fetch_orcid_data(metadata, type)
  defp fetch_orcid_data(%{"orcid" => %{} = metadata}, type), do: fetch_orcid_data(metadata, type)

  defp fetch_orcid_data(metadata, types) when is_list(types) do
    Enum.map(types, &fetch_orcid_data(metadata, &1))
  end

  defp fetch_orcid_data(_, _), do: nil

  @doc """
  Fetches metadata for an ORCID work URL like https://orcid.org/0000-0002-5534-712X/work/182038255
  Returns metadata suitable for URL preview with DOI and other academic information
  """
  def fetch_orcid_work_metadata(url) when is_binary(url) do
    with {:ok, orcid_id, work_id} <- parse_orcid_work_url(url),
         {:ok, work_data} <- fetch_orcid_work_via_public_api(orcid_id, work_id) do
      {:ok, transform_orcid_work_to_metadata(work_data)}
    else
      error ->
        error(error, "Failed to fetch ORCID work metadata")
        {:error, :orcid_fetch_failed}
    end
  end

  defp parse_orcid_work_url(url) do
    # Handle URLs with optional extra slashes
    case Regex.run(~r/orcid\.org\/+(\d{4}-\d{4}-\d{4}-\d{3}[0-9X])\/work\/(\d+)/, url) do
      [_, orcid_id, work_id] -> {:ok, orcid_id, work_id}
      _ -> {:error, :invalid_orcid_work_url}
    end
  end

  defp fetch_orcid_work_via_public_api(orcid_id, work_id) do
    # Uses public API endpoint that doesn't require authentication
    url = "https://pub.orcid.org/v3.0/#{orcid_id}/work/#{work_id}"

    with {:ok, %{body: body}} <- HTTP.get(url, [{"Accept", "application/json"}]),
         {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    end
  end

  defp transform_orcid_work_to_metadata(work_data) do
    # Extract DOI and other metadata from ORCID work data
    doi = extract_doi_from_work(work_data)

    %{
      "orcid" => work_data,
      # "title" => e(work_data, "title", "title", "value", nil),
      # "type" => e(work_data, "type", nil),
      # "journal-title" => e(work_data, "journal-title", "value", nil),
      # "publication-date" => e(work_data, "publication-date", nil),
      # "external-ids" => e(work_data, "external-ids", "external-id", nil),
      "doi" => doi,
      "canonical_url" => doi && "https://doi.org/#{doi}"
      # "contributors" => extract_contributors(work_data),
      # "source" => e(work_data, "source", "source-name", "value", nil)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" or v == [] end)
    |> Map.new()
  end

  defp extract_doi_from_work(work_data) do
    work_data
    |> e("external-ids", "external-id", [])
    |> List.wrap()
    |> Enum.find_value(fn ext_id ->
      if e(ext_id, "external-id-type", nil) == "doi" do
        e(ext_id, "external-id-value", nil)
      end
    end)
  end

  # defp extract_contributors(work_data) do
  #   work_data
  #   |> e("contributors", "contributor", [])
  #   |> List.wrap()
  #   |> Enum.map(fn contributor ->
  #     %{
  #       "name" => e(contributor, "credit-name", "value", nil),
  #       "role" => e(contributor, "contributor-attributes", "contributor-role", nil)
  #     }
  #   end)
  #   |> Enum.reject(fn item -> 
  #     is_nil(item["name"]) or item["name"] == ""
  #   end)
  # end

  def fetch_orcid_record(user, orcid_user_media, opts \\ []) do
    with {:ok, %{"person" => _} = fresh_data} <-
           fetch_orcid_data(orcid_user_media, "record") |> debug("reccord"),
         existing_data = e(orcid_user_media, :metadata, "orcid", nil),
         {:ok, orcid_user_media} <-
           Bonfire.Files.Media.update(user, orcid_user_media, %{
             metadata:
               Map.merge(
                 e(orcid_user_media, :metadata, %{}),
                 %{
                   "orcid" =>
                     Map.merge(
                       if(is_map(existing_data), do: existing_data, else: %{}),
                       fresh_data
                     )
                 }
               )
           }) do
      [orcid_user_media]
    else
      e ->
        error(e)
        []
    end
  end

  def fetch_orcid_works(user, orcid_user_media, opts \\ []) do
    with {:ok, %{"group" => works} = _data} <- fetch_orcid_data(orcid_user_media, "works") do
      works
      |> debug("wwworks")
      |> Enum.map(fn %{"work-summary" => summaries} ->
        summaries
        |> Enum.filter(fn summary ->
          # Filter based on configured visibility levels  
          allowed_levels =
            Config.get([:bonfire_open_science, :orcid_work_visibility_levels], ["public"])

          e(summary, "visibility", nil) in allowed_levels
        end)
        |> Enum.map(fn summary ->
          Bonfire.OpenScience.maybe_fetch_and_save_work(
            user,
            e(summary, "url", "value", nil) || "https://orcid.org/#{e(summary, "path", nil)}",
            %{orcid: summary},
            opts
            |> Keyword.put(:date_created, e(summary, "created-date", "value", nil))
          )
        end)
      end)
    else
      e ->
        error(e)
        []
    end
  end

  def fetch_orcid_latest(user, media, opts \\ []) do
    fetch_orcid_record(user, media, opts) ++ fetch_orcid_works(user, media, opts)
  end

  def fetch_orcid_for_all_known_scientists(opts \\ []) do
    with {:ok, medias} <- Bonfire.Files.Media.many(media_type: "orcid") |> debug() do
      Enum.map(medias, fn media ->
        case Bonfire.Social.Graph.Aliases.all_subjects_by_object(media) |> debug() do
          [%{} = user] -> fetch_orcid_latest(user, media, opts)
          other -> warn(media, "Could not find a user linked this ORCID via an Alias")
        end
      end)
    end
  end
end
