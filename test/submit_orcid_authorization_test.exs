defmodule Bonfire.OpenScience.SubmitOrcidAuthorizationTest do
  @moduledoc """
  A visitor with no session reaches `submit_orcid` through `GET /LiveHandler/<Module>/<event>`. Only a signed-in user may set an ORCID, and only on their own creator entry of a deposit, because the update is sent to Zenodo with the publisher's token.
  """
  use Bonfire.OpenScience.DataCase, async: false
  @moduletag :backend

  import Phoenix.ConnTest, only: [get: 2, build_conn: 0]
  import Bonfire.UI.Common.Testing.Helpers, only: [conn: 1]
  import Bonfire.Posts.Fake, only: [fake_post!: 3]
  @endpoint Application.compile_env!(:bonfire, :endpoint_module)

  @orcid "0000-0002-1825-0097"
  @path "/LiveHandler/Bonfire.OpenScience.Web.OrcidLinkLive/submit_orcid"

  setup do
    previous_token = System.get_env("INVENIO_RDM_PERSONAL_TOKEN")
    System.put_env("INVENIO_RDM_PERSONAL_TOKEN", "test-token")

    on_exit(fn ->
      if previous_token,
        do: System.put_env("INVENIO_RDM_PERSONAL_TOKEN", previous_token),
        else: System.delete_env("INVENIO_RDM_PERSONAL_TOKEN")
    end)

    account = fake_account!()
    publisher = fake_user!(account)
    coauthor_account = fake_account!()
    coauthor = fake_user!(coauthor_account)

    post =
      fake_post!(publisher, "public", %{post_content: %{html_body: "<p>a publication</p>"}})

    deposit = %{
      "id" => 123_456,
      "state" => "unsubmitted",
      "metadata" => %{
        "title" => "A publication",
        "creators" => [
          %{"id" => id(publisher), "name" => "Publisher"},
          %{"id" => id(coauthor), "name" => "Coauthor"}
        ]
      }
    }

    {:ok, _media} =
      Bonfire.OpenScience.save_as_attached_media(
        publisher,
        "https://zenodo.local/records/123456",
        %{"zenodo" => deposit},
        post
      )

    # record any write to the deposit API instead of sending it
    test_pid = self()

    for fun <- [:put, :post] do
      Repatch.patch(Req, fun, fn url, opts ->
        send(test_pid, {:zenodo_write, fun, url, opts})
        {:ok, %{status: 200, body: %{}}}
      end)
    end

    {:ok,
     post: post,
     publisher: publisher,
     publisher_account: account,
     coauthor: coauthor,
     coauthor_account: coauthor_account}
  end

  defp submit_path(post, user_id),
    do: "#{@path}?orcid_id=#{@orcid}&object_id=#{id(post)}&user_id=#{user_id}"

  # `/LiveHandler` never acts as the session's user, so the signed-in case is the event of a live socket
  test "a signed-in creator can set the ORCID on their own entry", ctx do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        __context__: %{current_user: ctx.coauthor, current_account: ctx.coauthor_account}
      }
    }

    Bonfire.OpenScience.Web.OrcidLinkLive.handle_event(
      "submit_orcid",
      %{"orcid_id" => @orcid, "object_id" => id(ctx.post), "user_id" => id(ctx.coauthor)},
      socket
    )

    assert_received {:zenodo_write, :put, _url, _opts}
  end

  test "a guest cannot set an ORCID on a creator entry", ctx do
    get(build_conn(), submit_path(ctx.post, id(ctx.coauthor)))

    refute_received {:zenodo_write, _, _url, _opts}
  end

  test "a signed-in user cannot set the ORCID on another creator's entry", ctx do
    get(
      conn(user: ctx.coauthor, account: ctx.coauthor_account),
      submit_path(ctx.post, id(ctx.publisher))
    )

    refute_received {:zenodo_write, _, _url, _opts}
  end
end
