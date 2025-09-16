defmodule Bonfire.OpenScience.ZenodoMetadataFormLive do
  use Bonfire.UI.Common.Web, :stateful_component
  import Untangle
  alias Bonfire.OpenScience.Zenodo
  alias Bonfire.OpenScience.Zenodo.MetadataHelpers

  prop object, :map, required: true
  prop participants, :any, default: nil
  prop include_comments, :boolean, default: true
  prop api_type, :any, default: nil
  # Edit mode props
  # :create, :edit_metadata, :new_version
  prop mode, :atom, default: :create
  prop zenodo_info, :map, default: nil
  # The media record containing Zenodo metadata
  prop media, :any, default: nil

  data current_metadata, :map, default: %{}
  data creators, :list, default: []
  data errors, :map, default: %{}
  data submitting, :boolean, default: false
  data add_to_orcid, :boolean, default: false
  data has_orcid_token, :boolean, default: false

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> populate_data()

    {:ok, socket}
  end

  defp populate_data(socket) do
    case socket.assigns.mode do
      :create -> populate_from_post(socket)
      mode when mode in [:edit_metadata, :new_version] -> populate_from_existing(socket)
      _ -> populate_from_post(socket)
    end
  end

  defp populate_from_post(socket) do
    object = socket.assigns.object
    api_type = socket.assigns.api_type
    current_user = current_user(socket)

    # Extract post title
    title =
      (e(object, :post_content, :name, nil) || e(object, :post_content, :summary, nil) ||
         e(object, :post_content, :html_body, "") |> Text.maybe_markdown_to_html())
      |> Text.text_only()
      |> Text.sentence_truncate(100)

    # Extract description
    description =
      """
      #{if e(object, :post_content, :name, nil), do: e(object, :post_content, :summary, nil)}
      #{e(object, :post_content, :html_body, nil)}
      """
      # |> Text.text_only()
      |> String.trim()
      |> Text.sentence_truncate(50_000)

    # e(object, :replied, :thread_id, nil) || 
    thread_id =
      id(object)

    replies_opts = replies_opts()

    replies =
      case Bonfire.Social.Threads.list_replies(thread_id, replies_opts) do
        %{edges: replies} when replies != [] ->
          replies

        _ ->
          []
      end

    # Get publication date
    publication_date = e(object, :inserted_at, nil) || Date.utc_today()
    formatted_date = format_date(publication_date)

    # Get author information
    author_name =
      e(current_user, :profile, :name, nil) ||
        e(current_user, :character, :username, "Unknown Author")

    # Get author affiliation
    author_affiliation =
      e(current_user, :profile, :website, "") ||
        e(current_user, :profile, :location, "")

    user_orcid_meta = Bonfire.OpenScience.ORCID.user_orcid_meta(current_user)

    user_orcid_id =
      case Bonfire.OpenScience.ORCID.orcid_id(user_orcid_meta) do
        {:ok, id} -> id
        _ -> nil
      end

    initial_creator = %{
      "id" => id(current_user),
      "name" => author_name,
      "orcid" => user_orcid_id,
      "affiliation" => author_affiliation
    }

    # Get thread participants as co-authors (included by default)
    thread_participants =
      thread_participants_as_creators(
        e(assigns(socket), :participants, nil),
        object,
        current_user
      )

    creators = [initial_creator | thread_participants]

    # Extract tags/keywords if available
    keywords = extract_keywords(object)

    metadata = %{
      "upload_type" => MetadataHelpers.get_default_upload_type(),
      "title" => title,
      "description" => description,
      # "additional_descriptions" => comments_as_descriptions(object, current_user: current_user),
      # "notes" => comments_as_descriptions(replies, opts),
      "publication_date" => formatted_date,
      "access_right" => MetadataHelpers.get_default_access_right(),
      "license" => MetadataHelpers.get_default_license(),
      "keywords" => keywords
    }

    has_orcid_token = user_orcid_id && Bonfire.OpenScience.ORCID.has_orcid_write_access?()

    socket
    |> assign(
      current_metadata: metadata,
      replies: if(api_type == :invenio, do: replies),
      notes: comments_as_note(replies, :html),
      # additional_descriptions: if(api_type==:invenio, do: comments_as_descriptions(replies, opts)),
      reply_ids: replies |> Enum.map(&e(&1, :activity, :id, nil)),
      creators: creators,
      has_orcid_token: has_orcid_token,
      add_to_orcid: has_orcid_token,
      include_comments: socket.assigns.include_comments
    )
  end

  defp populate_from_existing(socket) do
    current_user = current_user(socket)

    # Extract the actual Zenodo deposit data from the metadata structure
    # The metadata comes in format: %{"zenodo" => zenodo_deposit_data}
    zenodo_metadata = e(socket.assigns.media, :metadata, "zenodo", "metadata", %{})

    # Get ORCID info once at the beginning
    user_orcid_meta = Bonfire.OpenScience.ORCID.user_orcid_meta(current_user)

    user_orcid_id =
      case Bonfire.OpenScience.ORCID.orcid_id(user_orcid_meta) do
        {:ok, id} -> id
        _ -> nil
      end

    has_orcid_token = user_orcid_id && Bonfire.OpenScience.ORCID.has_orcid_write_access?()

    # Extract creators from existing Zenodo metadata
    zenodo_creators =
      case e(zenodo_metadata, "creators", nil) do
        creators when is_list(creators) ->
          creators
          |> Enum.map(fn creator ->
            %{
              "id" => e(creator, "id", nil),
              "name" => e(creator, "name", "") || "",
              "orcid" => e(creator, "orcid", "") || "",
              "affiliation" => e(creator, "affiliation", "") || ""
            }
          end)

        _ ->
          []
      end

    # Get thread participants as creators (with up-to-date profile info)
    thread_participants =
      thread_participants_as_creators(
        e(socket.assigns, :participants, nil),
        socket.assigns.object,
        current_user
      )

    # Merge zenodo_creators and thread_participants
    creators =
      MetadataHelpers.merge_creators_with_participants(zenodo_creators, thread_participants)

    # Extract and format the publication date
    pub_date =
      case e(zenodo_metadata, "publication_date", nil) do
        date_str when is_binary(date_str) -> date_str
        _ -> format_date(Date.utc_today())
      end

    # Convert keywords from list to comma-separated string if needed
    keywords =
      case e(zenodo_metadata, "keywords", nil) do
        keywords when is_list(keywords) -> Enum.join(keywords, ", ")
        keywords when is_binary(keywords) -> keywords
        _ -> ""
      end

    # Use existing Zenodo metadata with fallbacks
    metadata = %{
      "upload_type" =>
        e(zenodo_metadata, "resource_type", "type", nil) || e(zenodo_metadata, "upload_type", nil) ||
          MetadataHelpers.get_default_upload_type(),
      "title" => e(zenodo_metadata, "title", nil) || "",
      "description" => e(zenodo_metadata, "description", nil) || "",
      "publication_date" => pub_date,
      "access_right" =>
        e(zenodo_metadata, "access_right", nil) || MetadataHelpers.get_default_access_right(),
      "license" =>
        e(zenodo_metadata, "license", "id", nil) || e(zenodo_metadata, "license", nil) ||
          MetadataHelpers.get_default_license(),
      "keywords" => keywords
    }

    # For new versions, we need comment data too
    socket =
      if socket.assigns.mode == :new_version do
        object = socket.assigns.object
        thread_id = id(object)
        replies_opts = replies_opts()

        replies =
          case Bonfire.Social.Threads.list_replies(thread_id, replies_opts) do
            %{edges: replies} when replies != [] ->
              replies

            _ ->
              []
          end

        reply_ids = Enum.map(replies, fn reply -> id(reply) end)
        notes = comments_as_note(replies, :html, replies_opts)

        socket
        |> assign(
          replies: replies,
          reply_ids: reply_ids,
          notes: notes,
          # Allow comments for new versions
          include_comments: true
        )
      else
        socket
        # Don't show comments toggle for metadata edit only
        |> assign(include_comments: false)
      end

    socket
    |> assign(
      current_metadata: metadata,
      creators: creators,
      has_orcid_token: has_orcid_token,
      add_to_orcid: has_orcid_token
    )
  end

  defp replies_opts() do
    [
      #  NOTE: we only want to include public ones
      current_user: nil,
      preload: [:with_subject, :with_post_content],
      limit: 5000,
      max_depth: 5000
      # sort_by: sort_by
    ]
  end

  defp comments_as_note(replies, render_as \\ :html, opts \\ []) do
    maybe_apply(Bonfire.UI.Posts, :render_replies, [replies, render_as, opts])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp thread_participants_as_creators(participants, object, current_user) do
    # Get thread ID from the object
    thread_id = e(object, :replied, :thread_id, nil) || id(object)

    current_user_id = id(current_user)

    if thread_id do
      # Get thread participants using Bonfire.Social.Threads
      case participants ||
             Bonfire.Social.Threads.list_participants(object, thread_id,
               current_user: current_user,
               limit: 20
             ) do
        participants when is_list(participants) ->
          participants
          |> Enum.reject(fn p ->
            # Exclude the current user (already added as primary author)
            id(p) == current_user_id
          end)
          |> Enum.map(fn participant ->
            %{
              "id" => id(participant),
              "name" =>
                e(participant, :profile, :name, nil) ||
                  e(participant, :character, :username, "Unknown"),
              "orcid" =>
                case Bonfire.OpenScience.ORCID.user_orcid_id(participant) do
                  {:ok, id} -> id
                  _ -> nil
                end,
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
        object = socket.assigns.object
        current_user = current_user(socket)

        # Get thread participants
        thread_participants =
          thread_participants_as_creators(
            e(assigns(socket), :participants, nil),
            object,
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
    existing_metadata = socket.assigns.current_metadata

    # Preserve existing values for fields not in params
    metadata =
      Enum.reduce(existing_metadata, %{}, fn {key, value}, acc ->
        new_value = Map.get(metadata_params, key, value)
        Map.put(acc, key, new_value)
      end)

    creators =
      if Map.has_key?(params, "creators") do
        MetadataHelpers.extract_creators_from_params(params)
      else
        socket.assigns.creators
      end

    # Handle ORCID checkbox
    add_to_orcid = Map.get(params, "add_to_orcid") == "on"

    errors = MetadataHelpers.validate_metadata(metadata, creators)

    {:noreply,
     socket
     |> assign(
       current_metadata: metadata,
       creators: creators,
       errors: errors,
       add_to_orcid: add_to_orcid
     )}
  end

  def handle_event("submit", params, socket) do
    case Map.get(params, "action") do
      "add_creator" -> handle_add_creator_from_form(params, socket)
      _ -> handle_form_submit(params, socket)
    end
  end

  defp handle_add_creator_from_form(params, socket) do
    current_creators = MetadataHelpers.extract_creators_from_params(params)

    new_creator = %{
      "name" => "",
      "orcid" => "",
      "affiliation" => ""
    }

    creators = current_creators ++ [new_creator]
    metadata_params = Map.get(params, "metadata", %{})
    metadata = Map.merge(socket.assigns.current_metadata, metadata_params)

    {:noreply,
     socket
     |> assign(creators: creators)
     |> assign(current_metadata: metadata)}
  end

  defp handle_form_submit(params, socket) do
    creators = MetadataHelpers.extract_creators_from_params(params)
    metadata_params = Map.get(params, "metadata", %{})
    metadata = Map.merge(socket.assigns.current_metadata, metadata_params)

    handle_submission(socket.assigns.mode, socket, metadata, creators)
  end

  defp handle_submission(:edit_metadata, socket, metadata, creators) do
    errors = MetadataHelpers.validate_metadata(metadata, creators)

    if Enum.empty?(errors) do
      {:noreply,
       socket
       |> assign(submitting: true)
       |> update_zenodo_metadata(metadata, creators)}
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  defp handle_submission(:new_version, socket, metadata, creators) do
    errors = MetadataHelpers.validate_metadata(metadata, creators)

    if Enum.empty?(errors) do
      {:noreply,
       socket
       |> assign(submitting: true)
       |> create_zenodo_new_version(metadata, creators)}
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  defp handle_submission(_create, socket, metadata, creators) do
    errors = MetadataHelpers.validate_metadata(metadata, creators)

    if Enum.empty?(errors) do
      {:noreply,
       socket
       |> assign(submitting: true)
       |> submit_to_zenodo(metadata, creators)}
    else
      {:noreply, assign(socket, errors: errors)}
    end
  end

  defp update_zenodo_metadata(socket, metadata, creators) do
    current_user = current_user(socket)

    with {:ok, zenodo_info} <-
           MetadataHelpers.validate_update_params(current_user, socket.assigns.zenodo_info),
         {:ok, processed_metadata} <- prepare_metadata_for_update(socket, metadata),
         {:ok, result} <-
           execute_metadata_update(
             socket,
             current_user,
             zenodo_info,
             processed_metadata,
             creators
           ) do
      handle_update_success(socket, result, current_user, zenodo_info)
    else
      {:error, error_msg} when is_binary(error_msg) ->
        socket
        |> assign(submitting: false)
        |> assign_error(error_msg)

      other ->
        error(other, "Failed to update metadata - unexpected error")

        socket
        |> assign(submitting: false)
        |> assign_error("Failed to update metadata: #{inspect(other)}")
    end
  end

  defp prepare_metadata_for_update(socket, metadata) do
    api_type = socket.assigns.api_type

    processed_metadata =
      metadata
      |> Map.update("description", nil, fn description ->
        if api_type == :invenio do
          description
        else
          Text.maybe_markdown_to_html(description)
        end
      end)
      |> Map.put("notes", if(api_type == :zenodo, do: e(socket.assigns, :notes, nil)))

    {:ok, processed_metadata}
  end

  defp execute_metadata_update(socket, current_user, zenodo_info, processed_metadata, creators) do
    deposit_id = zenodo_info[:deposit_id]
    api_type = socket.assigns.api_type

    debug({deposit_id, api_type}, "Starting metadata update workflow")

    with {:ok, access_token, _api_type} <- Zenodo.get_user_zenodo_token(current_user),
         {:ok, deposit_info} <- Zenodo.get_deposit(deposit_id, access_token, api_type),
         {:ok, result} <-
           Zenodo.handle_zenodo_edit_workflow(
             deposit_info,
             deposit_id,
             creators,
             processed_metadata,
             access_token,
             api_type
           ) do
      {:ok, result}
    end
  end

  defp handle_update_success(socket, result, current_user, zenodo_info) do
    case update_local_media_record(socket, current_user, zenodo_info, result) do
      {:ok, _media} ->
        socket
        |> assign(submitting: false)
        |> assign_flash(:info, l("Metadata updated and published successfully"))

      {:error, media_error} ->
        error(media_error, "Media update failed but Zenodo update was successful")

        socket
        |> assign(submitting: false)
        |> assign_flash(
          :info,
          l("Metadata updated and published on Zenodo, but local record update failed")
        )
    end
  end

  defp update_local_media_record(socket, current_user, zenodo_info, _result) do
    api_type = socket.assigns.api_type
    deposit_id = zenodo_info[:deposit_id]

    # Try to get updated deposit info from Zenodo
    with {:ok, access_token, _api_type} <- Zenodo.get_user_zenodo_token(current_user),
         {:ok, updated_deposit} <- Zenodo.get_deposit(deposit_id, access_token, api_type) do
      # Prepare metadata structure
      zenodo_metadata = Map.merge(zenodo_info, updated_deposit)

      full_metadata = %{
        "title" =>
          e(updated_deposit, "title", nil) || e(updated_deposit, "metadata", "title", nil),
        "description" =>
          e(updated_deposit, "description", nil) ||
            e(updated_deposit, "metadata", "description", nil),
        "creator" => e(updated_deposit, "metadata", "creators", nil),
        "url" =>
          zenodo_info[:doi] || e(updated_deposit, "doi_url", nil) ||
            e(updated_deposit, "links", "latest_html", nil),
        "zenodo" => zenodo_metadata
      }

      # Update or create media record
      case socket.assigns.media do
        media when not is_nil(media) ->
          existing_metadata = e(media, :metadata, %{})
          merged_metadata = Map.merge(existing_metadata, full_metadata)
          Bonfire.Files.Media.update(current_user, media, %{metadata: merged_metadata})

        nil ->
          # Create new media record
          doi_url = zenodo_info[:doi] || e(updated_deposit, "doi_url", nil)

          Bonfire.OpenScience.save_as_attached_media(
            current_user,
            doi_url,
            full_metadata,
            socket.assigns.object
          )
      end
    else
      {:error, reason} ->
        {:error, "Failed to update local media record: #{inspect(reason)}"}
    end
  end

  defp create_zenodo_new_version(socket, metadata, creators) do
    current_user = current_user(socket)
    zenodo_info = socket.assigns.zenodo_info

    if is_nil(zenodo_info) || is_nil(zenodo_info[:deposit_id]) do
      socket
      |> assign(submitting: false)
      |> assign_error("Missing Zenodo deposit information")
    else
      deposit_id = zenodo_info[:deposit_id]
      api_type = socket.assigns.api_type
      include_comments = socket.assigns.include_comments

      # Include creators in the metadata for the API call
      metadata =
        metadata
        |> Map.update("description", nil, fn description ->
          if api_type == :invenio do
            # NOTE: kcworks is not rendering html, so just send markdown for now
            description
          else
            Text.maybe_markdown_to_html(description)
          end
        end)
        |> Map.put(
          "notes",
          if(api_type == :zenodo, do: e(socket.assigns, :notes, nil))
        )

      object = socket.assigns.object

      with {:ok, access_token, _api_type} <- Zenodo.get_user_zenodo_token(current_user),
           {:ok, new_deposit} <-
             Zenodo.create_new_version(deposit_id, access_token, api_type),
           new_deposit_id <- new_deposit["id"],
           {:ok, _updated} <-
             Zenodo.update_deposit_metadata(
               new_deposit_id,
               creators,
               metadata,
               access_token,
               api_type
             ),
           # Upload files to the new version
           bucket_url <- new_deposit["links"]["bucket"] || new_deposit["links"]["files"],
           files_to_upload <-
             [
               # Attach the post content as a file
               if(include_comments && api_type == :invenio,
                 do:
                   {"discussion.md",
                    comments_as_note(e(socket.assigns, :replies, nil), :markdown, replies_opts())
                    |> MetadataHelpers.stream_into()}
               ),
               {"primary_content.json", MetadataHelpers.prepare_record_json(object)},
               # Maybe attach the comments too
               if(include_comments,
                 do:
                   {"replies.json",
                    Bonfire.UI.Social.ExportController.create_json_stream(nil, "thread",
                      replies: socket.assigns.reply_ids || []
                    )}
               )
             ]
             |> Enum.reject(&is_nil/1),
           {:ok, _files} <-
             Zenodo.upload_multiple_files(bucket_url, files_to_upload, access_token, api_type),
           {:ok, published} <-
             Zenodo.publish_deposit(new_deposit_id, access_token, api_type) do
        # Get the new DOI using the same helper as original
        new_doi = Bonfire.OpenScience.Zenodo.extract_doi_from_deposit(published)

        if is_nil(new_doi) do
          error(published, "No DOI found in published deposit")

          socket
          |> assign(submitting: false)
          |> assign_error("Failed to get DOI from new version")
        else
          # Update the thread's media metadata with new version info
          {:ok, _} =
            Bonfire.OpenScience.save_as_attached_media(
              current_user,
              new_doi,
              %{"zenodo" => published},
              socket.assigns.object
            )

          # Try to add to ORCID if user opted in
          orcid_result =
            if socket.assigns.add_to_orcid do
              Bonfire.OpenScience.ORCID.MemberAPI.maybe_add_to_orcid(
                current_user,
                new_doi,
                metadata,
                creators
              )
            end

          # Send DM notifications to co-authors without ORCID
          spawn(fn ->
            Bonfire.OpenScience.DOICoauthorNotifications.notify_coauthors_after_doi_publish(
              current_user,
              # the object
              object,
              new_doi,
              creators,
              metadata["title"]
            )
          end)

          flash_message =
            case orcid_result do
              {:ok, _} ->
                "Successfully created new version with DOI: #{new_doi} and added to your ORCID profile."

              {:error, e} when is_binary(e) ->
                "Successfully created new version with DOI: #{new_doi}\n#{e}"

              _ ->
                "Successfully created new version with DOI: #{new_doi}"
            end

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, flash_message)
        end
      else
        {:error, reason} when is_binary(reason) ->
          socket
          |> assign(submitting: false)
          |> assign_error(reason)

        other ->
          error(other, "Failed to create new version")

          socket
          |> assign(submitting: false)
          |> assign_error("Failed to create new version")
      end
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

    object = socket.assigns.object

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
                    |> MetadataHelpers.stream_into()}
               ),
               {"primary_content.json", MetadataHelpers.prepare_record_json(object)},
               # Maybe attach the comments too
               if(include_comments,
                 do:
                   {"replies.json",
                    Bonfire.UI.Social.ExportController.create_json_stream(nil, "thread",
                      replies: socket.assigns.reply_ids || []
                    )}
               )
             ],
             auto_publish: true
           )
           |> debug("published?"),
         doi when is_binary(doi) <-
           Bonfire.OpenScience.Zenodo.extract_doi_from_deposit(e(result, :published, nil)) ||
             Bonfire.OpenScience.Zenodo.extract_doi_from_deposit(deposit),
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
          # Try to add to ORCID if user opted in
          debug({socket.assigns.add_to_orcid, creators}, "ORCID publishing check")

          orcid_result =
            if socket.assigns.add_to_orcid do
              debug("Attempting ORCID publishing")

              Bonfire.OpenScience.ORCID.MemberAPI.maybe_add_to_orcid(
                current_user,
                doi,
                metadata,
                creators
              )
            end
            |> debug("ORCID publishing result")

          # Send DM notifications to co-authors without ORCID
          spawn(fn ->
            Bonfire.OpenScience.DOICoauthorNotifications.notify_coauthors_after_doi_publish(
              current_user,
              # the post
              object,
              doi,
              creators,
              metadata["title"]
            )
          end)

          flash_message =
            case orcid_result do
              {:ok, _} -> "Successfully published DOI: #{doi} and added to your ORCID profile."
              {:error, e} when is_binary(e) -> "Successfully published DOI: #{doi}\n#{e}"
              _ -> "Successfully published DOI: #{doi}"
            end

          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, flash_message)

        doi = e(deposit, "metadata", "prereserve_doi", "doi", nil) ->
          doi = "https://doi.org/#{doi}"

          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(
            :info,
            l(
              "Draft created with DOI: %{doi} (but not published, you can edit the draft on %{platform_name} and publish it from there)",
              doi: doi,
              platform_name: api_type
            )
          )

        true ->
          Bonfire.UI.Common.OpenModalLive.close()

          socket
          |> assign(submitting: false)
          |> assign_flash(:info, "Draft created")
      end
    else
      {:error, :publish_failed} ->
        socket
        |> assign(submitting: false)
        |> assign_error(
          "Failed to publish to Zenodo. Please check your metadata (especially ORCID IDs) and try again."
        )

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
end
