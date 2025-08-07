defmodule Bonfire.OpenScience.OpenAlex.DataLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.APIs
  alias Bonfire.OpenScience.OpenAlex.Client
  alias Bonfire.OpenScience

  prop user, :map, required: true
  prop open_alex_data, :map, default: nil
  prop works_by_type, :list, default: []

  def update(assigns, socket) do
    user = assigns[:user]

    case Bonfire.OpenScience.ORCID.user_orcid_id(user) do
      {:ok, orcid_id} ->
        debug(orcid_id, "Fetching OpenAlex data for ORCID")
        open_alex_data = Client.fetch_topics(orcid_id)
        debug(open_alex_data, "OpenAlex data for main widget")

        works_by_type = Client.fetch_works_by_type(orcid_id)
        debug(works_by_type, "Works by type from OpenAlex")

        {:ok,
         assign(socket,
           open_alex_data: open_alex_data,
           works_by_type: works_by_type
         )}

      _ ->
        debug("No ORCID ID found - OpenAlex data widget will be empty")
        {:ok, assign(socket, open_alex_data: nil, works_by_type: [])}
    end
  end

  def handle_event("show_all_topics", _params, socket) do
    {:noreply, socket}
  end

  def filter_non_zero_counts(items) when is_list(items) do
    Enum.filter(items, fn item -> e(item, "count", 0) > 0 end)
  end

  def filter_non_zero_counts(_), do: []
end
