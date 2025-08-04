defmodule Bonfire.OpenScience.APIs do
  use Bonfire.Common.Utils

  use Oban.Worker,
    queue: :fetch_open_science,
    max_attempts: 1

  import Untangle
  alias Unfurl.Fetcher
  alias Bonfire.OpenScience
  alias Bonfire.OpenScience.ORCID
  alias Bonfire.OpenScience.DOI

  def maybe_fetch(url, opts \\ []) do
    if is_pub_id_or_uri_match?(url), do: fetch(url, opts)
  end

  def fetch(url, _opts \\ []) do
    wikibase_url =
      "https://en.wikipedia.org/api/rest_v1/data/citation/wikibase/#{URI.encode_www_form(url)}"

    # |> debug()

    # TODO: add a custom user agent 
    with {:ok, body, 200} <- Fetcher.fetch(wikibase_url),
         {:ok, [data | _]} <- Jason.decode(body) do
      with %{"identifiers" => %{"url" => dl_url}} when dl_url != wikibase_url <- data do
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
        warn(e, "Could not find data on wikipedia, trying with crossref...")
        Bonfire.OpenScience.Crossref.fetch_crossref(url)
    end
  end

  def is_pub_id_or_uri_match?(url) do
    OpenScience.pub_id_and_uri_matchers()
    |> Map.values()
    |> Enum.any?(fn
      fun when is_function(fun, 1) ->
        fun.(url)
        |> debug(url)

      scheme ->
        String.match?(url, scheme)
    end)
  end

  # trigger fetching via other modules (see RuntimeConfig)
  def trigger(:add_link, user, media) do
    ORCID.fetch_orcid_latest(user, media)
  end

  @impl Oban.Worker
  def perform(_job) do
    # cron job to periodically query for each user with an orcid and fetch their latest works
    ORCID.fetch_orcid_for_all_known_scientists()
    |> info("ORCID data imported")

    :ok
  end
end
