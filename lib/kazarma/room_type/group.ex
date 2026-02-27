# SPDX-FileCopyrightText: 2020-2024 Technostructures
# SPDX-License-Identifier: AGPL-3.0-only
defmodule Kazarma.RoomType.Group do
  @moduledoc """
  RoomType for Matrix rooms exposed as FEP-1b12 ActivityPub Group actors.

  When a Matrix room is registered as a Group (via `!kazarma group <handle>`):
  - It gets an AP `Group` actor served at `https://{domain}/-/_grp_{handle}`
  - Remote Fediverse users can follow it via WebFinger `acct:_grp_{handle}@{domain}`
  - Messages posted in the Matrix room are forwarded to AP followers as `Create{Note}` activities

  The Group actor stores its AP data (keys, actor JSON) in the `bridge_rooms` table
  alongside the room type metadata.
  """
  alias Kazarma.ActivityPub.Activity
  alias Kazarma.Bridge
  alias MatrixAppService.Bridge.Room

  require Logger

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

        case Bridge.create_room(%{
               local_id: room_id,
               remote_id: ap_id,
               data: %{
                 type: :group,
                 handle: handle,
                 ap_data: ap_data,
                 keys: keys
               }
             }) do
          {:ok, room} ->
            Logger.info(
              "Registered Matrix room #{room_id} as AP Group @_grp_#{handle}@#{Kazarma.Address.ap_domain()}"
            )

            {:ok, room}

          error ->
            Logger.error("Failed to register group room: #{inspect(error)}")
            error
        end
    end
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
