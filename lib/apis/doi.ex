defmodule Bonfire.OpenScience.DOI do
  @doi_matcher "10.\d{4,9}\/[-._;()\/:A-Z0-9]+$"
  def doi_matcher(), do: ~r/^#{@doi_matcher}/i

  @doc """
  Checks if a string is a DOI identifier.
  """
  def is_doi?("doi:" <> _), do: true
  def is_doi?("https://doi.org/" <> _), do: true
  def is_doi?("http://doi.org/" <> _), do: true

  def is_doi?(url) when is_binary(url) do
    doi_prefixed = ~r/^doi:([^\s]+)/i

    String.match?(url, doi_matcher()) || String.match?(url, doi_prefixed)
  end

  def is_doi?(_), do: false
end
