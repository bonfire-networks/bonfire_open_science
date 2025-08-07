defmodule Bonfire.OpenScience.ZenodoMetadataFormLive do
  use Bonfire.UI.Common.Web, :stateful_component
  import Untangle
  alias Bonfire.OpenScience.Zenodo

  prop post, :map, required: true
  prop current_user, :map, required: true

  data metadata, :map, default: %{}
  data creators, :list, default: []
  data errors, :map, default: %{}
  data submitting, :boolean, default: false

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> populate_from_post()

    {:ok, socket}
  end

  defp populate_from_post(socket) do
    post = socket.assigns.post
    current_user = socket.assigns.current_user

    # Extract post title
    title =
      e(post, :post_content, :name, nil) ||
        e(post, :post_content, :html_body, "")
        |> text_only()
        |> String.slice(0..100)
        |> String.trim()

    # Extract description
    description =
      e(post, :post_content, :summary, nil) ||
        e(post, :post_content, :html_body, "")
        |> text_only()
        |> String.slice(0..500)
        |> String.trim()

    # Get publication date
    publication_date = e(post, :inserted_at, nil) || Date.utc_today()
    formatted_date = format_date(publication_date)

    # Get author information
    author_name =
      e(current_user, :profile, :name, nil) ||
        e(current_user, :character, :username, "Unknown Author")

    # Get author affiliation
    author_affiliation =
      e(current_user, :profile, :website, "") ||
        e(current_user, :profile, :location, "")

    initial_creator = %{
      "name" => author_name,
      "orcid" => "",
      "affiliation" => author_affiliation
    }

    # Extract tags/keywords if available
    keywords = extract_keywords(post)

    metadata = %{
      "upload_type" => "publication",
      "title" => title,
      "description" => description,
      "publication_date" => formatted_date,
      "access_right" => "open",
      "license" => "CC-BY-4.0",
      "keywords" => keywords
    }

    socket
    |> assign(metadata: metadata)
    |> assign(creators: [initial_creator])
  end

  defp text_only(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp text_only(_), do: ""

  defp extract_keywords(post) do
    # TODO: Extract actual tags from post if they exist
    # For now, return empty string
    ""
  end

  defp format_date(nil), do: Date.utc_today() |> Date.to_iso8601()
  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_iso8601()
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: Date.utc_today() |> Date.to_iso8601()

  def handle_event("add_creator", _, socket) do
    new_creator = %{
      "name" => "",
      "orcid" => "",
      "affiliation" => ""
    }

    creators = socket.assigns.creators ++ [new_creator]
    {:noreply, assign(socket, creators: creators)}
  end

  def handle_event("remove_creator", %{"index" => index}, socket) do
    # Handle both string and integer index values
    index = if is_binary(index), do: String.to_integer(index), else: index

    # Instead of deleting, mark as hidden to preserve indices
    creators =
      List.update_at(socket.assigns.creators, index, fn creator ->
        Map.put(creator, "_hidden", true)
      end)

    # Check if we still have at least one visible creator
    visible_count = Enum.count(creators, fn c -> not Map.get(c, "_hidden", false) end)

    if visible_count == 0 do
      # Unhide the first creator if all are hidden
      creators =
        List.update_at(creators, 0, fn creator ->
          Map.delete(creator, "_hidden")
        end)
    end

    {:noreply, assign(socket, creators: creators)}
  end

  def handle_event("update_creators", %{"creators" => creators_params}, socket) do
    # Parse the creators params which come in as a map with string keys like "0", "1", etc.
    creators =
      creators_params
      |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
      |> Enum.map(fn {_index, creator} -> creator end)

    {:noreply, assign(socket, creators: creators)}
  end

  def handle_event("update_creators", _, socket) do
    # Handle case where creators params are missing
    {:noreply, socket}
  end

  def handle_event("validate", %{"metadata" => params}, socket) do
    errors = validate_metadata(params, socket.assigns.creators)

    metadata = Map.merge(socket.assigns.metadata, params)

    {:noreply, socket |> assign(metadata: metadata) |> assign(errors: errors)}
  end

  def handle_event("submit", %{"metadata" => params}, socket) do
    metadata = Map.merge(socket.assigns.metadata, params)
    errors = validate_metadata(metadata, socket.assigns.creators)

    if Enum.empty?(errors) do
      {:noreply, socket |> assign(submitting: true) |> submit_to_zenodo(metadata)}
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  defp validate_metadata(metadata, creators) do
    errors = %{}

    # Validate title
    errors =
      if is_nil(metadata["title"]) or String.trim(metadata["title"]) == "" do
        Map.put(errors, :title, "Title is required")
      else
        if String.length(metadata["title"]) > 500 do
          Map.put(errors, :title, "Title must be less than 500 characters")
        else
          errors
        end
      end

    # Validate description
    errors =
      if is_nil(metadata["description"]) or
           String.length(String.trim(metadata["description"])) < 10 do
        Map.put(errors, :description, "Description must be at least 10 characters")
      else
        errors
      end

    # Validate at least one visible creator with name
    visible_creators = Enum.reject(creators, fn c -> Map.get(c, "_hidden", false) end)

    has_valid_creator =
      Enum.any?(visible_creators, fn c ->
        c["name"] != nil and String.trim(c["name"]) != ""
      end)

    errors =
      if not has_valid_creator do
        Map.put(errors, :creators, "At least one author is required")
      else
        errors
      end

    # Validate license if access_right is open or embargoed
    if metadata["access_right"] in ["open", "embargoed"] do
      if is_nil(metadata["license"]) or metadata["license"] == "" do
        Map.put(errors, :license, "License is required for open access")
      else
        errors
      end
    else
      errors
    end
  end

  defp submit_to_zenodo(socket, metadata) do
    # Include creators in the metadata for the API call
    full_metadata = Map.put(metadata, "creators", socket.assigns.creators)

    case Zenodo.create_deposit_for_user(current_user(socket), full_metadata, auto_publish: true) do
      {:ok, %{published: published_record, deposit: deposit}} when published_record != false ->
        doi = e(deposit, "metadata", "prereserve_doi", "doi", nil)
        # deposit_id = e(deposit, "id", nil)

        socket
        |> assign(submitting: false)
        |> assign_flash(:info, "Draft created with DOI: #{doi}")

      {:ok, %{deposit: deposit}} ->
        doi = e(deposit, "metadata", "prereserve_doi", "doi", nil)
        # deposit_id = e(deposit, "id", nil)

        socket
        |> assign(submitting: false)
        |> assign_flash(:info, "Successfully published! DOI: #{doi}")

      # |> push_event("modal", %{action: "close", id: "zenodo-doi-modal"})

      {:error, reason} ->
        error_msg =
          case reason do
            :no_zenodo_credentials ->
              "Please connect your Zenodo account first"

            :invalid_zenodo_credentials ->
              "Invalid Zenodo credentials - please reconnect your account"

            :zenodo_api_error ->
              "Zenodo API error occurred"

            :request_failed ->
              "Network error - please try again"

            _ ->
              "Failed to create DOI: #{inspect(reason)}"
          end

        socket
        |> assign(submitting: false)
        |> assign_error(error_msg)
    end
  end

  def upload_type_options do
    [
      {"Publication", "publication"},
      {"Dataset", "dataset"},
      {"Software", "software"},
      {"Other", "other"}
    ]
  end

  def access_right_options do
    [
      {"Open Access", "open"},
      {"Embargoed", "embargoed"},
      {"Restricted", "restricted"},
      {"Closed", "closed"}
    ]
  end

  def license_options do
    [
      {"Creative Commons Attribution 4.0", "CC-BY-4.0"},
      {"Creative Commons Attribution Share-Alike 4.0", "CC-BY-SA-4.0"},
      {"Creative Commons Zero (Public Domain)", "CC0-1.0"},
      {"MIT License", "MIT"},
      {"Apache License 2.0", "Apache-2.0"}
    ]
  end
end
