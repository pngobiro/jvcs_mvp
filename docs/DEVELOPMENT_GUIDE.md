# J-VCS Development Guide

## Getting Started

This guide will help you set up your development environment and understand the development workflow for the Judiciary Virtual Court System.

## Prerequisites

### Required Software

- **Elixir**: 1.16 or higher
- **Erlang/OTP**: 26 or higher
- **Node.js**: 18 or higher (for asset compilation)
- **PostgreSQL**: 15 or higher
- **Redis**: 7 or higher
- **Docker**: 24 or higher (optional, for containerized dependencies)

### Installation

#### macOS (using Homebrew)

```bash
# Install Elixir and Erlang
brew install elixir

# Install PostgreSQL
brew install postgresql@15
brew services start postgresql@15

# Install Redis
brew install redis
brew services start redis

# Install Node.js
brew install node
```

#### Ubuntu/Debian

```bash
# Add Erlang Solutions repository
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update

# Install Elixir and Erlang
sudo apt-get install elixir esl-erlang

# Install PostgreSQL
sudo apt-get install postgresql-15

# Install Redis
sudo apt-get install redis-server

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install nodejs
```

#### Using Docker (Recommended for Dependencies)

```bash
# Start all dependencies
docker-compose up -d
```

## Project Setup

### 1. Clone the Repository

```bash
git clone https://github.com/judiciary-kenya/j-vcs.git
cd j-vcs
```

### 2. Install Dependencies

```bash
# Install Elixir dependencies
mix deps.get

# Install Node.js dependencies
cd assets && npm install && cd ..

# Compile dependencies
mix deps.compile
```

### 3. Configure Environment

Create a `.env` file in the project root:

```bash
# Database
DATABASE_URL=ecto://postgres:postgres@localhost/judiciary_dev

# Secret Key Base (generate with: mix phx.gen.secret)
SECRET_KEY_BASE=your_generated_secret_key_base_here

# Redis
REDIS_URL=redis://localhost:6379

# MinIO (for local development)
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=judiciary-recordings

# LDAP (optional for local dev)
LDAP_HOST=localhost
LDAP_PORT=389
LDAP_BASE_DN=dc=judiciary,dc=local

# SMS Gateway (optional)
SMS_API_KEY=your_sms_api_key
SMS_SENDER_ID=JUDICIARY
```

### 4. Setup Database

```bash
# Create database
mix ecto.create

# Run migrations
mix ecto.migrate

# Seed database with test data
mix run priv/repo/seeds.exs
```

### 5. Start the Development Server

```bash
# Start Phoenix server
mix phx.server

# Or start with IEx for debugging
iex -S mix phx.server
```

Visit `http://localhost:4000` in your browser.

## Project Structure

```
j-vcs/
├── assets/                 # Frontend assets
│   ├── css/               # Stylesheets
│   ├── js/                # JavaScript files
│   │   ├── app.js        # Main JS entry point
│   │   └── hooks/        # LiveView hooks
│   └── vendor/           # Third-party libraries
├── config/                # Configuration files
│   ├── config.exs        # Base configuration
│   ├── dev.exs           # Development config
│   ├── prod.exs          # Production config
│   └── test.exs          # Test config
├── docs/                  # Documentation
├── lib/
│   ├── judiciary/        # Core application logic
│   │   ├── auth/         # Authentication context
│   │   ├── court/        # Court session management
│   │   ├── media/        # Media processing
│   │   ├── collaboration/ # Invitations & sharing
│   │   └── integrations/ # External system integrations
│   ├── judiciary_web/    # Web interface
│   │   ├── channels/     # Phoenix Channels
│   │   ├── controllers/  # HTTP controllers
│   │   ├── live/         # LiveView modules
│   │   ├── components/   # Reusable components
│   │   └── templates/    # HTML templates
│   └── judiciary.ex      # Application entry point
├── priv/
│   ├── repo/
│   │   ├── migrations/   # Database migrations
│   │   └── seeds.exs     # Seed data
│   └── static/           # Static assets
├── test/                  # Test files
├── mix.exs               # Project dependencies
└── docker-compose.yml    # Docker services
```

## Development Workflow

### Creating a New Feature

#### 1. Create a Feature Branch

```bash
git checkout -b feature/your-feature-name
```

#### 2. Generate Context (if needed)

```bash
# Generate a new context with schema
mix phx.gen.context Court Session sessions \
  case_number:string \
  presiding_judge_id:references:users \
  start_time:utc_datetime \
  end_time:utc_datetime \
  status:string \
  is_sealed:boolean
```

#### 3. Create Migration

```bash
mix ecto.gen.migration add_your_feature
```

Edit the migration file in `priv/repo/migrations/`:

```elixir
defmodule Judiciary.Repo.Migrations.AddYourFeature do
  use Ecto.Migration

  def change do
    create table(:your_table, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :field_name, :string, null: false
      
      timestamps()
    end

    create index(:your_table, [:field_name])
  end
end
```

#### 4. Run Migration

```bash
mix ecto.migrate
```

#### 5. Write Tests First (TDD)

```elixir
# test/judiciary/court_test.exs
defmodule Judiciary.CourtTest do
  use Judiciary.DataCase

  alias Judiciary.Court

  describe "sessions" do
    test "create_session/1 with valid data creates a session" do
      judge = insert(:user, role: :judge)
      
      attrs = %{
        case_number: "E034-2026",
        presiding_judge_id: judge.id,
        start_time: DateTime.utc_now()
      }

      assert {:ok, %Session{} = session} = Court.create_session(attrs)
      assert session.case_number == "E034-2026"
    end
  end
end
```

#### 6. Implement Feature

```elixir
# lib/judiciary/court.ex
defmodule Judiciary.Court do
  alias Judiciary.Court.Session
  alias Judiciary.Repo

  def create_session(attrs \\ %{}) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end
end
```

#### 7. Run Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/judiciary/court_test.exs

# Run specific test line
mix test test/judiciary/court_test.exs:10

# Run with coverage
mix test --cover
```

### Working with LiveView

#### Generate LiveView

```bash
mix phx.gen.live Court Session sessions \
  case_number:string \
  status:string \
  --web CourtLive
```

#### LiveView Structure

```elixir
defmodule JudiciaryWeb.CourtLive.Index do
  use JudiciaryWeb, :live_view

  alias Judiciary.Court

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to real-time updates
      Phoenix.PubSub.subscribe(Judiciary.PubSub, "sessions")
    end

    {:ok, assign(socket, :sessions, list_sessions())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    session = Court.get_session!(id)
    {:ok, _} = Court.delete_session(session)

    {:noreply, assign(socket, :sessions, list_sessions())}
  end

  @impl true
  def handle_info({:session_updated, session}, socket) do
    {:noreply, update(socket, :sessions, fn sessions ->
      [session | sessions]
    end)}
  end

  defp list_sessions do
    Court.list_sessions()
  end
end
```

### Working with Phoenix Channels

#### Create Channel

```bash
# Generate channel
mix phx.gen.channel Court
```

#### Implement Channel

```elixir
defmodule JudiciaryWeb.CourtChannel do
  use JudiciaryWeb, :channel

  alias Judiciary.Court.SessionServer

  @impl true
  def join("court:" <> session_id, payload, socket) do
    if authorized?(payload) do
      # Start or get session server
      {:ok, pid} = SessionServer.start_or_get(session_id)
      
      socket = assign(socket, :session_id, session_id)
      socket = assign(socket, :session_pid, pid)
      
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{
      body: body,
      user: socket.assigns.current_user.name
    })
    {:noreply, socket}
  end

  @impl true
  def handle_in("mute", %{"user_id" => user_id}, socket) do
    SessionServer.mute_participant(socket.assigns.session_pid, user_id)
    {:noreply, socket}
  end

  defp authorized?(_payload) do
    true
  end
end
```

### Working with GenServers

#### Create GenServer

```elixir
defmodule Judiciary.Court.SessionServer do
  use GenServer

  alias Judiciary.Court.Session

  # Client API

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  def join(session_id, user) do
    GenServer.call(via_tuple(session_id), {:join, user})
  end

  def mute_participant(session_id, user_id) do
    GenServer.cast(via_tuple(session_id), {:mute, user_id})
  end

  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    
    state = %{
      session_id: session_id,
      participants: %{},
      status: :waiting,
      recording: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, user}, _from, state) do
    participant = %{
      id: user.id,
      name: user.name,
      role: user.role,
      muted: false,
      joined_at: DateTime.utc_now()
    }

    new_state = put_in(state, [:participants, user.id], participant)
    
    # Broadcast to all participants
    broadcast_update(new_state)

    {:reply, {:ok, participant}, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:mute, user_id}, state) do
    new_state = update_in(state, [:participants, user_id], fn p ->
      %{p | muted: true}
    end)

    broadcast_update(new_state)

    {:noreply, new_state}
  end

  # Private Functions

  defp via_tuple(session_id) do
    {:via, Registry, {Judiciary.SessionRegistry, session_id}}
  end

  defp broadcast_update(state) do
    Phoenix.PubSub.broadcast(
      Judiciary.PubSub,
      "court:#{state.session_id}",
      {:state_updated, state}
    )
  end
end
```

### Working with Membrane Pipelines

#### Create Media Pipeline

```elixir
defmodule Judiciary.Media.RoomPipeline do
  use Membrane.Pipeline

  alias Membrane.WebRTC

  @impl true
  def handle_init(_ctx, opts) do
    session_id = opts.session_id
    output_path = "/tmp/recordings/#{session_id}.mkv"

    spec = [
      child(:source, %WebRTC.Source{
        signaling: {:websocket, opts.signaling_url}
      })
      |> child(:tee, Membrane.Tee.Parallel)
      |> via_out(:sfu)
      |> child(:router, WebRTC.SFU)
      |> via_out(:recording)
      |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{
        preset: :fast,
        profile: :baseline
      })
      |> child(:muxer, %Membrane.Matroska.Muxer{})
      |> child(:sink, %Membrane.File.Sink{location: output_path})
    ]

    state = %{
      session_id: session_id,
      output_path: output_path,
      recording: false
    }

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:end_of_stream, :source, _ctx, state) do
    # Upload recording to MinIO
    Judiciary.Media.upload_recording(state.output_path, state.session_id)
    
    {[], state}
  end
end
```

## Testing

### Test Structure

```
test/
├── judiciary/              # Context tests
│   ├── auth_test.exs
│   ├── court_test.exs
│   └── media_test.exs
├── judiciary_web/          # Web tests
│   ├── channels/
│   ├── controllers/
│   └── live/
├── support/                # Test helpers
│   ├── conn_case.ex
│   ├── channel_case.ex
│   ├── data_case.ex
│   └── factory.ex
└── test_helper.exs
```

### Writing Tests

#### Unit Tests

```elixir
defmodule Judiciary.CourtTest do
  use Judiciary.DataCase

  alias Judiciary.Court

  describe "create_session/1" do
    test "creates session with valid attributes" do
      judge = insert(:user, role: :judge)
      
      attrs = %{
        case_number: "E034-2026",
        presiding_judge_id: judge.id
      }

      assert {:ok, session} = Court.create_session(attrs)
      assert session.case_number == "E034-2026"
    end

    test "returns error with invalid attributes" do
      assert {:error, changeset} = Court.create_session(%{})
      assert %{case_number: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
```

#### Integration Tests

```elixir
defmodule JudiciaryWeb.CourtLiveTest do
  use JudiciaryWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    judge = insert(:user, role: :judge)
    session = insert(:session, presiding_judge_id: judge.id)
    
    %{judge: judge, session: session}
  end

  test "judge can start session", %{conn: conn, judge: judge, session: session} do
    conn = log_in_user(conn, judge)
    
    {:ok, view, _html} = live(conn, "/sessions/#{session.id}")
    
    assert view
           |> element("#start-session-btn")
           |> render_click() =~ "Session started"
    
    assert_push "session_started", %{session_id: _}
  end
end
```

#### Channel Tests

```elixir
defmodule JudiciaryWeb.CourtChannelTest do
  use JudiciaryWeb.ChannelCase

  setup do
    user = insert(:user)
    session = insert(:session)
    
    {:ok, _, socket} =
      JudiciaryWeb.UserSocket
      |> socket("user_id", %{user_id: user.id})
      |> subscribe_and_join(JudiciaryWeb.CourtChannel, "court:#{session.id}")

    %{socket: socket, user: user, session: session}
  end

  test "broadcasts are pushed to the client", %{socket: socket} do
    broadcast_from!(socket, "new_msg", %{body: "Hello"})
    assert_push "new_msg", %{body: "Hello"}
  end
end
```

### Test Factories

```elixir
# test/support/factory.ex
defmodule Judiciary.Factory do
  use ExMachina.Ecto, repo: Judiciary.Repo

  def user_factory do
    %Judiciary.Auth.User{
      email: sequence(:email, &"user#{&1}@judiciary.go.ke"),
      name: "Test User",
      role: :clerk,
      password_hash: Bcrypt.hash_pwd_salt("password123")
    }
  end

  def session_factory do
    %Judiciary.Court.Session{
      case_number: sequence(:case_number, &"E#{&1}-2026"),
      presiding_judge: build(:user, role: :judge),
      start_time: DateTime.utc_now(),
      status: :scheduled
    }
  end
end
```

## Debugging

### IEx Debugging

```elixir
# Add breakpoint in code
require IEx; IEx.pry()

# In IEx session
iex> h Enum.map          # Help for function
iex> i variable          # Inspect variable
iex> v()                 # Show history
iex> recompile()         # Recompile code
```

### Logger

```elixir
require Logger

Logger.debug("Debug message", user_id: user.id)
Logger.info("Session started", session_id: session.id)
Logger.warn("Low bandwidth detected", quality: :poor)
Logger.error("Failed to start recording", reason: error)
```

### Observer

```bash
# Start with observer
iex -S mix phx.server

# In IEx
iex> :observer.start()
```

## Code Quality

### Formatting

```bash
# Check formatting
mix format --check-formatted

# Auto-format code
mix format
```

### Linting (Credo)

```bash
# Run Credo
mix credo

# Strict mode
mix credo --strict

# Explain issue
mix credo explain lib/judiciary/court.ex:10
```

### Type Checking (Dialyzer)

```bash
# Build PLT (first time only)
mix dialyzer --plt

# Run type checking
mix dialyzer
```

### Security Audit

```bash
# Check for vulnerable dependencies
mix deps.audit

# Check for security issues
mix sobelow
```

## Common Tasks

### Reset Database

```bash
mix ecto.reset
```

### Generate Secret

```bash
mix phx.gen.secret
```

### Create Admin User

```bash
mix run -e "Judiciary.Seeds.create_admin()"
```

### Clear Cache

```bash
redis-cli FLUSHALL
```

### View Routes

```bash
mix phx.routes
```

## Troubleshooting

### Port Already in Use

```bash
# Find process using port 4000
lsof -i :4000

# Kill process
kill -9 <PID>
```

### Database Connection Issues

```bash
# Check PostgreSQL status
pg_isready

# Restart PostgreSQL
brew services restart postgresql@15
```

### Asset Compilation Errors

```bash
# Clean and reinstall
cd assets
rm -rf node_modules package-lock.json
npm install
cd ..
```

### Dependency Conflicts

```bash
# Clean dependencies
mix deps.clean --all
mix deps.get
mix deps.compile
```

## Resources

- [Elixir School](https://elixirschool.com/)
- [Phoenix Guides](https://hexdocs.pm/phoenix/overview.html)
- [Membrane Framework Docs](https://membrane.stream/learn)
- [Ecto Documentation](https://hexdocs.pm/ecto)
- [LiveView Documentation](https://hexdocs.pm/phoenix_live_view)
