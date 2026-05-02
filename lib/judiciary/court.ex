defmodule Judiciary.Court do
  @moduledoc """
  The Court context.
  """

  import Ecto.Query, warn: false
  alias Judiciary.Repo

  alias Judiciary.Court.Activity
  alias Judiciary.Court.CourtHouse
  alias Judiciary.Court.VirtualRoom

  def list_courts do
    Repo.all(CourtHouse)
  end

  # ... (existing functions)

  def list_virtual_rooms do
    Repo.all(VirtualRoom)
    |> Repo.preload([:court, :presiding_officer])
  end

  def get_virtual_room!(id), do: Repo.get!(VirtualRoom, id) |> Repo.preload([:court, :presiding_officer])

  def get_virtual_room_by_slug(slug) do
    Activity
    |> order_by(desc: :start_time)
    |> then(fn activity_query ->
      Repo.get_by(VirtualRoom, slug: slug)
      |> case do
        nil -> nil
        room -> Repo.preload(room, [:court, :presiding_officer, activities: activity_query])
      end
    end)
  end

  def create_virtual_room(attrs \\ %{}) do
    %VirtualRoom{}
    |> VirtualRoom.changeset(attrs)
    |> Repo.insert()
  end

  def update_virtual_room(%VirtualRoom{} = room, attrs) do
    room
    |> VirtualRoom.changeset(attrs)
    |> Repo.update()
  end

  def delete_virtual_room(%VirtualRoom{} = room) do
    Repo.delete(room)
  end

  def change_virtual_room(%VirtualRoom{} = room, attrs \\ %{}) do
    VirtualRoom.changeset(room, attrs)
  end

  def get_court!(id), do: Repo.get!(CourtHouse, id)

  def create_court(attrs \\ %{}) do
    %CourtHouse{}
    |> CourtHouse.changeset(attrs)
    |> Repo.insert()
  end

  def update_court(%CourtHouse{} = court, attrs) do
    court
    |> CourtHouse.changeset(attrs)
    |> Repo.update()
  end

  def delete_court(%CourtHouse{} = court) do
    Repo.delete(court)
  end

  def change_court(%CourtHouse{} = court, attrs \\ %{}) do
    CourtHouse.changeset(court, attrs)
  end

  def list_activities do
    Activity
    |> Repo.all()
    |> Repo.preload([:court, :judge, :virtual_room])
  end

  def get_activity(id) do
    Activity
    |> Repo.get(id)
    |> case do
      nil -> nil
      activity -> Repo.preload(activity, [:court, :judge, :virtual_room])
    end
  end

  def get_activity!(id) do
    Activity
    |> Repo.get!(id)
    |> Repo.preload([:court, :judge, :virtual_room])
  end

  def create_activity(attrs \\ %{}) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, activity} -> {:ok, Repo.preload(activity, [:court, :judge, :virtual_room])}
      error -> error
    end
  end

  def update_activity(%Activity{} = activity, attrs) do
    activity
    |> Activity.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, activity} ->
        activity = Repo.preload(activity, [:court, :judge, :virtual_room])
        Phoenix.PubSub.broadcast(Judiciary.PubSub, "activities", {:activity_updated, activity})
        {:ok, activity}

      error ->
        error
    end
  end

  def delete_activity(%Activity{} = activity) do
    Repo.delete(activity)
  end

  def change_activity(%Activity{} = activity, attrs \\ %{}) do
    Activity.changeset(activity, attrs)
  end
end
