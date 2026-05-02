alias Judiciary.Court.Activity
alias Judiciary.Court.CourtHouse
alias Judiciary.Court.VirtualRoom
alias Judiciary.Repo

base_url = System.get_env("BASE_URL") || "http://localhost:4000"
IO.puts "Seeding courts using base_url: #{base_url}..."

courts = [
  %{
    name: "Milimani High Court - Court 1",
    code: "MIL-H-01",
    link: "#{base_url}/activities/1/room"
  },
  %{
    name: "Milimani High Court - Court 2",
    code: "MIL-H-02",
    link: "#{base_url}/activities/3/room"
  },
  %{
    name: "Mombasa Law Courts - Court 3",
    code: "MSA-L-03",
    link: "#{base_url}/activities/5/room"
  }
]

court_records = Enum.map(courts, fn attrs ->
  case Repo.get_by(CourtHouse, code: attrs.code) do
    nil ->
      %CourtHouse{}
      |> CourtHouse.changeset(attrs)
      |> Repo.insert!()
    court ->
      court
  end
end)

milimani_1 = Enum.find(court_records, &(&1.code == "MIL-H-01"))
milimani_2 = Enum.find(court_records, &(&1.code == "MIL-H-02"))

IO.puts "Seeding users and virtual chambers..."

judges = [
  %{
    email: "j.tech@judiciary.go.ke",
    name: "Hon. Justice Tech",
    role: "judge",
    link: "#{base_url}/users/chambers/tech"
  },
  %{
    email: "l.binary@judiciary.go.ke",
    name: "Hon. Lady Justice Binary",
    role: "judge",
    link: "#{base_url}/users/chambers/binary"
  },
  %{
    email: "j.silicon@judiciary.go.ke",
    name: "Hon. Justice Silicon",
    role: "judge",
    link: "#{base_url}/users/chambers/silicon"
  },
  %{
    email: "j.cloud@judiciary.go.ke",
    name: "Hon. Justice Cloud",
    role: "judge",
    link: "#{base_url}/users/chambers/cloud"
  },
  %{
    email: "c.clerk@judiciary.go.ke",
    name: "Standard Clerk",
    role: "clerk",
    link: "#{base_url}/users/dashboard/clerk"
  },
  %{
    email: "a.lawyer@example.com",
    name: "Standard Advocate",
    role: "advocate",
    link: "#{base_url}/users/dashboard/advocate"
  }
]

judge_records = Enum.map(judges, fn attrs ->
  user = case Judiciary.Accounts.get_user_by_email(attrs.email) do
    nil ->
      {:ok, user} = Judiciary.Accounts.register_user(attrs)
      # Set a default password
      {:ok, user} = 
        user
        |> Judiciary.Accounts.User.password_changeset(%{password: "password1234"})
        |> Judiciary.Repo.update()
      user
    user ->
      user
  end

  # Ensure each judge has a virtual chamber
  if user.role == "judge" do
    slug = user.email |> String.split("@") |> List.first() |> String.replace(".", "-")
    chamber_slug = "#{slug}-chamber"
    
    case Repo.get_by(VirtualRoom, slug: chamber_slug) do
      nil ->
        %VirtualRoom{}
        |> VirtualRoom.changeset(%{
          name: "#{user.name}'s Chambers",
          type: "chamber",
          slug: chamber_slug,
          presiding_officer_id: user.id,
          court_id: if(user.email in ["j.tech@judiciary.go.ke", "l.binary@judiciary.go.ke"], do: milimani_1.id, else: milimani_2.id)
        })
        |> Repo.insert!()
      _room ->
        :ok
    end
  end
  
  user
end)

# Create a sample Bench Room
case Repo.get_by(VirtualRoom, slug: "constitutional-bench") do
  nil ->
    %VirtualRoom{}
    |> VirtualRoom.changeset(%{
      name: "Constitutional Court Bench",
      type: "bench",
      slug: "constitutional-bench",
      court_id: milimani_1.id,
      bench_members: [
        Enum.find(judge_records, &(&1.email == "j.tech@judiciary.go.ke")).id,
        Enum.find(judge_records, &(&1.email == "l.binary@judiciary.go.ke")).id
      ]
    })
    |> Repo.insert!()
  _ -> :ok
end

IO.puts "Seeding court activities..."

# Clean up existing activities to allow linking to rooms
Repo.delete_all(Activity)

# Fetch rooms for mapping
rooms = Repo.all(VirtualRoom)

activities = [
  %{
    case_number: "PET-E001-2026",
    title: "Constitutional Petition: Rights of Digital Sovereignty",
    start_time: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
    status: "pending",
    judge_name: "Hon. Justice Tech",
    court_id: milimani_1.id,
    judge_id: Enum.find(judge_records, &(&1.email == "j.tech@judiciary.go.ke")).id,
    virtual_room_id: Enum.find(rooms, &(&1.slug == "j-tech-chamber")).id
  },
  %{
    case_number: "CRIM-B452-2026",
    title: "The State vs. Cyber Attacker",
    start_time: DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second),
    status: "in_progress",
    judge_name: "Hon. Lady Justice Binary",
    court_id: milimani_1.id,
    judge_id: Enum.find(judge_records, &(&1.email == "l.binary@judiciary.go.ke")).id,
    virtual_room_id: Enum.find(rooms, &(&1.slug == "l-binary-chamber")).id
  },
  %{
    case_number: "COMM-C123-2025",
    title: "Global Tech Corp vs. Local Startup Ltd",
    start_time: DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second),
    status: "pending",
    judge_name: "Hon. Justice Silicon",
    court_id: milimani_2.id,
    judge_id: Enum.find(judge_records, &(&1.email == "j.silicon@judiciary.go.ke")).id,
    virtual_room_id: Enum.find(rooms, &(&1.slug == "j-silicon-chamber")).id
  },
  %{
    case_number: "ELC-D789-2026",
    title: "Employment Dispute: Remote Work Policy",
    start_time: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second),
    status: "completed",
    judge_name: "Hon. Justice Cloud",
    court_id: milimani_2.id,
    judge_id: Enum.find(judge_records, &(&1.email == "j.cloud@judiciary.go.ke")).id,
    virtual_room_id: Enum.find(rooms, &(&1.slug == "j-cloud-chamber")).id
  }
]

Enum.each(activities, fn attrs ->
  %Activity{}
  |> Activity.changeset(Map.put(attrs, :link, "#{base_url}/rooms/#{Enum.find(rooms, &(&1.id == attrs.virtual_room_id)).slug}"))
  |> Repo.insert!()
end)

IO.puts "Successfully seeded #{length(activities)} activities, #{length(courts)} courts and virtual rooms."
