defmodule Bonfire.OpenScience.Orcid.PreviewLive do
  use Bonfire.UI.Common.Web, :stateless_component

  prop metadata, :map, required: true

  def total_peer_reviews(metadata) do
    metadata
    # Get all peer-review groups
    |> e("orcid", "activities-summary", "peer-reviews", "group", [])
    |> Enum.reduce(0, fn group, acc ->
      # Sum the lengths of "peer-review-group" lists within each group
      group
      |> e("peer-review-group", [])
      |> Enum.count()
      |> Kernel.+(acc)
    end)
  end

  def total_publications_or_grants(metadata) do
    metadata
    # Get all peer-review groups
    |> e("orcid", "activities-summary", "peer-reviews", "group", [])
    # Count each group as a distinct publication/grant
    |> Enum.count()
  end

  # def print_review_summary(metadata) do
  #   total_reviews = total_peer_reviews(metadata)
  #   total_publications = total_publications_or_grants(metadata)

  #   IO.puts("#{total_reviews} reviews for #{total_publications} publications/grants")
  # end

  def total_works(metadata) do
    metadata
    |> e("orcid", "activities-summary", "works", "group", [])
    |> Enum.count()
  end
end
