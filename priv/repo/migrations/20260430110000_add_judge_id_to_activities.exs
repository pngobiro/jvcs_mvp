defmodule Judiciary.Repo.Migrations.AddJudgeIdToActivities do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :judge_id, references(:users, on_delete: :nilify_all)
    end

    create index(:activities, [:judge_id])
  end
end
