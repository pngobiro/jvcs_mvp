defmodule Judiciary.Repo.Migrations.AddRecordingUrlToActivities do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :recording_url, :text
    end
  end
end
