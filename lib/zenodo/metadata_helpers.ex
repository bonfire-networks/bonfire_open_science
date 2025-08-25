defmodule Bonfire.OpenScience.Zenodo.MetadataHelpers do
  @moduledoc """
  Shared helper functions for cleaning and processing Zenodo metadata.

  These functions ensure metadata is properly formatted for Zenodo API submission
  by removing empty fields and standardizing data structures.
  """

  @doc """
  Cleans metadata for Zenodo submission by removing empty fields and standardizing formats.
  """
  def clean_metadata_for_zenodo(metadata) when is_map(metadata) do
    metadata
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
end
