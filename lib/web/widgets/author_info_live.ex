defmodule Bonfire.OpenScience.AuthorInfoLive do
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
        debug(reason, "Could not fetch author info")
        {:ok, assign(socket, author_data: nil)}
    end
  end

  def format_mean_citedness(nil), do: "N/A"

  def format_mean_citedness(value) when is_number(value) do
    Float.round(value, 2)
  end

  def format_mean_citedness(_), do: "N/A"
end
