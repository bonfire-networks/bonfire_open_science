defmodule Bonfire.OpenScience.OpenAlexDataProviderLive do
  use Bonfire.UI.Common.Web, :stateful_component
  alias Bonfire.OpenScience.Publications

  prop user, :map, default: nil
  prop current_user, :map, default: nil

  # Shared data
  prop author_data, :map, default: nil
  prop recent_publication, :map, default: nil
  prop most_cited_publication, :map, default: nil
  prop works_by_type, :list, default: []

  prop enabled_widgets, :map,
    default: %{
      recent_publication: false,
      most_cited_publication: false,
      author_info: false,
      author_topics: false,
      publication_types: false
    }

  def update(assigns, socket) do
    # Handle both regular assigns and Surface component state
    assigns = case assigns do
      %{__context__: _} -> assigns  # Normal assigns
      %{socket: %{assigns: socket_assigns}} -> socket_assigns  # Surface state wrapper
      _ -> assigns
    end
    
    user = assigns[:user]
    current_user = assigns[:current_user] || current_user(socket)

    debug(user, "User in OpenAlex Data Provider")
    debug(current_user, "Current user in OpenAlex Data Provider")

    # Exit early if no user is provided
    if is_nil(user) do
      debug("No user provided - OpenAlex widgets will be empty")

      {:ok,
       assign(socket,
         user: user,
         current_user: current_user,
         author_data: nil,
         recent_publication: nil,
         most_cited_publication: nil,
         works_by_type: [],
         enabled_widgets: %{
           recent_publication: false,
           most_cited_publication: false,
           author_info: false,
           author_topics: false,
           publication_types: false
         }
       )}
    else
      # Fetch enabled widgets using Publications context
      enabled_widgets = Publications.enabled_widgets(current_user || user)

      debug(enabled_widgets, "OpenAlex Data Provider enabled_widgets")

      # Use the simplified Publications context to fetch all data at once
      case Publications.get_all_publication_data(user) do
        {:ok, data} ->
          {:ok,
           assign(socket,
             user: user,
             current_user: current_user,
             author_data: data.author_data,
             recent_publication: data.recent_publication,
             most_cited_publication: data.most_cited_publication,
             works_by_type: data.works_by_type,
             enabled_widgets: enabled_widgets
           )}

        {:error, reason} ->
          debug(reason, "Could not fetch OpenAlex data")

          {:ok,
           assign(socket,
             user: user,
             current_user: current_user,
             author_data: nil,
             recent_publication: nil,
             most_cited_publication: nil,
             works_by_type: [],
             enabled_widgets: enabled_widgets
           )}
      end
    end
  end
end
