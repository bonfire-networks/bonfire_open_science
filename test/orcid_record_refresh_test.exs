# SPDX-License-Identifier: AGPL-3.0-only
defmodule Bonfire.OpenScience.OrcidRecordRefreshTest do
  @moduledoc """
  An ORCID profile is a Media shared by every user who links that ORCID URL (deduped by canonical URL). Refreshing its record stores data fetched from ORCID, so it works for any user, not only the Media's creator.
  """
  use Bonfire.OpenScience.DataCase, async: false
  @moduletag :backend

  import Tesla.Mock

  alias Bonfire.Files.Media
  alias Bonfire.OpenScience.ORCID

  setup do
    mock(fn %{method: :get, url: "https://pub.orcid.org/" <> _} ->
      %Tesla.Env{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: Jason.encode!(%{"person" => %{"name" => %{"given-names" => %{"value" => "Jo"}}}})
      }
    end)

    creator = fake_user!()
    url = "https://orcid.org/0000-0002-1825-#{Enum.random(1000..9999)}"

    {:ok, media} =
      Media.insert(creator, url, %{media_type: "orcid", size: 0}, %{
        url: url,
        metadata: %{"sub" => "0000-0002-1825-0097", "access_token" => "tok"}
      })

    {:ok, creator: creator, media: media}
  end

  test "the creator can refresh the record (control)", %{creator: creator, media: media} do
    assert [%Media{} = refreshed] = ORCID.fetch_orcid_record(creator, media)
    assert refreshed.metadata["orcid"]["person"]
  end

  test "another user can refresh the record of a shared ORCID media", %{media: media} do
    other = fake_user!()

    assert [%Media{} = refreshed] = ORCID.fetch_orcid_record(other, media)
    assert refreshed.metadata["orcid"]["person"]
  end
end
