defmodule Judiciary.Repo.Migrations.AddVirtualRoomToActivities do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :virtual_room_id, references(:virtual_rooms, on_delete: :nothing)
    end

    create index(:activities, [:virtual_room_id])
  end
end
