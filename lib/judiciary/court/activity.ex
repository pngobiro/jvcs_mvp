defmodule Judiciary.Court.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "activities" do
    field :case_number, :string
    field :title, :string
    field :start_time, :utc_datetime
    field :status, :string, default: "pending"
    field :judge_name, :string
    field :link, :string
    field :recording_url, :string
    field :transcript_url, :string

    belongs_to :court, Judiciary.Court.CourtHouse
    belongs_to :judge, Judiciary.Accounts.User
    belongs_to :virtual_room, Judiciary.Court.VirtualRoom
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:case_number, :title, :start_time, :status, :judge_name, :court_id, :judge_id, :virtual_room_id, :link, :recording_url, :transcript_url])
    |> validate_required([:case_number, :title, :start_time, :judge_name])
  end
end
