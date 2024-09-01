defmodule Bonfire.OpenScience.Orcid.KeywordsLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop metadata, :map, required: true

  defp extract_keywords(metadata) do
    # Safely navigating through nested maps to find keywords
    metadata
    |> e("orcid", "person", "keywords", "keyword", [])
    |> Enum.map(fn
      %{"content" => content} -> content
      _ -> nil
    end)
    |> Enum.filter(&is_binary/1)
  end
end
