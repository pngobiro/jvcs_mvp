defmodule Judiciary.Court.CourtHouse do
  use Ecto.Schema
  import Ecto.Changeset

  schema "courts" do
    field :name, :string
    field :code, :string
    field :link, :string

    has_many :activities, Judiciary.Court.Activity, foreign_key: :court_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(court, attrs) do
    court
    |> cast(attrs, [:name, :code, :link])
    |> validate_required([:name, :code])
    |> unique_constraint(:code)
  end
end
