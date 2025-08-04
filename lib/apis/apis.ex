defmodule Bonfire.OpenScience.APIs do
  use Bonfire.Common.Utils

  use Oban.Worker,
    queue: :fetch_open_science,
    max_attempts: 1

  import Untangle
  alias Unfurl.Fetcher

  @doi_matcher "10.\d{4,9}\/[-._;()\/:A-Z0-9]+$"

  def pub_id_matchers,
    do: %{
      pmid: ~r/PMID:*[ \t]*[0-9]{1,10}/,
      pmcid: ~r/PMC[0-9]+/,
      # :doi => ~r/10.+\/.+/,
      doi: ~r/^#{@doi_matcher}/i,
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

  def maybe_fetch(url) do
    if is_pub_id_or_uri_match?(url), do: fetch(url)
  end

  def fetch(url, _opts \\ []) do
    url =
      "https://en.wikipedia.org/api/rest_v1/data/citation/wikibase/#{URI.encode_www_form(url)}"
      |> debug()

    # TODO: add a custom user agent 
    with {:ok, body, 200} <- Fetcher.fetch(url),
         {:ok, [data | _]} <- Jason.decode(body) do
      with %{"identifiers" => %{"url" => dl_url}} when dl_url != url <- data do
        key = if String.ends_with?(dl_url, ".pdf"), do: :download_url, else: :canonical_url

        {:ok,
         %{wikibase: data}
         |> Map.put(key, dl_url)}
      else
        _ ->
          {:ok, %{wikibase: data}}
      end
    else
      e ->
        warn(e, "Could not find data on wikipedia, try another source...")
        fetch_crossref(url)
    end
  end

  def fetch_crossref(url) do
    with true <- is_doi?(url),
         # TODO: add a custom user agent or optional API key?
         {:ok, body, 200} <-
           Fetcher.fetch("https://api.crossref.org/works/#{URI.encode_www_form(url)}"),
         {:ok, %{"message" => data}} <- Jason.decode(body) do
      with %{"link" => links} when is_list(links) <- data do
        Enum.find_value(links, fn
          %{"content-type" => "application/pdf", "URL" => dl_url} when dl_url != url ->
            {:ok, %{crossref: data, download_url: dl_url}}

          _ ->
            nil
        end)
      end || {:ok, %{crossref: data}}
    end
  end

  # Delegate to ORCID module for DOI checking
  defdelegate is_doi?(url), to: Bonfire.OpenScience.ORCID

  def is_pub_id_or_uri_match?(url) do
    pub_id_and_uri_matchers()
    |> Map.values()
    |> Enum.any?(fn
      fun when is_function(fun, 1) ->
        fun.(url)
        |> debug(url)

      scheme ->
        String.match?(url, scheme)
    end)
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
    # Use public API endpoint that doesn't require authentication
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
      "title" => e(work_data, "title", "title", "value", nil),
      "type" => e(work_data, "type", nil),
      "journal-title" => e(work_data, "journal-title", "value", nil),
      "publication-date" => e(work_data, "publication-date", nil),
      "external-ids" => e(work_data, "external-ids", "external-id", nil),
      "doi" => doi,
      "url" => doi && "https://doi.org/#{doi}",
      "contributors" => extract_contributors(work_data),
      "source" => e(work_data, "source", "source-name", "value", nil)
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

  defp extract_contributors(work_data) do
    work_data
    |> e("contributors", "contributor", [])
    |> List.wrap()
    |> Enum.map(fn contributor ->
      %{
        "name" => e(contributor, "credit-name", "value", nil),
        "role" => e(contributor, "contributor-attributes", "contributor-role", nil)
      }
    end)
    |> Enum.reject(fn item -> 
      is_nil(item["name"]) or item["name"] == ""
    end)
  end

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
        |> Enum.map(fn summary ->
          fetch_and_publish_work(
            user,
            e(summary, "url", "value", nil) || "https://orcid.org/#{e(summary, "path", nil)}",
            opts ++
              [date_created: e(summary, "created-date", "value", nil), extra: %{orcid: summary}]
          )
        end)
      end)
    else
      e ->
        error(e)
        []
    end
  end

  def fetch_and_publish_work(user, url, opts \\ []) do
    Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(
      user,
      url,
      opts
      #  to upsert metadata
      |> Keyword.put_new(:update_existing, true)
      # to (re)publish the activity
      # |> Keyword.put_new(:update_existing, :force)
      |> Keyword.merge(
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
        extra: opts[:extra] || %{}
      )
    )
  end

  def fetch_orcid_latest(user, media, opts \\ []) do
    fetch_orcid_record(user, media, opts) ++ fetch_orcid_works(user, media, opts)
  end

  # trigger fetching via other modules (see RuntimeConfig)
  def trigger(:add_link, user, media) do
    fetch_orcid_latest(user, media)
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

  # Delegate to new ORCID module for backward compatibility
  defdelegate find_orcid_id(aliases), to: Bonfire.OpenScience.ORCID, as: :find_from_aliases

  @impl Oban.Worker
  def perform(_job) do
    # cron job to periodically query for each user with an orcid and fetch their latest works
    fetch_orcid_for_all_known_scientists()
    |> info("ORCID data imported")

    :ok
  end
end
