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
      {:ok, "Successfully sent DOI notification DM to recipient_id"}
  """
  def notify_coauthors_after_doi_publish(current_user, post, doi, creators, title \\ nil) do
    debug("Starting DOI co-author notifications for DOI: #{doi}")

    # Use creators list directly
    recipients_without_orcid =
      filter_participants_without_orcid(creators, id(current_user))

    if recipients_without_orcid != [] do
      debug(length(recipients_without_orcid), "Found participants without ORCID to notify")

      # Send DM to each participant
      Enum.map(recipients_without_orcid, fn recipient ->
        send_doi_notification_dm(current_user, recipient, post, doi, title)
      end)
      |> Enums.all_oks_or_error()
    else
      {:error, info("No participants need to be notified")}
    end
  end

  @doc """
  Filters thread participants to only include those without ORCID IDs.

  Excludes:
  - The current user (publisher)
  - Participants who already have ORCID listed in creators
  """
  defp filter_participants_without_orcid(creators, current_user_id) do
    creators
    |> Enum.reject(fn c ->
      c["id"] == current_user_id or (c["orcid"] && c["orcid"] != "")
    end)
  end

  @doc """
  Sends a DM to a participant requesting their ORCID ID.
  """
  defp send_doi_notification_dm(sender, recipient, post, doi, title) do
    title = title || e(post, :post_content, :name, nil) || "Untitled"

    sender_name =
      e(sender, :profile, :name, nil) || e(sender, :character, :username, l("someone"))

    instance_url = Bonfire.Common.URIs.base_uri() |> to_string()

    # TODO: give an option to opt-out
    message_content = """
    Hi! This is an automated message sent by a Open Science Network instance of Bonfire on behalf of #{sender_name}.

    I have just archived the discussion "#{title}" with DOI: [#{doi}](#{doi}) and included you as a co-author since you participated in the thread. 

    If you are a researcher and have an ORCID ID, please [visit this link](#{instance_url}/open_science/orcid_link/#{id(post)}/add/#{id(recipient)}?name=#{URI.encode(recipient["name"])}) to add it to the publication metadata. This will help properly attribute your contribution and link it to your academic profile.

    If you're an Open Science Network user, you can also link your ORCID in your profile settings so it is automatically included in future publications.

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
        {:ok, debug("Successfully sent DOI notification DM to #{id(recipient)}")}

      {:error, error} ->
        error(error, "Failed to send DOI notification DM to #{id(recipient)}")
    end
  end
end
