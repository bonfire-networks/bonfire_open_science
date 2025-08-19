defmodule Bonfire.OpenScience.ZenodoMetadataFormLive do
  use Bonfire.UI.Common.Web, :stateful_component
  import Untangle
  alias Bonfire.OpenScience.Zenodo

  prop post, :map, required: true
  prop participants, :any, default: nil
  prop include_comments, :boolean, default: true
  prop api_type, :any, default: nil

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
    api_type = socket.assigns.api_type
    current_user = current_user(socket)

    # Extract post title
    title =
      (e(post, :post_content, :name, nil) || e(post, :post_content, :summary, nil) ||
         e(post, :post_content, :html_body, "") |> Text.maybe_markdown_to_html())
      |> Text.text_only()
      |> Text.sentence_truncate(100)

    # Extract description
    description =
      """
      #{if e(post, :post_content, :name, nil), do: e(post, :post_content, :summary, nil)}
      #{e(post, :post_content, :html_body, nil)}
      """
      # |> Text.text_only()
      |> String.trim()
      |> Text.sentence_truncate(50_000)

    # e(post, :replied, :thread_id, nil) || 
    thread_id =
      id(post)

    replies_opts = replies_opts()

    replies =
      case Bonfire.Social.Threads.list_replies(thread_id, replies_opts) |> debug("repliess") do
        %{edges: replies} when replies != [] ->
          replies

        _ ->
          []
      end

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
      "orcid" => Bonfire.OpenScience.ORCID.user_orcid_id(current_user) |> ok_unwrap(),
      "affiliation" => author_affiliation
    }

    # Get thread participants as co-authors (included by default)
    thread_participants =
      thread_participants_as_creators(e(assigns(socket), :participants, nil), post, current_user)

    creators = [initial_creator | thread_participants]

    # Extract tags/keywords if available
    keywords = extract_keywords(post)

    metadata = %{
      "upload_type" => "publication",
      "title" => title,
      "description" => description,
      # "additional_descriptions" => comments_as_descriptions(post, current_user: current_user),
      # "notes" => comments_as_descriptions(replies, opts),
      "publication_date" => formatted_date,
      "access_right" => "open",
      "license" => "CC-BY-4.0",
      "keywords" => keywords
    }

    socket
    |> assign(
      metadata: metadata,
      replies: if(api_type == :invenio, do: replies),
      notes: comments_as_note(replies, :html, replies_opts),
      # additional_descriptions: if(api_type==:invenio, do: comments_as_descriptions(replies, opts)),
      reply_ids: replies |> Enum.map(&e(&1, :activity, :id, nil)),
      creators: creators
    )
  end

  defp replies_opts(limit \\ 5_000) do
    [
      #  NOTE: we only want to include public ones
      current_user: nil,
      preload: [:with_subject, :with_post_content],
      limit: limit,
      max_depth: limit
      # sort_by: sort_by
    ]
  end

  defp comments_as_note(replies, render_as \\ :html, opts \\ []) do
    replies
    |> Bonfire.Social.Threads.prepare_replies_tree(opts)
    |> debug("repliesstreee")
    # |> Enum.map(fn {reply, child_replies} ->
    # render_recursive_descriptions(reply, child_replies, render_as)
    # end)
    |> recursive_descriptions(render_as)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp comments_as_descriptions(replies, render_as \\ :html, opts \\ []) do
    replies
    |> Bonfire.Social.Threads.prepare_replies_tree(opts)
    |> debug("repliesstreee")
    # |> Enum.map(fn {reply, child_replies} ->
    # render_recursive_descriptions(reply, child_replies, render_as)
    # end)
    |> recursive_descriptions(render_as)
  end

  defp recursive_descriptions(replies, render_as \\ :html) do
    replies
    |> Enum.map(fn {reply, child_replies} ->
      render_recursive_descriptions(reply, child_replies, render_as)
    end)
  end

  defp render_recursive_descriptions(reply, child_replies, render_as \\ :html, level \\ 0)

  defp render_recursive_descriptions(reply, child_replies, :markdown, level) do
    author =
      e(reply, :activity, :subject, :profile, :name, nil) ||
        e(reply, :activity, :subject, :character, :username, nil) ||
        "Unknown"

    fields = [
      {"**#{author}:**", true},
      {e(reply, :activity, :object, :post_content, :name, nil), false},
      {e(reply, :activity, :object, :post_content, :summary, nil), false},
      {e(reply, :activity, :object, :post_content, :html_body, nil), false}
    ]

    content =
      fields
      |> Enum.map(fn
        {text, true} when is_binary(text) and text != "" ->
          "#{text}\n"

        {text, false} when is_binary(text) ->
          text = String.trim(text)
          if text not in ["", "<p> </p>"], do: "#{text}\n", else: ""

        _ ->
          ""
      end)
      |> Enum.join("")
      |> String.trim()

    quote_prefix = String.duplicate("> ", level)

    quoted_content =
      content
      |> String.split("\n")
      |> Enum.map(&(quote_prefix <> &1))
      |> Enum.join("\n")

    children =
      child_replies
      |> Enum.map(fn {child, children} ->
        render_recursive_descriptions(child, children, :markdown, level + 1)
      end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    result =
      if children != "" do
        quoted_content <> "\n" <> children
      else
        quoted_content
      end

    result
    |> Text.sentence_truncate(50_000)
  end

  defp render_recursive_descriptions(reply, child_replies, _html, _) do
    fields = [
      {"<strong>#{e(reply, :activity, :subject, :profile, :name, nil)} (#{e(reply, :activity, :subject, :character, :username, nil)}):</strong>",
       true},
      {e(reply, :activity, :object, :post_content, :name, nil), false},
      {e(reply, :activity, :object, :post_content, :summary, nil)
       |> Text.maybe_markdown_to_html(), false},
      {e(reply, :activity, :object, :post_content, :html_body, nil)
       |> Text.maybe_markdown_to_html(), false}
    ]

    content =
      fields
      |> Enum.map(fn
        {text, true} ->
          "<p>#{text}</p>"

        {text, false} when is_binary(text) ->
          text = String.trim(text) |> debug("txxxt")
          if text not in ["", "<p> </p>"], do: "<p>#{text}</p>", else: ""

        _ ->
          ""
      end)
      |> Enum.join("")

    children =
      child_replies
      |> Enum.map(fn {child, children} -> render_recursive_descriptions(child, children) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    """
    <blockquote class="ml-4 border-l-1">
    #{content}
    #{children}
    </blockquote>
    """
    |> Text.sentence_truncate(50_000)
  end

  defp thread_participants_as_creators(participants, post, current_user) do
    # Get thread ID from the post
    thread_id = e(post, :replied, :thread_id, nil) || id(post)

    if thread_id do
      # Get thread participants using Bonfire.Social.Threads
      case participants ||
             Bonfire.Social.Threads.list_participants(post, thread_id,
               current_user: current_user,
               limit: 20
             ) do
        participants when is_list(participants) ->
          participants
          |> Enum.reject(fn p ->
            # Exclude the current user (already added as primary author)
            id(p) == e(current_user, :id, nil)
          end)
          |> Enum.map(fn participant ->
            %{
              "id" => id(participant),
              "name" =>
                e(participant, :profile, :name, nil) ||
                  e(participant, :character, :username, "Unknown"),
              "orcid" => Bonfire.OpenScience.ORCID.user_orcid_id(participant) |> ok_unwrap(),
              "affiliation" =>
                e(participant, :profile, :website, "") ||
                  e(participant, :profile, :location, "")
            }
          end)
          # Remove any duplicates 
          |> Enum.uniq_by(fn c -> c["orcid"] || c["id"] end)

        _ ->
          []
      end
    else
      []
    end
  end

  defp text_only(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp text_only(_), do: ""

  defp extract_keywords(_post) do
    # TODO: Extract actual tags from post if they exist
    ""
  end

  defp format_date(nil), do: Date.utc_today() |> Date.to_iso8601()
  defp format_date(%DateTime{} = dt), do: DateTime.to_date(dt) |> Date.to_iso8601()
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(_), do: Date.utc_today() |> Date.to_iso8601()

  def handle_event("toggle_include_comments", _, socket) do
    # toggle
    include_comments = !e(assigns(socket), :include_comments, true)

    # Update creators list based on the toggle
    creators =
      if include_comments do
        # Add thread participants
        post = socket.assigns.post
        current_user = current_user(socket)

        # Get thread participants
        thread_participants =
          thread_participants_as_creators(
            e(assigns(socket), :participants, nil),
            post,
            current_user
          )

        socket.assigns.creators ++ thread_participants
      else
        # Keep only the primary author (first in the list)
        case socket.assigns.creators do
          [first | _rest] -> [first]
          [] -> []
        end
      end

    {:noreply,
     socket
     |> assign(include_comments: include_comments)
     |> assign(creators: creators)}
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

    creators =
      if visible_count == 0 do
        # Unhide the first creator if all are hidden
        List.update_at(creators, 0, fn creator ->
          Map.delete(creator, "_hidden")
        end)
      else
        creators
      end

    {:noreply, assign(socket, creators: creators)}
  end

  def handle_event("validate", params, socket) do
    metadata_params = Map.get(params, "metadata", %{})
    existing_metadata = socket.assigns.metadata

    # Preserve existing values for fields not in params
    metadata =
      Enum.reduce(existing_metadata, %{}, fn {key, value}, acc ->
        new_value = Map.get(metadata_params, key, value)
        Map.put(acc, key, new_value)
      end)

    creators =
      if Map.has_key?(params, "creators") do
        extract_creators_from_params(params)
      else
        socket.assigns.creators
      end

    errors = validate_metadata(metadata, creators)

    {:noreply, socket |> assign(metadata: metadata) |> assign(errors: errors)}
  end

  def handle_event("submit", params, socket) do
    case Map.get(params, "action") do
      "add_creator" -> handle_add_creator_from_form(params, socket)
      _ -> handle_form_submit(params, socket)
    end
  end

  defp handle_add_creator_from_form(params, socket) do
    current_creators = extract_creators_from_params(params)

    new_creator = %{
      "name" => "",
      "orcid" => "",
      "affiliation" => ""
    }

    creators = current_creators ++ [new_creator]
    metadata_params = Map.get(params, "metadata", %{})
    metadata = Map.merge(socket.assigns.metadata, metadata_params)

    {:noreply,
     socket
     |> assign(creators: creators)
     |> assign(metadata: metadata)}
  end

  defp handle_form_submit(params, socket) do
    creators = extract_creators_from_params(params)
    metadata_params = Map.get(params, "metadata", %{})
    metadata = Map.merge(socket.assigns.metadata, metadata_params)

    errors = validate_metadata(metadata, creators)

    if Enum.empty?(errors) do
      {:noreply,
       socket
       #  |> assign(creators: creators)
       |> assign(submitting: true)
       |> submit_to_zenodo(metadata, creators)}
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  defp extract_creators_from_params(%{"creators" => creators_params})
       when is_map(creators_params) do
    creators_params
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_index, creator} -> creator end)
    |> Enum.reject(fn creator -> Map.get(creator, "_hidden", false) end)
  end

  defp extract_creators_from_params(_), do: []

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

  defp submit_to_zenodo(socket, metadata, creators) do
    current_user = current_user(socket)
    api_type = socket.assigns.api_type
    include_comments = socket.assigns.include_comments

    # Include creators in the metadata for the API call
    metadata =
      metadata
      # |> Map.put("creators", creators)
      |> Map.update("description", nil, fn description ->
        if api_type == :invenio do
          # NOTE: kcworks is not rendering html, so just send markdown for now
          description

          #  "#{description}\n\n#{comments_as_note(e(socket.assigns, :replies, nil), :markdown, replies_opts())}"
          #  "#{Text.maybe_markdown_to_html(description)}\n\n#{e(socket.assigns, :notes, nil)}"
        else
          Text.maybe_markdown_to_html(description)
        end
      end)
      |> Map.put(
        "notes",
        if(api_type == :zenodo, do: e(socket.assigns, :notes, nil))
      )

    # |> Map.put("creators", socket.assigns.creators)
    # |> Map.put("include_comments", include_comments)

    object = socket.assigns.post

    with {:ok, %{deposit: deposit} = result} <-
           Zenodo.publish_deposit_for_user(
             current_user,
             creators,
             metadata,
             [
               # Attach the post content as a file
               if(include_comments && api_type == :invenio,
                 do:
                   {"discussion.md",
                    comments_as_note(e(socket.assigns, :replies, nil), :markdown, replies_opts())
                    |> stream_into()}
               ),
               {"primary_content.json", prepare_record_json(object)},
               # Maybe attach the comments too
               if(include_comments,
                 do:
                   {"replies.json",
                    Bonfire.UI.Me.ExportController.create_json_stream(nil, "thread",
                      replies: socket.assigns.reply_ids || []
                    )}
               )
             ],
             auto_publish: true
           )
           |> debug("published?"),
         doi when is_binary(doi) <-
           e(result, :published, "doi_url", nil) ||
             if(
               doi =
                 e(result, :published, "pids", "doi", "identifier", nil) ||
                   e(deposit, "pids", "doi", "identifier", nil) ||
                   e(deposit, "metadata", "prereserve_doi", "doi", nil),
               do: "https://doi.org/#{doi}"
             ),
         {:ok, _} <-
           Bonfire.OpenScience.save_as_attached_media(
             current_user,
             doi,
             %{
               "zenodo" =>
                 e(result, :published, nil) || Map.put(deposit, "files", e(result, :files, []))
             },
             object
           )
           |> debug("attached?") do
      cond do
        e(result, :published, nil) ->
          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, "Successfully published DOI: #{doi}")

        doi = e(deposit, "metadata", "prereserve_doi", "doi", nil) ->
          doi = "https://doi.org/#{doi}"

          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, "Draft created with DOI: #{doi}")

        true ->
          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, "Draft created")
      end
    else
      {:error, reason} when is_binary(reason) ->
        socket
        |> assign(submitting: false)
        |> assign_error(reason)

      other ->
        error(other, "Failed to create DOI")

        socket
        |> assign(submitting: false)
        |> assign_error("Failed to create DOI")
    end
  end

  defp prepare_record_json(post) do
    with {:ok, json} <- Bonfire.UI.Me.ExportController.object_json(post) do
      json
      |> stream_into()
    else
      _ ->
        []
    end

    # |> debug("jsssson")
  end

  defp stream_into(data) do
    data
    |> List.wrap()
    |> Stream.into([])
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
