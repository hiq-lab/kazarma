# SPDX-FileCopyrightText: 2020-2024 Technostructures
# SPDX-License-Identifier: AGPL-3.0-only
defmodule Kazarma.RoomTypes.GroupTest do
  @moduledoc false

  use Kazarma.DataCase

  import Kazarma.ActivityPub.Adapter
  import Kazarma.Matrix.Transaction
  import Kazarma.MatrixMocks

  alias Kazarma.Bridge
  alias MatrixAppService.Bridge.Room
  alias MatrixAppService.Event

  describe "register_room/3 — registering a Matrix room as a Fediverse Group" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    test "it creates entries in bridge_rooms and bridge_users" do
      assert {:ok, %Room{}} =
               Kazarma.RoomType.Group.register_room(
                 "!myroom:kazarma",
                 "mygroup",
                 "@alice:kazarma"
               )

      # bridge_rooms: room type is :group with correct handle and AP ID
      assert [
               %Room{
                 local_id: "!myroom:kazarma",
                 remote_id: "http://kazarma/-/_grp_mygroup",
                 data: %{
                   "type" => "group",
                   "handle" => "mygroup",
                   "ap_data" => %{
                     "type" => "Group",
                     "preferredUsername" => "_grp_mygroup",
                     "id" => "http://kazarma/-/_grp_mygroup"
                   }
                 }
               }
             ] = Bridge.list_rooms()

      # bridge_users: AP identity entry for the Group actor
      assert [
               %{
                 local_id: "!myroom:kazarma",
                 remote_id: "http://kazarma/-/_grp_mygroup",
                 data: %{
                   "ap_data" => %{
                     "type" => "Group",
                     "id" => "http://kazarma/-/_grp_mygroup"
                   }
                 }
               }
             ] = Bridge.list_users()
    end

    test "it returns {:error, :already_registered} when the handle is already taken" do
      {:ok, _} =
        Kazarma.RoomType.Group.register_room("!myroom:kazarma", "mygroup", "@alice:kazarma")

      assert {:error, :already_registered} =
               Kazarma.RoomType.Group.register_room(
                 "!myroom:kazarma",
                 "mygroup",
                 "@alice:kazarma"
               )
    end
  end

  describe "new_event/1 — Matrix message in a Group room is bridged to AP followers" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    setup do
      {:ok, keys} = ActivityPub.Safety.Keys.generate_rsa_pem()

      ap_data = %{
        "preferredUsername" => "_grp_mygroup",
        "id" => "http://kazarma/-/_grp_mygroup",
        "type" => "Group",
        "name" => "mygroup",
        "followers" => "http://kazarma/-/_grp_mygroup/followers",
        "following" => "http://kazarma/-/_grp_mygroup/following",
        "inbox" => "http://kazarma/-/_grp_mygroup/inbox",
        "outbox" => "http://kazarma/-/_grp_mygroup/outbox",
        "manuallyApprovesFollowers" => false,
        "endpoints" => %{"sharedInbox" => "http://kazarma/shared_inbox"}
      }

      {:ok, _room} =
        Bridge.create_room(%{
          local_id: "!myroom:kazarma",
          remote_id: "http://kazarma/-/_grp_mygroup",
          data: %{type: :group, handle: "mygroup", ap_data: ap_data, keys: keys}
        })

      {:ok, _user} =
        Bridge.create_user(%{
          local_id: "!myroom:kazarma",
          remote_id: "http://kazarma/-/_grp_mygroup",
          data: %{"ap_data" => ap_data, "keys" => keys}
        })

      :ok
    end

    def group_message_event_fixture do
      %Event{
        sender: "@alice:kazarma",
        room_id: "!myroom:kazarma",
        type: "m.room.message",
        content: %{"msgtype" => "m.text", "body" => "Hello Fediverse from Matrix!"}
      }
    end

    test "it creates an AP Note from the Group actor addressed to followers and the public" do
      # sender_ap_ids/1 calls get_actor(matrix_id:) which tries to fetch the sender profile
      Kazarma.Matrix.TestClient
      |> expect_get_profile_not_found("@alice:kazarma")

      Kazarma.ActivityPub.TestServer
      |> expect(:create, fn
        %{
          actor: %ActivityPub.Actor{
            ap_id: "http://kazarma/-/_grp_mygroup",
            data: %{"type" => "Group", "preferredUsername" => "_grp_mygroup"}
          },
          object: %{
            "content" => "Hello Fediverse from Matrix!",
            "type" => "Note",
            "to" => ["https://www.w3.org/ns/activitystreams#Public", _followers_url]
          },
          to: ["https://www.w3.org/ns/activitystreams#Public", _followers_url2]
        } ->
          {:ok,
           %{object: %ActivityPub.Object{data: %{"id" => "http://kazarma/-/_grp_mygroup/Note/1"}}}}
      end)

      assert :ok == new_event(group_message_event_fixture())
    end
  end

  describe "handle_activity/1 — Follow from AP actor to Group triggers Accept" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    setup do
      {:ok, keys} = ActivityPub.Safety.Keys.generate_rsa_pem()

      ap_data = %{
        "preferredUsername" => "_grp_mygroup",
        "id" => "http://kazarma/-/_grp_mygroup",
        "type" => "Group",
        "name" => "mygroup",
        "followers" => "http://kazarma/-/_grp_mygroup/followers",
        "following" => "http://kazarma/-/_grp_mygroup/following",
        "inbox" => "http://kazarma/-/_grp_mygroup/inbox",
        "outbox" => "http://kazarma/-/_grp_mygroup/outbox",
        "manuallyApprovesFollowers" => false,
        "endpoints" => %{"sharedInbox" => "http://kazarma/shared_inbox"}
      }

      {:ok, _room} =
        Bridge.create_room(%{
          local_id: "!myroom:kazarma",
          remote_id: "http://kazarma/-/_grp_mygroup",
          data: %{type: :group, handle: "mygroup", ap_data: ap_data, keys: keys}
        })

      {:ok, _user} =
        Bridge.create_user(%{
          local_id: "!myroom:kazarma",
          remote_id: "http://kazarma/-/_grp_mygroup",
          data: %{"ap_data" => ap_data, "keys" => keys}
        })

      # Insert the remote follower actor
      {:ok, _follower_obj} =
        ActivityPub.Object.do_insert(%{
          "data" => %{
            "type" => "Person",
            "name" => "Alice",
            "preferredUsername" => "alice",
            "url" => "http://pleroma.com/pub/actors/alice",
            "id" => "http://pleroma.com/pub/actors/alice",
            "inbox" => "http://pleroma.com/pub/actors/alice/inbox",
            "followers" => "http://pleroma.com/pub/actors/alice/followers",
            "following" => "http://pleroma.com/pub/actors/alice/following",
            "endpoints" => %{"sharedInbox" => "http://pleroma.com/shared_inbox"}
          },
          "local" => false,
          "public" => true,
          "actor" => "http://pleroma.com/pub/actors/alice"
        })

      :ok
    end

    def follow_group_fixture do
      %ActivityPub.Object{
        data: %{
          "type" => "Follow",
          "actor" => "http://pleroma.com/pub/actors/alice",
          "object" => "http://kazarma/-/_grp_mygroup",
          "id" => "http://pleroma.com/activities/follow-1",
          "to" => ["http://kazarma/-/_grp_mygroup"]
        }
      }
    end

    test "it sends Accept{Follow} back to the follower" do
      Kazarma.ActivityPub.TestServer
      |> expect(:accept, fn
        %{
          to: ["http://pleroma.com/pub/actors/alice"],
          actor: %ActivityPub.Actor{
            ap_id: "http://kazarma/-/_grp_mygroup",
            data: %{"type" => "Group"}
          },
          object: "http://pleroma.com/activities/follow-1"
        } ->
          {:ok, %{}}
      end)

      assert :ok == handle_activity(follow_group_fixture())
    end
  end
end
