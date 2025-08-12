defmodule Bonfire.OpenScience do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

  use Bonfire.Common.Config
  alias Bonfire.Common.Utils
  alias Bonfire.OpenScience.ORCID
  use Bonfire.Common.E
  import Untangle

  def pub_id_matchers,
    do: %{
      pmid: ~r/PMID:*[ \t]*[0-9]{1,10}/,
      pmcid: ~r/PMC[0-9]+/,
      # :doi => ~r/10.+\/.+/,
      doi: Bonfire.OpenScience.DOI.doi_matcher(),
      # doi_prefixed: ~r/doi:^#{@doi_matcher}/i
      doi_prefixed: ~r/^doi:([^\s]+)/i
      # doi_prefixed: ~r/^doi: ([^\s]+)/i
      # scopus_eid: ~r/2-s2.0-[0-9]{11}/
    }

  def pub_uri_matchers,
    do: %{
      doi_url: ~r/doi\.org([^\s]+)/i
    }

  def pub_id_and_uri_matchers, do: Map.merge(pub_id_matchers(), pub_uri_matchers())

  def pub_id_matcher(type), do: pub_id_and_uri_matchers()[type]

  def maybe_fetch_and_save_work(user, url, extra_data \\ %{}, opts \\ []) do
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(
      user,
      url,
      opts
      #  to upsert metadata
      |> Keyword.put_new(:update_existing, true)
      # to (re)publish the activity
      # |> Keyword.put_new(:update_existing, :force)
      |> Keyword.merge(
        fetch_fn: fn url, opts -> fetch_url_metadata(url, opts) end,
        id: DatesTimes.generate_ulid_if_past(opts[:date_created]),
        post_create_fn: fn current_user, media, opts ->
          Bonfire.Social.Objects.publish(
            current_user,
            :create,
            media,
            #  TODO: use a more specific boundary
            [boundary: "public"],
            __MODULE__
          )
        end,
        extra: extra_data
      )
    )
  end

  def fetch_url_metadata(url, opts) do
    # Special handling for ORCID work URLs
    if Bonfire.OpenScience.ORCID.is_orcid_work_url?(url) do
      maybe_fetch_orcid_work_metadata(url, opts)

      # Default for other URLs
    else
      Bonfire.OpenScience.APIs.maybe_fetch(url, opts) || Unfurl.unfurl(url, opts)
    end
  end

  @doc """
  Tries to fetch metadata for a given ORCID work URL from both the ORCID API and the original source (eg. DOI), returning the merged result, or at least the available one.
  """
  def maybe_fetch_orcid_work_metadata(url, opts \\ []) do
    with {:ok, %{} = orcid_metadata} <-
           Bonfire.OpenScience.ORCID.fetch_orcid_work_metadata(url) |> debug("from orcid") do
      case e(orcid_metadata, "canonical_url", nil) do
        canonical_url when is_binary(canonical_url) and canonical_url != url ->
          with {:ok, %{} = source_metadata} <-
                 (Bonfire.OpenScience.APIs.maybe_fetch(url, opts) ||
                    Unfurl.unfurl(canonical_url, opts))
                 |> debug("from DOI") do
            {:ok, Map.merge(orcid_metadata, source_metadata)}
          else
            e ->
              warn(e, "Could not get source metadata from original source")
              {:ok, orcid_metadata}
          end

        _ ->
          {:ok, orcid_metadata}
      end
    else
      error ->
        warn(error, "Could not fetch metadata from ORCID API")
        # Fallback to regular web scraping if API fails
        Bonfire.OpenScience.APIs.maybe_fetch(url, opts) || Unfurl.unfurl(url, opts)
    end
  end

  def repo, do: Config.repo()

  def user_alias_by_type(user, type) do
    user_aliases(user)
    |> find_from_aliases(type)
  end

  def user_aliases(user) do
    Utils.maybe_apply(
      Bonfire.Social.Graph.Aliases,
      :list_aliases,
      [user],
      fallback_return: []
    )
    |> e(:edges, [])
  end

  @doc """
  Finds a provider ID from a list of user aliases.
  Returns the first valid one found or nil.
  """
  def find_from_aliases(aliases, type) when is_list(aliases) do
    Enum.find_value(aliases, fn alias ->
      if e(alias, :edge, :object, :media_type, nil) == type do
        e(alias, :edge, :object, nil)
      end
    end)
  end

  def find_from_aliases(_), do: nil

  def is_research?(url, meta) do
    # Check various sources for research indicators
    # Check ORCID metadata
    # Check URL patterns for academic repositories
    # ||
    (e(meta, "wikibase", "itemType", nil) in ["journalArticle"] or
       e(meta, "wikibase", "identifiers", "doi", nil)) ||
      e(meta, "crossref", "DOI", nil) ||
      e(meta, "other", "prism.doi", nil) ||
      is_academic_orcid_type?(e(meta, "orcid", "type", nil)) ||
      has_doi_in_orcid?(meta) ||
      is_academic_repository_url?(url)

    # Check JSON-LD (handle both single object and array)
    # check_json_ld_type(e(meta, "json_ld", nil), ["ScholarlyArticle", "Dataset", "https://schema.org/ScholarlyArticle", "https://schema.org/Dataset"]) ||
  end

  defp is_academic_orcid_type?(type) when is_binary(type) do
    type in [
      "journal-article",
      "report",
      "book-chapter",
      "book",
      "conference-paper",
      "dissertation",
      "preprint",
      "working-paper",
      "thesis",
      "technical-report",
      "research-tool",
      "data-set"
    ]
  end

  defp is_academic_orcid_type?(_), do: false

  defp has_doi_in_orcid?(meta) do
    case e(meta, "orcid", "external-ids", "external-id", nil) do
      external_ids when is_list(external_ids) ->
        Enum.any?(external_ids, fn ext_id ->
          e(ext_id, "external-id-type", nil) == "doi"
        end)

      _ ->
        false
    end
  end

  defp is_academic_repository_url?(url) when is_binary(url) do
    prefixes = [
      "https://doi.org/",
      "https://dx.doi.org/"
    ]

    substrings = [
      "zenodo.org",
      "arxiv.org",
      "pubmed.ncbi.nlm.nih.gov",
      "researchgate.net/publication",
      "academia.edu",
      "ssrn.com",
      "biorxiv.org",
      "medrxiv.org",
      "mdpi.com",
      "nature.com",
      "sciencedirect.com",
      "springer.com",
      "wiley.com",
      "plos.org",
      "frontiersin.org",
      "orcid.org"
    ]

    Enum.any?(prefixes, &String.starts_with?(url, &1)) ||
      Enum.any?(substrings, &String.contains?(url, &1))
  end

  defp is_academic_repository_url?(_), do: false
end
