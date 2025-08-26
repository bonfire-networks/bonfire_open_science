defmodule Bonfire.OpenScience.DOICoauthorNotificationsTest do
  use Bonfire.OpenScience.DataCase, async: true

  alias Bonfire.OpenScience.DOICoauthorNotifications
  import Bonfire.Posts.Fake
  alias Bonfire.Messages

  describe "notify_coauthors_after_doi_publish/4" do
    test "sends DMs to thread participants without ORCID" do
      # Create test users
      publisher = fake_user!()
      participant_with_orcid = fake_user!()
      participant_without_orcid = fake_user!()
      excluded_participant = fake_user!()

      # Create a post from publisher
      assert post = fake_post!(publisher)

      # Create some replies to establish thread participants
      assert _reply1 =
               fake_post!(participant_with_orcid, "public", %{
                 reply_to_id: id(post),
                 post_content: %{html_body: "reply1"}
               })

      assert _reply2 =
               fake_post!(participant_without_orcid, "public", %{
                 reply_to_id: id(post),
                 post_content: %{html_body: "reply2"}
               })

      assert _reply3 =
               fake_post!(excluded_participant, "public", %{
                 reply_to_id: id(post),
                 post_content: %{html_body: "reply2"}
               })

      # Mock creators list - one with ORCID, one without
      creators = [
        %{
          "id" => id(publisher),
          "name" => "Publisher Name",
          "orcid" => "0000-0000-0000-0001"
        },
        %{
          "id" => id(participant_with_orcid),
          "name" => "Participant with ORCID",
          "orcid" => "0000-0000-0000-0002"
        },
        %{
          "id" => id(participant_without_orcid),
          "name" => "Participant without ORCID",
          "orcid" => nil
        }
      ]

      doi = "10.5281/zenodo.123456"

      # Test the notification function
      assert {:ok, _} =
               DOICoauthorNotifications.notify_coauthors_after_doi_publish(
                 publisher,
                 post,
                 doi,
                 creators
               )

      # Verify that DM was sent to participant without ORCID
      %{edges: dms_for_participant_without_orcid} = Messages.list(participant_without_orcid)

      assert Enum.any?(dms_for_participant_without_orcid, fn dm ->
               String.contains?(dm.activity.object.post_content.html_body, doi)
             end)

      # Verify that participant with ORCID was not notified
      %{edges: dms_for_participant_with_orcid} = Messages.list(participant_with_orcid)

      refute Enum.any?(dms_for_participant_with_orcid, fn dm ->
               String.contains?(dm.activity.object.post_content.html_body, doi)
             end)

      # TODO: Verify that publisher was not notified
      # %{edges: dms_for_publisher} = Messages.list(publisher, publisher)

      # refute Enum.any?(dms_for_publisher, fn dm ->
      #          String.contains?(dm.activity.object.post_content.html_body, doi)
      #        end)

      # Verify that excluded participant was not notified
      %{edges: dms_for_excluded_participant} = Messages.list(excluded_participant)

      refute Enum.any?(dms_for_excluded_participant, fn dm ->
               String.contains?(dm.activity.object.post_content.html_body, doi)
             end)
    end

    # test "handles post without thread participants" do
    #   publisher = fake_user!()

    #   # Create a post without any replies (no thread participants)
    #   assert post = fake_post!(publisher)

    #   creators = [
    #     %{
    #       "id" => id(publisher),
    #       "name" => "Publisher Name",
    #       "orcid" => "0000-0000-0000-0001"
    #     }
    #   ]

    #   doi = "10.5281/zenodo.123456"

    #   # Should not crash with no participants
    #   result =
    #     DOICoauthorNotifications.notify_coauthors_after_doi_publish(
    #       publisher,
    #       post,
    #       doi,
    #       creators
    #     )

    #   assert result == :ok
    # end
  end
end
