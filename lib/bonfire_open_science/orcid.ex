defmodule Bonfire.OpenScience.ORCID do
  @moduledoc """
  ORCID utility functions for validation and extraction.
  """

  use Bonfire.Common.Utils

  # ORCID format: 0000-0000-0000-0000 (4 groups of 4 digits/X separated by hyphens)
  @orcid_format ~r/^\d{4}-\d{4}-\d{4}-\d{3}[\dX]$/

  @doc """
  Validates an ORCID identifier format.
  Returns {:ok, orcid_id} if valid, {:error, :invalid_orcid_format} otherwise.
  """
  def validate(orcid_id) when is_binary(orcid_id) do
    if Regex.match?(@orcid_format, orcid_id) do
      {:ok, orcid_id}
    else
      {:error, :invalid_orcid_format}
    end
  end

  def validate(_), do: {:error, :invalid_orcid_format}

  @doc """
  Extracts ORCID ID from a path or URL.
  Handles various formats like full URLs or direct IDs.
  """
  def extract_from_path(path) when is_binary(path) do
    cond do
      # Handle full ORCID URLs
      String.contains?(path, "orcid.org/") ->
        path
        |> String.replace(~r{^https?://orcid\.org/}, "")
        |> String.trim("/")
        |> case do
          "" -> nil
          orcid_id -> orcid_id
        end

      # Handle direct ORCID IDs
      Regex.match?(@orcid_format, path) ->
        path

      # Invalid format
      true ->
        nil
    end
  end

  def extract_from_path(_), do: nil

  @doc """
  Finds ORCID ID from a list of user aliases.
  Returns the first valid ORCID found or nil.
  """
  def find_from_aliases(aliases) when is_list(aliases) do
    Enum.find_value(aliases, fn alias ->
      if e(alias, :edge, :object, :media_type, "") == "orcid" do
        path = e(alias, :edge, :object, :path, "")
        extract_from_path(path)
      end
    end)
  end

  def find_from_aliases(_), do: nil

  @doc """
  Checks if a string is a DOI identifier.
  """
  def is_doi?("doi:" <> _), do: true
  def is_doi?("https://doi.org/" <> _), do: true
  def is_doi?("http://doi.org/" <> _), do: true

  def is_doi?(url) when is_binary(url) do
    doi_matcher = ~r/^10.\d{4,9}\/[-._;()\/:A-Z0-9]+$/i
    doi_prefixed = ~r/^doi:([^\s]+)/i

    String.match?(url, doi_matcher) || String.match?(url, doi_prefixed)
  end

  def is_doi?(_), do: false
end
