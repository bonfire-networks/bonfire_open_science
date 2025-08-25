defmodule Bonfire.OpenScience.DOICoauthorNotifications do
  @moduledoc """
  Module for sending DM notifications to thread participants after DOI publication.

  When a DOI is published on Zenodo, this module automatically sends direct messages
  to thread participants who don't have ORCID IDs listed, asking them to provide
  their ORCID for proper attribution.
  """

  use Bonfire.Common.Utils
  alias Bonfire.Messages
  alias Bonfire.Social.Threads

  @doc """
  Sends DM notifications to thread participants without ORCID after DOI publication.

  ## Parameters
  - current_user: The user who published the DOI
  - post: The post that was archived/published
  - doi: The generated DOI string
  - creators: List of creators with their metadata (including ORCID if present)

  ## Examples
      iex> notify_coauthors_after_doi_publish(user, post, "10.5281/zenodo.123456", creators)
      :ok
  """
  def notify_coauthors_after_doi_publish(current_user, post, doi, creators) do
    debug("Starting DOI co-author notifications for DOI: #{doi}")

    # Get thread participants
    thread_id = e(post, :replied, :thread_id, nil) || id(post)

    if thread_id do
      case Threads.list_participants(post, thread_id,
             current_user: current_user,
             limit: 20
           ) do
        participants when is_list(participants) and participants != [] ->
          # Filter participants without ORCID
          recipients_without_orcid =
            filter_participants_without_orcid(participants, creators, current_user)

          debug("Found #{length(recipients_without_orcid)} participants without ORCID to notify")

          # Send DM to each participant
          Enum.each(recipients_without_orcid, fn participant ->
            send_doi_notification_dm(current_user, participant, post, doi)
          end)

        _ ->
          debug("No thread participants found or participants list is empty")
      end
    else
      debug("No thread ID found for post")
    end

    :ok
  end

  @doc """
  Filters thread participants to only include those without ORCID IDs.

  Excludes:
  - The current user (publisher)
  - Participants who already have ORCID listed in creators
  """
  defp filter_participants_without_orcid(participants, creators, current_user) do
    # Get list of creator IDs that already have ORCID
    creators_with_orcid =
      creators
      |> Enum.filter(fn c -> c["orcid"] && c["orcid"] != "" end)
      |> Enum.map(fn c -> c["id"] end)
      |> MapSet.new()

    debug("Creators with ORCID: #{inspect(creators_with_orcid)}")

    participants
    |> Enum.reject(fn participant ->
      participant_id = id(participant)

      # Exclude current user and those with ORCID
      exclude_current = participant_id == id(current_user)
      exclude_has_orcid = MapSet.member?(creators_with_orcid, participant_id)

      debug(
        "Participant #{participant_id}: exclude_current=#{exclude_current}, exclude_has_orcid=#{exclude_has_orcid}"
      )

      exclude_current || exclude_has_orcid
    end)
  end

  @doc """
  Sends a DM to a participant requesting their ORCID ID.
  """
  defp send_doi_notification_dm(sender, recipient, post, doi) do
    title = e(post, :post_content, :name, nil) || "Untitled"
    sender_name = e(sender, :profile, :name, nil) || e(sender, :character, :username, "someone")
    instance_url = Bonfire.Common.URIs.base_uri() |> to_string()

    message_content = """
    Hi! This is an automatic message sent in behalf of #{sender_name}.
    #{sender_name} has just published the discussion "#{title}" on Zenodo with DOI: #{doi}
    You were included as a co-author since you participated in the thread.
    If you have an ORCID ID, please share it so it can be added to the publication metadata. This will help properly attribute your contribution and link it to your academic profile.
    You can [visit this link](#{instance_url}/open_science/orcid_link/#{id(post)}?doi=#{URI.encode(doi)}) to add your ORCID to the publication.
    You can add your ORCID to your Bonfire profile settings for future publications

    View the publication: #{doi}

    Thank you for your contribution to this research!
    """

    debug("Sending DM notification to #{id(recipient)} about DOI: #{doi}")

    case Messages.send(
           sender,
           %{
             post_content: %{
               html_body: message_content
             }
           },
           [id(recipient)]
         ) do
      {:ok, _message} ->
        debug("Successfully sent DOI notification DM to #{id(recipient)}")
        :ok

      {:error, error} ->
        error("Failed to send DOI notification DM to #{id(recipient)}: #{inspect(error)}")
        {:error, error}
    end
  end
end
