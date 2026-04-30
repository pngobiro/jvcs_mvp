defmodule Judiciary.Court do
  @moduledoc """
  The Court context.
  """

  import Ecto.Query, warn: false
  alias Judiciary.Repo

  alias Judiciary.Court.Activity
  alias Judiciary.Court.CourtHouse

  def list_courts do
    Repo.all(CourtHouse)
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
    |> Repo.preload([:court, :judge])
  end

  def get_activity!(id) do
    Activity
    |> Repo.get!(id)
    |> Repo.preload([:court, :judge])
  end

  def create_activity(attrs \\ %{}) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, activity} -> {:ok, Repo.preload(activity, [:court, :judge])}
      error -> error
    end
  end

  def update_activity(%Activity{} = activity, attrs) do
    activity
    |> Activity.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, activity} ->
        activity = Repo.preload(activity, [:court, :judge])
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
