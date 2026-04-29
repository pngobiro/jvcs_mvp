defmodule Judiciary.Court.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "activities" do
    field :case_number, :string
    field :title, :string
    field :start_time, :utc_datetime
    field :status, :string, default: "pending"
    field :judge_name, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [:case_number, :title, :start_time, :status, :judge_name])
    |> validate_required([:case_number, :title, :start_time, :judge_name])
  end
end
