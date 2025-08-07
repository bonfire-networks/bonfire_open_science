defmodule Bonfire.OpenScience.OpenAlex.PreviewLive do
  use Bonfire.UI.Common.Web, :stateful_component

  prop open_alex_data, :map, default: nil

  def update(assigns, socket) do
    {:ok, socket}
  end

  def handle_event("show_all_topics", _params, socket) do
    {:noreply, socket}
  end

  # defp fetch_topics(orcid_id) do
  #   url = "https://api.openalex.org/authors/orcid:#{orcid_id}"

  #   case HTTPoison.get(url) do
  #     {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
  #       data = Jason.decode!(body)
  #       data

  #     _ ->
  #       []
  #   end
  # end
end
