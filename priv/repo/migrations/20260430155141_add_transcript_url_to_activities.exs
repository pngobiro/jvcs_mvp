defmodule Judiciary.Repo.Migrations.AddTranscriptUrlToActivities do
  use Ecto.Migration

  def change do
    alter table(:activities) do
      add :transcript_url, :text
    end
  end
end
