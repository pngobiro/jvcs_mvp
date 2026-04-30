defmodule Judiciary.Repo.Migrations.AddCourtsAndLinks do
  use Ecto.Migration

  def change do
    create table(:courts) do
      add :name, :string, null: false
      add :code, :string, null: false
      add :link, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:courts, [:code])

    alter table(:activities) do
      add :court_id, references(:courts, on_delete: :nilify_all)
      add :link, :string
    end

    create index(:activities, [:court_id])

    alter table(:users) do
      add :name, :string
      add :role, :string
      add :link, :string
    end
  end
end
