defmodule Bonfire.OpenScience.ZenodoDepositAuthorizationTest do
  @moduledoc """
  The Zenodo metadata form edits a deposit or publishes a new version of it, using the caller's token or else the instance's token. Only the user who archived the post may do that: a signed-in user who is not the deposit's creator and opens the post must not cause any write to the deposit API.
  """
  use Bonfire.OpenScience.ConnCase, async: false
  @moduletag :ui

  import Bonfire.Common.Enums, only: [id: 1]
  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  setup do
    previous_token = System.get_env("INVENIO_RDM_PERSONAL_TOKEN")
    System.put_env("INVENIO_RDM_PERSONAL_TOKEN", "test-token")

    on_exit(fn ->
      if previous_token,
        do: System.put_env("INVENIO_RDM_PERSONAL_TOKEN", previous_token),
        else: System.delete_env("INVENIO_RDM_PERSONAL_TOKEN")
    end)

    publisher_account = fake_account!()
    publisher = fake_user!(publisher_account)
    stranger_account = fake_account!()
    stranger = fake_user!(stranger_account)

    post =
      fake_post!(publisher, "public", %{post_content: %{html_body: "<p>a publication</p>"}})

    deposit = %{
      "id" => 123_456,
      "state" => "unsubmitted",
      "metadata" => %{
        "title" => "A publication",
        "description" => "A description that is long enough",
        "creators" => [%{"id" => id(publisher), "name" => "Publisher"}]
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

    Repatch.patch(Req, :get, [mode: :shared], fn url, _opts ->
      send(test_pid, {:zenodo_read, url})
      {:ok, %{status: 200, body: deposit}}
    end)

    for fun <- [:put, :post] do
      Repatch.patch(Req, fun, [mode: :shared], fn url, opts ->
        send(test_pid, {:zenodo_write, fun, url, opts})
        {:ok, %{status: 200, body: %{}}}
      end)
    end

    {:ok,
     post: post,
     publisher: publisher,
     publisher_account: publisher_account,
     stranger: stranger,
     stranger_account: stranger_account}
  end

  defp submit_form(conn, post, kind) when kind in ["edit", "version"] do
    {:ok, view, html} = live(conn, "/post/#{id(post)}")

    # the actions menu decides what the viewer may do only when it is opened
    html =
      case Regex.run(~r/id="([^"]*permitted_actions[^"]*)"/, html) do
        [_, menu_id] ->
          view |> with_target("##{menu_id}") |> render_hook("load", %{})
          render(view)

        _ ->
          html
      end

    # the form only shows once its modal is opened
    html =
      case Regex.run(~r/id="([^"]*zenodo_#{kind}_modal)"/, html) do
        [_, modal_id] ->
          view |> with_target("##{modal_id}") |> render_hook("open", %{})
          render(view)

        _ ->
          html
      end

    # the opened modal holds the form that the metadata component renders
    if html =~ ~s(id="metadata") do
      # the handler crashes after its Zenodo requests when the thread has no replies loaded, which exits the view; the requests sent so far are checked either way
      try do
        view
        |> element("form#metadata")
        |> render_submit(%{
          "metadata" => %{
            "title" => "Hijacked title",
            "description" => "A description that is long enough",
            "license" => "cc-by-4.0"
          },
          "creators" => %{"0" => %{"name" => "Someone"}}
        })
      catch
        :exit, _ -> :submitted
      end
    else
      :no_form
    end
  end

  test "the user who archived the post can edit the deposit metadata (control)", ctx do
    assert submit_form(
             conn(user: ctx.publisher, account: ctx.publisher_account),
             ctx.post,
             "edit"
           ) != :no_form

    assert_received {:zenodo_write, _, _url, _opts}
  end

  test "the user who archived the post can publish a new version (control)", ctx do
    assert submit_form(
             conn(user: ctx.publisher, account: ctx.publisher_account),
             ctx.post,
             "version"
           ) != :no_form

    assert_received {:zenodo_write, :post, "/records/123456/versions", _opts}
  end

  describe "a co-editor of the post who did not archive it" do
    setup ctx do
      coeditor_account = fake_account!()
      coeditor = fake_user!(coeditor_account)

      {:ok, acl} =
        Bonfire.Boundaries.Acls.get_or_create_object_custom_acl(ctx.post, ctx.publisher)

      Bonfire.Boundaries.Grants.grant(coeditor.id, acl.id, [:see, :read, :edit], true,
        current_user: ctx.publisher
      )

      {:ok, coeditor: coeditor, coeditor_account: coeditor_account}
    end

    test "cannot edit the deposit metadata", ctx do
      assert submit_form(
               conn(user: ctx.coeditor, account: ctx.coeditor_account),
               ctx.post,
               "edit"
             ) != :no_form

      refute_received {:zenodo_write, _, _url, _opts}
    end

    test "cannot publish a new version", ctx do
      assert submit_form(
               conn(user: ctx.coeditor, account: ctx.coeditor_account),
               ctx.post,
               "version"
             ) != :no_form

      refute_received {:zenodo_write, _, _url, _opts}
    end
  end

  test "a signed-in user who did not archive the post cannot edit the deposit metadata", ctx do
    submit_form(
      conn(user: ctx.stranger, account: ctx.stranger_account),
      ctx.post,
      "edit"
    )

    refute_received {:zenodo_write, _, _url, _opts}
  end

  test "a signed-in user who did not archive the post cannot publish a new version", ctx do
    submit_form(
      conn(user: ctx.stranger, account: ctx.stranger_account),
      ctx.post,
      "version"
    )

    refute_received {:zenodo_write, _, _url, _opts}
  end
end
