defmodule Bonfire.OpenScience.Zenodo.MetadataHelpers do
  @moduledoc """
  Shared helper functions for cleaning and processing Zenodo metadata.

  These functions ensure metadata is properly formatted for Zenodo API submission
  by removing empty fields and standardizing data structures.
  """
  use Bonfire.Common.Config
  import Untangle

  @doc """
  Cleans metadata for Zenodo submission by removing empty fields and standardizing formats.
  """
  def clean_metadata_for_zenodo(metadata) when is_map(metadata) do
    metadata
    # to avoid this when editing: A validation error occurred. pids.doi: The prefix '10.5072' is managed by Zenodo. Please supply an external DOI or select 'No' to have a DOI generated for you
    |> Map.drop(["doi", "doi_url"])
    |> clean_subjects_field()
    |> clean_keywords_field()
    |> Map.reject(fn {_key, value} ->
      # Remove nil values and empty strings
      is_nil(value) or value === ""
    end)
  end

  @doc """
  Cleans the subjects field by removing empty subjects and invalid structures.
  """
  def clean_subjects_field(metadata) do
    case Map.get(metadata, "subjects") do
      subjects when is_list(subjects) ->
        cleaned_subjects =
          subjects
          |> Enum.map(&clean_individual_subject/1)
          |> Enum.reject(&is_empty_subject?/1)

        case cleaned_subjects do
          [] -> Map.delete(metadata, "subjects")
          valid_subjects -> Map.put(metadata, "subjects", valid_subjects)
        end

      _ ->
        # Remove the subjects field if it's not a proper list
        Map.delete(metadata, "subjects")
    end
  end

  @doc """
  Cleans individual subject entries by removing empty values.
  """
  def clean_individual_subject(subject) when is_map(subject) do
    subject
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or value == "" or value == []
    end)
    |> Map.new()
  end

  def clean_individual_subject(subject), do: subject

  @doc """
  Checks if a subject is empty and should be removed.
  """
  def is_empty_subject?(subject) when is_map(subject) do
    case subject do
      %{} ->
        true

      %{"subjects" => subjects} when subjects in [nil, "", []] ->
        true

      _ ->
        subject
        |> Map.values()
        |> Enum.all?(fn value ->
          is_nil(value) or value == "" or value == []
        end)
    end
  end

  def is_empty_subject?(_), do: false

  @doc """
  Cleans the keywords field by converting strings to arrays and removing empty entries.
  """
  def clean_keywords_field(metadata) do
    case Map.get(metadata, "keywords") do
      keywords when is_binary(keywords) ->
        keyword_array =
          keywords
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        case keyword_array do
          [] -> Map.delete(metadata, "keywords")
          valid_keywords -> Map.put(metadata, "keywords", valid_keywords)
        end

      keywords when is_list(keywords) ->
        cleaned_keywords =
          keywords
          |> Enum.map(fn
            k when is_binary(k) -> String.trim(k)
            k -> to_string(k)
          end)
          |> Enum.reject(&(&1 == ""))

        case cleaned_keywords do
          [] -> Map.delete(metadata, "keywords")
          valid_keywords -> Map.put(metadata, "keywords", valid_keywords)
        end

      _ ->
        Map.delete(metadata, "keywords")
    end
  end

  # Find the original publisher who has Zenodo credentials
  def find_original_publisher_token(object) do
    # The publisher is typically the creator of the post
    publisher = Bonfire.Social.Objects.object_creator(object)

    case publisher do
      %{} = user ->
        # Verify they have Zenodo credentials
        Bonfire.OpenScience.Zenodo.get_user_zenodo_token(user)

      _ ->
        error(publisher, "Could not find original publisher")
    end
  end

  #     # Ensure DOI fields have the correct full format
  # def ensure_correct_doi_format(metadata, full_doi) when is_binary(full_doi) do
  #   # Extract just the DOI identifier from the full URL (e.g., "10.5072/zenodo.318716")
  #   {doi_identifier, doi_url} =
  #     case full_doi do
  #       "https://doi.org/" <> doi -> {doi, full_doi}
  #       "http://doi.org/" <> doi -> {doi, full_doi}
  #       doi -> {doi, "https://doi.org/" <> doi}
  #     end

  #   debug({doi_identifier, full_doi}, "Setting DOI in metadata")

  #   metadata
  #   |> Map.put("doi", doi_identifier)
  #   |> Map.put("doi_url", doi_url)
  # end

  # def ensure_correct_doi_format(metadata, _), do: metadata

  def prepare_record_json(object) do
    with {:ok, json} <- Bonfire.UI.Me.ExportController.object_json(object) do
      json
      |> stream_into()
    else
      _ ->
        []
    end

    # |> debug("jsssson")
  end

  # Helper to merge two lists of creators, preferring non-empty fields from participants,
  # and preserving any creators that are not current participants.
  def merge_creators_with_participants(zenodo_creators, participants) do
    # Build lookup maps and sets in a single pass
    {orcid_map, id_map, name_map, seen_keys} =
      Enum.reduce(zenodo_creators, {%{}, %{}, %{}, MapSet.new()}, fn c,
                                                                     {orcid_map, id_map, name_map,
                                                                      seen} ->
        orcid_map =
          if c["orcid"] && c["orcid"] != "",
            do: Map.put(orcid_map, c["orcid"], c),
            else: orcid_map

        id_map = if c["id"], do: Map.put(id_map, c["id"], c), else: id_map

        name_map =
          if c["name"] && c["name"] != "", do: Map.put(name_map, c["name"], c), else: name_map

        key =
          cond do
            c["orcid"] && c["orcid"] != "" -> {:orcid, c["orcid"]}
            c["id"] && c["id"] != "" -> {:id, c["id"]}
            c["name"] && c["name"] != "" -> {:name, c["name"]}
            true -> nil
          end

        seen = if key, do: MapSet.put(seen, key), else: seen
        {orcid_map, id_map, name_map, seen}
      end)

    # Merge participants into zenodo_creators, updating or adding as needed
    {merged, updated_keys} =
      Enum.reduce(participants, {zenodo_creators, seen_keys}, fn participant, {acc, seen} ->
        orcid = participant["orcid"]
        id = participant["id"]
        name = participant["name"]

        cond do
          orcid && Map.has_key?(orcid_map, orcid) ->
            existing = orcid_map[orcid]

            updated =
              Map.merge(existing, participant, fn _k, v1, v2 ->
                if v2 in [nil, ""], do: v1, else: v2
              end)

            key = {:orcid, orcid}

            {
              acc
              |> Enum.map(fn
                %{"orcid" => ^orcid} -> updated
                c -> c
              end),
              MapSet.put(seen, key)
            }

          id && Map.has_key?(id_map, id) ->
            existing = id_map[id]

            updated =
              Map.merge(existing, participant, fn _k, v1, v2 ->
                if v2 in [nil, ""], do: v1, else: v2
              end)

            key = {:id, id}

            {
              acc
              |> Enum.map(fn
                %{"id" => ^id} -> updated
                c -> c
              end),
              MapSet.put(seen, key)
            }

          name && Map.has_key?(name_map, name) ->
            existing = name_map[name]

            updated =
              Map.merge(existing, participant, fn _k, v1, v2 ->
                if v2 in [nil, ""], do: v1, else: v2
              end)

            key = {:name, name}

            {
              acc
              |> Enum.map(fn
                %{"name" => ^name} -> updated
                c -> c
              end),
              MapSet.put(seen, key)
            }

          true ->
            key =
              cond do
                orcid && orcid != "" -> {:orcid, orcid}
                id && id != "" -> {:id, id}
                name && name != "" -> {:name, name}
                true -> nil
              end

            {
              acc ++ [participant],
              if(key, do: MapSet.put(seen, key), else: seen)
            }
        end
      end)

    # Deduplicate by seen keys
    merged
    |> Enum.reduce({[], MapSet.new()}, fn c, {acc, seen} ->
      key =
        cond do
          c["orcid"] && c["orcid"] != "" -> {:orcid, c["orcid"]}
          c["id"] && c["id"] != "" -> {:id, c["id"]}
          c["name"] && c["name"] != "" -> {:name, c["name"]}
          true -> nil
        end

      if key && MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[c | acc], if(key, do: MapSet.put(seen, key), else: seen)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def ensure_deposit_id(%{deposit_id: nil, doi: doi} = zenodo_info) when is_binary(doi) do
    case Bonfire.OpenScience.Zenodo.extract_deposit_id_from_doi(doi) do
      nil -> zenodo_info
      deposit_id -> Map.put(zenodo_info, :deposit_id, deposit_id)
    end
  end

  def ensure_deposit_id(zenodo_info), do: zenodo_info

  def validate_update_params(current_user, zenodo_info) do
    cond do
      is_nil(zenodo_info) ->
        {:error, "Missing Zenodo deposit information"}

      is_nil(current_user) ->
        {:error, "Authentication required"}

      true ->
        # Ensure we have deposit_id, extracting from DOI if needed
        fixed_zenodo_info = MetadataHelpers.ensure_deposit_id(zenodo_info)

        if is_nil(fixed_zenodo_info[:deposit_id]) do
          error(
            fixed_zenodo_info,
            "Missing Zenodo deposit ID - cannot determine which deposit to update"
          )
        else
          {:ok, fixed_zenodo_info}
        end
    end
  end

  def extract_creators_from_params(%{"creators" => creators_params})
      when is_map(creators_params) do
    creators_params
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_index, creator} -> creator end)
    |> Enum.reject(fn creator -> Map.get(creator, "_hidden", false) end)
  end

  def extract_creators_from_params(_), do: []

  def validate_metadata(metadata, creators) do
    errors = %{}

    # Validate title
    errors =
      if is_nil(metadata["title"]) or String.trim(metadata["title"]) == "" do
        Map.put(errors, :title, "Title is required")
      else
        if String.length(metadata["title"]) > 500 do
          Map.put(errors, :title, "Title must be less than 500 characters")
        else
          errors
        end
      end

    # Validate description
    errors =
      if is_nil(metadata["description"]) or
           String.length(String.trim(metadata["description"])) < 10 do
        Map.put(errors, :description, "Description must be at least 10 characters")
      else
        errors
      end

    # Validate at least one visible creator with name
    visible_creators = Enum.reject(creators, fn c -> Map.get(c, "_hidden", false) end)

    has_valid_creator =
      Enum.any?(visible_creators, fn c ->
        c["name"] != nil and String.trim(c["name"]) != ""
      end)

    errors =
      if not has_valid_creator do
        Map.put(errors, :creators, "At least one author is required")
      else
        errors
      end

    # Validate ORCID format for any provided ORCIDs
    invalid_orcids =
      visible_creators
      |> Enum.filter(fn c ->
        orcid = String.trim(c["orcid"] || "")
        orcid != "" and not Bonfire.OpenScience.ORCID.valid_orcid_format?(orcid)
      end)
      |> Enum.map(fn c -> c["name"] || "Unknown author" end)

    errors =
      if invalid_orcids != [] do
        Map.put(errors, :creators, "Invalid ORCID format for: #{Enum.join(invalid_orcids, ", ")}")
      else
        errors
      end

    # Validate license if access_right is open
    errors =
      if metadata["access_right"] == "open" do
        if is_nil(metadata["license"]) or metadata["license"] == "" do
          Map.put(errors, :license, "License is required for open access")
        else
          errors
        end
      else
        errors
      end

    errors
  end

  def stream_into(data) do
    data
    |> List.wrap()
    |> Stream.into([])
  end

  def upload_type_options do
    [
      {"Publication", "publication"},
      {"Dataset", "dataset"},
      {"Software", "software"},
      {"Other", "other"}
    ]
  end

  def access_right_options do
    [
      {"Open Access", "open"},
      {"Restricted", "restricted"},
      {"Closed", "closed"}
    ]
  end

  def license_options do
    [
      {"Creative Commons Attribution 4.0", "CC-BY-4.0"},
      {"Creative Commons Attribution Share-Alike 4.0", "CC-BY-SA-4.0"},
      {"Creative Commons Zero (Public Domain)", "CC0-1.0"},
      {"MIT License", "MIT"},
      {"Apache License 2.0", "Apache-2.0"}
    ]
  end

  # Configuration helpers for default values
  def get_default_upload_type do
    Bonfire.Common.Config.get(
      [:bonfire_open_science, :zenodo_defaults, :upload_type],
      "publication"
    )
  end

  def get_default_access_right do
    Bonfire.Common.Config.get([:bonfire_open_science, :zenodo_defaults, :access_right], "open")
  end

  def get_default_license do
    Bonfire.Common.Config.get([:bonfire_open_science, :zenodo_defaults, :license], "CC-BY-4.0")
  end
end
