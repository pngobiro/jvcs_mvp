defmodule Judiciary.Repo.Migrations.CreateActivities do
  use Ecto.Migration

  def change do
    create table(:activities) do
      add :case_number, :string, null: false
      add :title, :string, null: false
      add :start_time, :utc_datetime, null: false
      add :status, :string, null: false, default: "pending"
      add :judge_name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:activities, [:case_number])
    create index(:activities, [:status])
  end
end
