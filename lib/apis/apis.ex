defmodule Bonfire.OpenScience.APIs do
  use Bonfire.Common.Utils

  use Oban.Worker,
    queue: :fetch_open_science,
    max_attempts: 1

  import Untangle
  alias Unfurl.Fetcher

  @doi_matcher "10.\d{4,9}\/[-._;()\/:A-Z0-9]+$"
  @pub_id_matchers %{
    pmid: ~r/PMID:*[ \t]*[0-9]{1,10}/,
    pmcid: ~r/PMC[0-9]+/,
    # :doi => ~r/10.+\/.+/,
    doi: ~r/^#{@doi_matcher}/i,
    # doi_prefixed: ~r/doi:^#{@doi_matcher}/i
    doi_prefixed: ~r/^doi:([^\s]+)/i
    # scopus_eid: ~r/2-s2.0-[0-9]{11}/
  }
  @pub_uri_matchers %{
    doi_url: ~r/doi\.org([^\s]+)/i
  }
  @pub_id_and_uri_matchers Map.merge(@pub_id_matchers, @pub_uri_matchers)

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

  def is_doi?("doi:" <> _), do: true
  def is_doi?("https://doi.org/" <> _), do: true
  def is_doi?("http://doi.org/" <> _), do: true

  def is_doi?(url),
    do:
      is_binary(url) and
        (String.match?(url, pub_id_matcher(:doi)) ||
           String.match?(url, pub_id_matcher(:doi_prefixed)))

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

  def pub_id_matchers(), do: @pub_id_matchers
  def pub_uri_matchers(), do: @pub_uri_matchers
  def pub_id_and_uri_matchers(), do: @pub_id_and_uri_matchers
  def pub_id_matcher(type), do: pub_id_and_uri_matchers()[type]

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

  def fetch_orcid_record(user, orcid_user_media, opts \\ []) do
    with {:ok, %{"person" => _} = data} <-
           fetch_orcid_data(orcid_user_media, "record") |> debug("reccord"),
         {:ok, orcid_user_media} <-
           Bonfire.Files.Media.update(user, orcid_user_media, %{
             metadata:
               Map.merge(
                 e(orcid_user_media, :metadata, %{}),
                 %{"orcid" => Map.merge(e(orcid_user_media, :metadata, "orcid", %{}), data)}
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
          Bonfire.Files.Acts.URLPreviews.maybe_fetch_and_save(
            user,
            e(summary, "url", "value", nil) || "https://orcid.org/#{e(summary, "path", nil)}",
            opts
            #  to upsert metadata
            |> Keyword.put_new(:update_existing, true)
            # to (re)publish the activity
            # |> Keyword.put_new(:update_existing, :force)
            |> Keyword.merge(
              id:
                DatesTimes.maybe_generate_ulid(
                  # e(summary, "publication-date", nil) ||
                  e(summary, "created-date", "value", nil)
                ),
              post_create_fn: fn current_user, media, opts ->
                Bonfire.Social.Objects.publish(
                  current_user,
                  :create,
                  media,
                  [boundary: "public"],
                  __MODULE__
                )
              end,
              extra: %{orcid: summary}
            )
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

  @impl Oban.Worker
  def perform(_job) do
    # cron job to periodically query for each user with an orcid and fetch their latest works
    fetch_orcid_for_all_known_scientists()
    |> info("ORCID data imported")

    :ok
  end
end
