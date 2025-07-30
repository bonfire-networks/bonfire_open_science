defmodule Bonfire.OpenScience.RecentPublicationLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.Publications

  prop user, :map, required: true
  prop recent_publication, :map, default: nil

  def update(assigns, socket) do
    user = assigns[:user]

    case Publications.get_recent_publication(user) do
      {:ok, publication} ->
        {:ok, assign(socket, recent_publication: publication)}

      {:error, reason} ->
        debug(reason, "Could not fetch recent publication")
        {:ok, assign(socket, recent_publication: nil)}
    end
  end

  def format_publication_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        "#{date.year}"

      _ ->
        date_string
    end
  end

  def format_publication_date(_), do: "Unknown"

  def format_citation_count(count) when is_integer(count) and count > 0 do
    cond do
      count >= 1000 -> "#{Float.round(count / 1000, 1)}k"
      true -> "#{count}"
    end
  end

  def format_citation_count(_), do: "0"

  def get_publication_url(publication) do
    # Try DOI first, then best OA location, then primary location
    cond do
      doi = e(publication, "doi", nil) -> doi
      oa_url = e(publication, "best_oa_location", "landing_page_url", nil) -> oa_url
      primary_url = e(publication, "primary_location", "landing_page_url", nil) -> primary_url
      true -> "#"
    end
  end

  def get_source_name(publication) do
    # Try primary location first
    primary_source = e(publication, "primary_location", "source", "display_name", nil)

    # Try best OA location
    oa_source = e(publication, "best_oa_location", "source", "display_name", nil)

    # Try other locations
    other_source =
      e(publication, "locations", [])
      |> Enum.find_value(fn location ->
        e(location, "source", "display_name", nil)
      end)

    # Check if it's a preprint/submitted version
    version = e(publication, "primary_location", "version", nil)
    is_published = e(publication, "primary_location", "is_published", false)

    # Try to extract source info from DOI for known publishers
    doi_source = extract_source_from_doi(e(publication, "doi", ""))

    cond do
      primary_source -> primary_source
      oa_source -> oa_source
      other_source -> other_source
      doi_source -> doi_source
      version == "submittedVersion" -> "Preprint"
      not is_published -> "Unpublished"
      true -> "Unknown Source"
    end
  end

  defp extract_source_from_doi(doi) when is_binary(doi) do
    cond do
      String.contains?(doi, "egusphere") -> "EGU Sphere (Preprint)"
      String.contains?(doi, "arxiv") -> "arXiv"
      String.contains?(doi, "biorxiv") -> "bioRxiv"
      String.contains?(doi, "medrxiv") -> "medRxiv"
      String.contains?(doi, "chemrxiv") -> "ChemRxiv"
      String.contains?(doi, "psyarxiv") -> "PsyArXiv"
      String.contains?(doi, "ssrn") -> "SSRN"
      String.contains?(doi, "zenodo") -> "Zenodo"
      String.contains?(doi, "figshare") -> "Figshare"
      true -> nil
    end
  end

  defp extract_source_from_doi(_), do: nil

  def truncate_title(title, max_length \\ 80) when is_binary(title) do
    if String.length(title) > max_length do
      String.slice(title, 0, max_length) <> "..."
    else
      title
    end
  end

  def truncate_title(_, _), do: "Untitled"
end
