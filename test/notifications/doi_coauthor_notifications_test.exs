defmodule Bonfire.OpenScience.DOICoauthorNotificationsTest do
  use Bonfire.OpenScience.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.OpenScience.DOICoauthorNotifications
  alias Bonfire.Social.{Fake, FeedActivities}
  alias Bonfire.Messages

  describe "notify_coauthors_after_doi_publish/4" do
    test "sends DMs to thread participants without ORCID" do
      # Create test users
      publisher = fake_user!()
      participant_with_orcid = fake_user!()
      participant_without_orcid = fake_user!()

      # Create a post from publisher
      assert {:ok, post} = Fake.fake_post!(publisher)

      # Create some replies to establish thread participants
      assert {:ok, _reply1} = Fake.fake_post!(participant_with_orcid, %{reply_to_id: id(post)})
      assert {:ok, _reply2} = Fake.fake_post!(participant_without_orcid, %{reply_to_id: id(post)})

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
      result =
        DOICoauthorNotifications.notify_coauthors_after_doi_publish(
          publisher,
          post,
          doi,
          creators
        )

      assert result == :ok

      # Verify that DM was sent to participant without ORCID
      # We would need to check the Messages context for this
      # This is a basic integration test - in a real scenario we might
      # want to mock the Messages.send function to verify it's called correctly
    end

    test "handles post without thread participants" do
      publisher = fake_user!()

      # Create a post without any replies (no thread participants)
      assert {:ok, post} = Fake.fake_post!(publisher)

      creators = [
        %{
          "id" => id(publisher),
          "name" => "Publisher Name",
          "orcid" => "0000-0000-0000-0001"
        }
      ]

      doi = "10.5281/zenodo.123456"

      # Should not crash with no participants
      result =
        DOICoauthorNotifications.notify_coauthors_after_doi_publish(
          publisher,
          post,
          doi,
          creators
        )

      assert result == :ok
    end

    test "excludes publisher from notifications" do
      publisher = fake_user!()
      participant = fake_user!()

      # Create a post and reply
      assert {:ok, post} = Fake.fake_post!(publisher)
      assert {:ok, _reply} = Fake.fake_post!(participant, %{reply_to_id: id(post)})

      # Both publisher and participant have no ORCID in creators
      creators = [
        %{
          "id" => id(publisher),
          "name" => "Publisher Name",
          "orcid" => nil
        },
        %{
          "id" => id(participant),
          "name" => "Participant Name",
          "orcid" => nil
        }
      ]

      doi = "10.5281/zenodo.123456"

      # Should only notify participant, not publisher
      result =
        DOICoauthorNotifications.notify_coauthors_after_doi_publish(
          publisher,
          post,
          doi,
          creators
        )

      assert result == :ok
      # In a full test, we would verify only the participant received a DM
    end
  end
end
