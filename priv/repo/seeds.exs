alias Judiciary.Court.Activity
alias Judiciary.Repo

IO.puts "Seeding court activities..."

activities = [
  %{
    case_number: "PET-E001-2026",
    title: "Constitutional Petition: Rights of Digital Sovereignty",
    start_time: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
    status: "pending",
    judge_name: "Hon. Justice Tech"
  },
  %{
    case_number: "CRIM-B452-2026",
    title: "The State vs. Cyber Attacker",
    start_time: DateTime.utc_now() |> DateTime.add(7200, :second) |> DateTime.truncate(:second),
    status: "in_progress",
    judge_name: "Hon. Lady Justice Binary"
  },
  %{
    case_number: "COMM-C123-2025",
    title: "Global Tech Corp vs. Local Startup Ltd",
    start_time: DateTime.utc_now() |> DateTime.add(86400, :second) |> DateTime.truncate(:second),
    status: "pending",
    judge_name: "Hon. Justice Silicon"
  },
  %{
    case_number: "ELC-D789-2026",
    title: "Employment Dispute: Remote Work Policy",
    start_time: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second),
    status: "completed",
    judge_name: "Hon. Justice Cloud"
  }
]

Enum.each(activities, fn attrs ->
  %Activity{}
  |> Activity.changeset(attrs)
  |> Repo.insert!()
end)

IO.puts "Successfully seeded #{length(activities)} activities."
