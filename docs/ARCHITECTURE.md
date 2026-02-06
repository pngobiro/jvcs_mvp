# J-VCS Architecture Guide

## System Architecture Overview

The Judiciary Virtual Court System follows a **Modular Monolith** architecture pattern, combining the simplicity of monolithic deployment with the organizational benefits of microservices.

## Core Principles

1. **Single Deployment Unit**: All modules deploy together as one Elixir release
2. **Logical Separation**: Code organized into bounded contexts
3. **Shared Database**: Single PostgreSQL instance with schema separation
4. **Event-Driven Communication**: Phoenix PubSub for inter-context messaging

## Architecture Layers

### 1. Presentation Layer

**Technology**: Phoenix LiveView + JavaScript Hooks

**Responsibilities**:
- Server-side rendering of UI
- Real-time updates via WebSocket
- Minimal client-side JavaScript (only for WebRTC)

**Key Components**:
```
lib/judiciary_web/
├── live/
│   ├── court_live.ex           # Main courtroom interface
│   ├── dashboard_live.ex       # Judge/Clerk dashboard
│   └── admin_live.ex           # System administration
├── components/
│   ├── roster.ex               # Participant list
│   ├── video_grid.ex           # Video layout manager
│   ├── lobby_notification.ex   # Waiting room alerts
│   └── invite_modal.ex         # Link sharing interface
└── controllers/
    └── api/                    # REST API for integrations
```

### 2. Application Layer

**Technology**: Phoenix Contexts

**Responsibilities**:
- Business logic encapsulation
- Data validation and transformation
- Orchestration of domain operations

**Contexts**:

```elixir
# Court Context - Session Management
Judiciary.Court
├── Session          # Schema
├── SessionServer    # GenServer for live state
├── Participant      # Schema
└── API              # Public interface

# Media Context - WebRTC & Recording
Judiciary.Media
├── RoomPipeline     # Membrane pipeline
├── Recording        # Schema
└── Transcoder       # Background jobs

# Auth Context - Authentication & Authorization
Judiciary.Auth
├── User             # Schema
├── Guardian         # Token management
└── LDAP             # SSO integration

# Collaboration Context - Invitations
Judiciary.Collaboration
├── Invitation       # Schema
├── LinkGenerator    # Secure URL creation
└── Mailer           # Email notifications

# Integrations Context - External Systems
Judiciary.Integrations
├── CTS              # Case Tracking System
├── EFiling          # E-filing platform
└── SMS              # SMS gateway
```

### 3. Communication Layer

**Technology**: Phoenix Channels (WebSocket)

**Channels**:

```elixir
# Court Channel - Real-time session events
JudiciaryWeb.CourtChannel
- join/3              # Authenticate and join session
- handle_in/3         # Process client messages
- handle_out/3        # Filter outbound messages

# Signaling Channel - WebRTC negotiation
JudiciaryWeb.SignalingChannel
- handle_in("offer")  # SDP offer from client
- handle_in("answer") # SDP answer from client
- handle_in("ice")    # ICE candidate exchange

# Presence - Track online users
JudiciaryWeb.Presence
- track/3             # Register user presence
- list/1              # Get online users
```

### 4. Media Layer

**Technology**: Membrane Framework

**Pipeline Architecture**:

```
Client (WebRTC) 
    ↓
[UDP Source] → [SRTP Decrypt] → [RTP Depayloader]
    ↓
[Tee (Splitter)]
    ├─→ [SFU Router] → Other Participants
    └─→ [Transcoder] → [File Sink] → MinIO
```

**Key Modules**:

```elixir
defmodule Judiciary.Media.RoomPipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    spec = [
      child(:source, %Membrane.WebRTC.Source{
        signaling: {:websocket, opts.signaling_url}
      })
      |> child(:tee, Membrane.Tee.Parallel)
      |> via_out(:sfu)
      |> child(:router, Membrane.WebRTC.SFU)
      |> via_out(:recording)
      |> child(:encoder, %Membrane.H264.FFmpeg.Encoder{preset: :fast})
      |> child(:muxer, %Membrane.Matroska.Muxer{})
      |> child(:sink, %Membrane.File.Sink{location: opts.output_path})
    ]

    {[spec: spec], %{session_id: opts.session_id}}
  end
end
```

### 5. Data Layer

**Technology**: PostgreSQL + Redis + MinIO

**Data Flow**:

```
Application
    ↓
[Ecto Repo] → PostgreSQL (Persistent State)
    ↓
[Phoenix PubSub] → Redis (Real-time Events)
    ↓
[ExAws] → MinIO (Object Storage)
```

**Database Design Principles**:
- UUID primary keys for distributed systems
- Timestamptz for all timestamps (UTC)
- JSONB for flexible metadata
- Partial indexes for performance
- Foreign key constraints for integrity

## Process Architecture

### Supervision Tree

```
Application
├── Judiciary.Repo (Database)
├── JudiciaryWeb.Endpoint (HTTP/WebSocket)
├── Judiciary.PubSub (Redis)
├── Judiciary.Court.SessionSupervisor
│   └── DynamicSupervisor
│       ├── SessionServer (session_1)
│       ├── SessionServer (session_2)
│       └── SessionServer (session_n)
├── Judiciary.Media.PipelineSupervisor
│   └── DynamicSupervisor
│       ├── RoomPipeline (room_1)
│       ├── RoomPipeline (room_2)
│       └── RoomPipeline (room_n)
└── Oban (Background Jobs)
    ├── RecordingWorker
    ├── TranscriptionWorker
    └── EmailWorker
```

### GenServer Lifecycle

**Session Server**:

```elixir
# Start
{:ok, pid} = Judiciary.Court.SessionServer.start_link(session_id: "uuid")

# State Management
GenServer.call(pid, {:join, user})
GenServer.cast(pid, {:mute, user_id})
GenServer.call(pid, :get_state)

# Termination
GenServer.stop(pid)
```

## Network Architecture

### Hybrid P2P/SFU Model

**Decision Logic**:

```elixir
defmodule Judiciary.Media.NetworkStrategy do
  def select_mode(participants) do
    cond do
      same_subnet?(participants) and length(participants) <= 4 ->
        :p2p_mesh
      
      length(participants) <= 10 ->
        :sfu
      
      true ->
        :sfu_with_simulcast
    end
  end

  defp same_subnet?(participants) do
    participants
    |> Enum.map(&extract_subnet/1)
    |> Enum.uniq()
    |> length() == 1
  end
end
```

**P2P Mode** (Local Network):
- Direct peer connections
- No server bandwidth usage
- Limited to 4 participants
- Automatic fallback to SFU if quality degrades

**SFU Mode** (Remote):
- Server forwards streams
- Bandwidth optimization via simulcast
- Supports 50+ participants per room
- Adaptive bitrate based on network conditions

## Security Architecture

### Authentication Flow

```
User Request
    ↓
[Load Balancer] → TLS Termination
    ↓
[Phoenix Endpoint] → Session Cookie Validation
    ↓
[Pow Plug] → User Authentication
    ↓
[Guardian] → JWT Token Generation
    ↓
[LiveView Socket] → Secure WebSocket Connection
```

### Authorization Layers

1. **Route Level**: Phoenix Router guards
2. **Context Level**: Policy modules
3. **Data Level**: Ecto query filters
4. **UI Level**: LiveView assigns

```elixir
# Route Level
scope "/admin", JudiciaryWeb do
  pipe_through [:browser, :require_admin]
  live "/dashboard", AdminDashboardLive
end

# Context Level
defmodule Judiciary.Court.Policy do
  def can_start_recording?(%User{role: :judge}, _session), do: true
  def can_start_recording?(%User{role: :clerk}, session) do
    session.presiding_judge_id == user.id
  end
  def can_start_recording?(_, _), do: false
end

# Data Level
def list_sessions(user) do
  Session
  |> where([s], s.presiding_judge_id == ^user.id)
  |> or_where([s], s.is_public == true)
  |> Repo.all()
end
```

### Encryption Strategy

**Data in Transit**:
- TLS 1.3 for HTTPS/WSS
- DTLS-SRTP for WebRTC media
- Certificate pinning for mobile apps

**Data at Rest**:
- PostgreSQL: Transparent Data Encryption (TDE)
- MinIO: Server-Side Encryption (SSE-C)
- Backups: AES-256-GCM encryption

## Scalability Architecture

### Horizontal Scaling

**Erlang Clustering**:

```elixir
# config/prod.exs
config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes.DNS,
      config: [
        service: "judiciary-vcs-headless",
        application_name: "judiciary"
      ]
    ]
  ]
```

**Load Distribution**:
- Sticky sessions for LiveView (Nginx)
- Consistent hashing for GenServers
- Distributed Erlang for cross-node communication

### Vertical Scaling

**Resource Allocation**:
```yaml
# kubernetes/deployment.yaml
resources:
  requests:
    cpu: "4000m"
    memory: "8Gi"
  limits:
    cpu: "8000m"
    memory: "16Gi"
```

**BEAM Tuning**:
```bash
# vm.args
+K true                    # Enable kernel poll
+A 64                      # Async thread pool size
+SDio 64                   # Dirty IO schedulers
+SDcpu 16                  # Dirty CPU schedulers
+stbt db                   # Scheduler bind type
```

## Monitoring Architecture

### Observability Stack

```
Application Metrics
    ↓
[Telemetry] → [Prometheus Exporter]
    ↓
[Prometheus] → [Grafana Dashboards]
    ↓
[AlertManager] → [PagerDuty/Email]
```

**Key Metrics**:
- Active sessions count
- Participant count per session
- Media pipeline health
- Database connection pool
- WebSocket connection count
- CPU/Memory per node
- Network bandwidth usage

### Logging Strategy

```elixir
# Structured logging with metadata
Logger.metadata(
  session_id: session.id,
  user_id: user.id,
  case_number: session.case_number
)

Logger.info("Session started", 
  participant_count: 5,
  recording_enabled: true
)
```

## Disaster Recovery

### Backup Strategy

**Database**:
- Continuous WAL archiving
- Daily full backups
- Point-in-time recovery capability
- 30-day retention

**Object Storage**:
- Cross-region replication
- Versioning enabled
- 7-year retention (legal requirement)

**Configuration**:
- GitOps with version control
- Encrypted secrets in Vault
- Infrastructure as Code (Terraform)

### Failover Procedures

1. **Node Failure**: Automatic pod restart by Kubernetes
2. **Database Failure**: Automatic failover to standby replica
3. **Region Failure**: Manual DNS switch to DR site
4. **Complete Outage**: Restore from backups (RTO: 4 hours, RPO: 15 minutes)

## Performance Optimization

### Caching Strategy

```elixir
# Multi-level caching
defmodule Judiciary.Court do
  # Level 1: Process dictionary (per-request)
  def get_session(id) do
    case Process.get({:session, id}) do
      nil -> 
        session = fetch_and_cache(id)
        Process.put({:session, id}, session)
        session
      cached -> cached
    end
  end

  # Level 2: ETS (per-node)
  defp fetch_and_cache(id) do
    case :ets.lookup(:sessions, id) do
      [{^id, session}] -> session
      [] -> 
        session = Repo.get(Session, id)
        :ets.insert(:sessions, {id, session})
        session
    end
  end
end
```

### Database Optimization

- Connection pooling (Postgrex)
- Prepared statements
- Query result caching
- Materialized views for reports
- Partitioning for large tables

### Media Optimization

- Adaptive bitrate streaming
- Simulcast for multiple qualities
- VP8/VP9 codec preference
- Audio-only mode for low bandwidth
- Thumbnail generation for recordings

## Development Workflow

### Local Development

```bash
# Start dependencies
docker-compose up -d postgres redis minio

# Setup database
mix ecto.setup

# Start Phoenix
mix phx.server
```

### Testing Strategy

```elixir
# Unit tests
test "session server tracks participants" do
  {:ok, pid} = SessionServer.start_link(session_id: "test")
  :ok = SessionServer.join(pid, %User{id: "user1"})
  
  state = :sys.get_state(pid)
  assert map_size(state.participants) == 1
end

# Integration tests
test "user can join session via LiveView" do
  {:ok, view, _html} = live(conn, "/session/#{session.id}")
  
  assert view |> element("#join-btn") |> render_click()
  assert_push "joined", %{user_id: _}
end
```

### CI/CD Pipeline

```yaml
# .github/workflows/ci.yml
- name: Run tests
  run: mix test --cover

- name: Check formatting
  run: mix format --check-formatted

- name: Run Credo
  run: mix credo --strict

- name: Security audit
  run: mix deps.audit

- name: Build release
  run: mix release
```

## Deployment Architecture

### Kubernetes Resources

```
Namespace: judiciary-vcs-prod
├── Deployment: judiciary-vcs (3 replicas)
├── Service: judiciary-vcs (ClusterIP)
├── Service: judiciary-vcs-headless (for clustering)
├── Ingress: judiciary-vcs-ingress
├── ConfigMap: judiciary-vcs-config
├── Secret: judiciary-vcs-secrets
├── PVC: recordings-storage
└── HPA: judiciary-vcs-autoscaler
```

### Release Management

```bash
# Build release
MIX_ENV=prod mix release

# Run migrations
_build/prod/rel/judiciary/bin/judiciary eval "Judiciary.Release.migrate"

# Start application
_build/prod/rel/judiciary/bin/judiciary start
```

## Future Enhancements

### Phase 2 Features

- AI-powered transcription with speaker diarization
- Real-time translation for multi-lingual proceedings
- Virtual backgrounds and noise suppression
- Screen sharing with annotation tools
- Breakout rooms for private consultations

### Scalability Targets

- 500 concurrent sessions
- 5,000 simultaneous participants
- 99.9% uptime SLA
- Sub-200ms latency nationwide
- Support for all 47 counties

## References

- [Elixir Documentation](https://hexdocs.pm/elixir)
- [Phoenix Framework](https://hexdocs.pm/phoenix)
- [Membrane Framework](https://membrane.stream)
- [WebRTC Specification](https://www.w3.org/TR/webrtc/)
- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/)
