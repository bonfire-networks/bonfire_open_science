defmodule Bonfire.OpenScience.AuthorTopicsLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.Publications

  prop user, :map, required: true
  prop author_data, :map, default: nil

  def update(assigns, socket) do
    user = assigns[:user]

    case Publications.get_author_info(user) do
      {:ok, data} ->
        {:ok, assign(socket, author_data: data)}

      {:error, reason} ->
        debug(reason, "Could not fetch author topics")
        {:ok, assign(socket, author_data: nil)}
    end
  end

  def has_topics?(author_data) do
    topics = e(author_data, "topics", [])
    is_list(topics) and length(topics) > 0
  end

  def topics_count(author_data) do
    e(author_data, "topics", [])
    |> length()
  end
end
