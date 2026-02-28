# SPDX-FileCopyrightText: 2020-2024 Technostructures
# SPDX-License-Identifier: AGPL-3.0-only
defmodule Kazarma.RoomType.Group do
  @moduledoc """
  RoomType for Matrix rooms exposed as FEP-1b12 ActivityPub Group actors.

  When a Matrix room is registered as a Group (via `!kazarma group <handle>`):
  - It gets an AP `Group` actor served at `https://{domain}/-/_grp_{handle}`
  - Remote Fediverse users can follow it via WebFinger `acct:_grp_{handle}@{domain}`
  - Messages posted in the Matrix room are forwarded to AP followers as `Create{Note}` activities
  - Posts from Fediverse actors to the Group are bridged into the Matrix room and announced to followers

  The Group actor stores its AP data (keys, actor JSON) in the `bridge_rooms` table
  alongside the room type metadata.
  """
  alias Kazarma.ActivityPub.Activity
  alias Kazarma.Bridge
  alias Kazarma.Matrix.Client
  alias MatrixAppService.Bridge.Room

  require Logger

  @doc """
  Called when a Fediverse actor posts to the Group actor. Bridges the message into
  the Matrix room and announces it to the group's followers (FEP-1b12 forwarding).
  """
  def create_from_ap(
        %{
          data: %{"actor" => sender_ap_id} = activity_data,
          object: %ActivityPub.Object{data: object_data} = ap_object
        } = _activity
      ) do
    all_targets = List.wrap(activity_data["to"]) ++ List.wrap(Map.get(activity_data, "cc", []))

    with %Room{local_id: room_id, remote_id: group_ap_id} <- find_group_room(all_targets),
         %ActivityPub.Actor{} = group_actor <- get_group_actor_struct(group_ap_id),
         %{local_id: sender_matrix_id} <- Kazarma.Address.get_user(ap_id: sender_ap_id) do
      :ok = Client.join(sender_matrix_id, room_id)

      attachments = Map.get(object_data, "attachment")
      Activity.send_message_and_attachment(sender_matrix_id, room_id, object_data, attachments)

      announce_to_followers(group_actor, ap_object)

      :ok
    else
      nil ->
        Logger.error(
          "Group create_from_ap: could not find group room or sender for #{inspect(all_targets)}"
        )

        :error

      error ->
        Logger.error("Group create_from_ap failed: #{inspect(error)}")
        :error
    end
  end

  @doc """
  Called by `Kazarma.Matrix.Transaction` when a Matrix message is received in a
  Group-type room. Creates an AP Note from the Group actor and delivers it to followers.
  """
  def create_from_event(
        event,
        %Room{remote_id: group_ap_id} = _room
      ) do
    Logger.debug("Group room: forwarding Matrix message to AP followers")

    with %ActivityPub.Actor{} = group_actor <- get_group_actor_struct(group_ap_id),
         {:ok, activity} <-
           Activity.create_from_event(
             event,
             sender: group_actor,
             to: [
               "https://www.w3.org/ns/activitystreams#Public",
               group_actor.data["followers"]
             ],
             cc: sender_ap_ids(event.sender)
           ) do
      Kazarma.Logger.log_bridged_activity(activity,
        room_type: :group,
        room_id: event.room_id,
        obj_type: "Note"
      )

      :ok
    else
      nil ->
        Logger.error("Group create_from_event: could not find group actor for #{group_ap_id}")
        :error

      error ->
        Logger.error("Group create_from_event failed: #{inspect(error)}")
        :error
    end
  end

  @doc """
  Registers a Matrix room as a Fediverse Group with the given handle.
  Creates the AP Group actor data and stores it in bridge_rooms.

  The Group will be discoverable at `@_grp_{handle}@{domain}` on the Fediverse.
  """
  def register_room(room_id, handle, _user_id) do
    ap_id = build_group_ap_id(handle)

    case Bridge.get_room_by_remote_id(ap_id) do
      %Room{} ->
        Logger.info("Group room already registered: #{ap_id}")
        {:error, :already_registered}

      nil ->
        {:ok, keys} = ActivityPub.Safety.Keys.generate_rsa_pem()
        ap_data = Kazarma.ActivityPub.Actor.build_group_actor_data(handle, ap_id)

        with {:ok, room} <-
               Bridge.create_room(%{
                 local_id: room_id,
                 remote_id: ap_id,
                 data: %{
                   type: :group,
                   handle: handle,
                   ap_data: ap_data,
                   keys: keys
                 }
               }),
             {:ok, _user} <-
               Bridge.create_user(%{
                 local_id: room_id,
                 remote_id: ap_id,
                 data: %{"ap_data" => ap_data, "keys" => keys}
               }) do
          Logger.info(
            "Registered Matrix room #{room_id} as AP Group @_grp_#{handle}@#{Kazarma.Address.ap_domain()}"
          )

          {:ok, room}
        else
          error ->
            Logger.error("Failed to register group room: #{inspect(error)}")
            error
        end
    end
  end

  @doc """
  Resolves a Group AP ID to an `%ActivityPub.Actor{}` using the bridge_users entry.
  This is used by `Address.get_actor/1` via `Bridge.get_user_by_remote_id/1`.
  """
  def get_actor_from_user_record(%{data: %{"ap_data" => ap_data, "keys" => keys}}) do
    Kazarma.ActivityPub.Actor.build_actor_from_data(ap_data, keys)
  end

  @doc """
  Resolves a Group AP ID to an `%ActivityPub.Actor{}` struct using stored bridge data.
  Returns nil if the group is not registered.
  """
  def get_group_actor_struct(group_ap_id) do
    case Bridge.get_room_by_remote_id(group_ap_id) do
      %Room{data: %{"ap_data" => ap_data, "keys" => keys}} ->
        Kazarma.ActivityPub.Actor.build_actor_from_data(ap_data, keys)

      _ ->
        nil
    end
  end

  defp find_group_room(ap_ids) do
    Enum.find_value(ap_ids, fn ap_id ->
      case Bridge.get_room_by_remote_id(ap_id) do
        %Room{data: %{"type" => "group"}} = room -> room
        _ -> nil
      end
    end)
  end

  defp announce_to_followers(group_actor, ap_object) do
    case Kazarma.ActivityPub.announce(%{actor: group_actor, object: ap_object}) do
      {:ok, _} ->
        :ok

      error ->
        Logger.warning("Group announce_to_followers failed: #{inspect(error)}")
        :ok
    end
  end

  # Returns the AP ID URL for a group handle (localpart = "_grp_{handle}")
  defp build_group_ap_id(handle) do
    KazarmaWeb.Router.Helpers.activity_pub_url(
      KazarmaWeb.Endpoint,
      :actor,
      "-",
      "_grp_#{handle}"
    )
  end

  # Returns a list with the sender's AP ID if they have an AP actor, else empty list
  defp sender_ap_ids(sender_matrix_id) do
    case Kazarma.Address.get_actor(matrix_id: sender_matrix_id) do
      %ActivityPub.Actor{ap_id: ap_id} -> [ap_id]
      _ -> []
    end
  end
end
