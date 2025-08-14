defmodule Bonfire.OpenScience.Crossref do
  alias Bonfire.OpenScience.DOI
  alias Unfurl.Fetcher

  def fetch_crossref(url) do
    with true <- DOI.is_doi?(url),
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
end
