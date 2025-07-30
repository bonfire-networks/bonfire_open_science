defmodule Bonfire.OpenScience.OpenAlex.DataLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.APIs
  alias Bonfire.OpenScience

  prop user, :map, required: true
  prop open_alex_data, :map, default: nil
  prop works_by_type, :list, default: []

  def update(assigns, socket) do
    user = assigns[:user]
    aliases = OpenScience.user_aliases(user)
    debug(aliases, "User aliases for OpenAlex data widget")
    orcid_id = APIs.find_orcid_id(aliases)
    debug(orcid_id, "Found ORCID ID for OpenAlex data widget")

    case orcid_id do
      nil ->
        debug("No ORCID ID found - OpenAlex data widget will be empty")
        {:ok, assign(socket, open_alex_data: nil, works_by_type: [])}

      orcid_id ->
        debug(orcid_id, "Fetching OpenAlex data for ORCID")
        open_alex_data = APIs.open_alex_fetch_topics(orcid_id)
        debug(open_alex_data, "OpenAlex data for main widget")

        works_by_type = APIs.open_alex_fetch_works_by_type(orcid_id)
        debug(works_by_type, "Works by type from OpenAlex")

        {:ok,
         assign(socket,
           open_alex_data: open_alex_data,
           works_by_type: works_by_type
         )}
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
