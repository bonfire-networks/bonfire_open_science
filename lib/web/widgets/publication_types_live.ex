defmodule Bonfire.OpenScience.PublicationTypesLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.Publications

  prop user, :map, required: true
  prop works_by_type, :list, default: []

  def update(assigns, socket) do
    user = assigns[:user]

    case Publications.get_publication_types(user) do
      {:ok, types} ->
        {:ok, assign(socket, works_by_type: types)}

      {:error, reason} ->
        debug(reason, "Could not fetch publication types")
        {:ok, assign(socket, works_by_type: [])}
    end
  end

  def filter_non_zero_counts(items) when is_list(items) do
    Enum.filter(items, fn item -> e(item, "count", 0) > 0 end)
  end

  def filter_non_zero_counts(_), do: []

  def has_publication_types?(works_by_type) do
    filtered = filter_non_zero_counts(works_by_type)
    is_list(filtered) and length(filtered) > 0
  end
end
