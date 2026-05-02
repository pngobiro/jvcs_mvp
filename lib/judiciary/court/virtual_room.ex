defmodule Judiciary.Court.VirtualRoom do
  use Ecto.Schema
  import Ecto.Changeset

  schema "virtual_rooms" do
    field :name, :string
    field :type, :string # "chamber", "bench", "public"
    field :slug, :string
    field :bench_members, {:array, :integer}, default: []

    belongs_to :court, Judiciary.Court.CourtHouse
    belongs_to :presiding_officer, Judiciary.Accounts.User, foreign_key: :presiding_officer_id
    has_many :activities, Judiciary.Court.Activity, foreign_key: :virtual_room_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(room, attrs) do
    room
    |> cast(attrs, [:name, :type, :slug, :court_id, :presiding_officer_id, :bench_members])
    |> validate_required([:name, :type, :slug])
    |> unique_constraint(:slug)
  end
end
