defmodule Judiciary.Repo.Migrations.CreateVirtualRooms do
  use Ecto.Migration

  def change do
    create table(:virtual_rooms) do
      add :name, :string, null: false
      add :type, :string, null: false # "chamber", "bench", "public"
      add :slug, :string, null: false
      add :court_id, references(:courts, on_delete: :nothing)
      add :presiding_officer_id, references(:users, on_delete: :nothing)
      add :bench_members, {:array, :integer}, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:virtual_rooms, [:slug])
    create index(:virtual_rooms, [:court_id])
    create index(:virtual_rooms, [:presiding_officer_id])
  end
end
