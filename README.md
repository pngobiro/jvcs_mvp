# Judiciary Virtual Court System (J-VCS) MVP

**Document ID**: J-VCS-TECH-2.2  
**Date**: February 5, 2026  
**Owner**: Directorate of ICT, The Judiciary of Kenya  
**Architecture**: Native Elixir/OTP & Membrane Modular Monolith  
**Security Level**: Restricted (Judicial Data)

## Overview

The J-VCS is a purpose-built, real-time judicial conferencing platform designed to achieve Digital Sovereignty for the Kenyan Judiciary. By migrating from commercial SaaS providers (Microsoft Teams/Zoom) to a self-hosted, open-source architecture, the system reduces annual licensing costs by **KES 28M** while ensuring all judicial data resides within Kenyan borders.

## Key Features

- 🎥 Real-time video conferencing with WebRTC integration
- 🔐 Secure authentication and authorization system
- 🔗 Integration with Case Tracking System (CTS) and E-filing platforms
- 📹 Automated session recording and archiving
- 📝 Real-time transcription with speech-to-text capabilities
- 📡 Low-bandwidth optimization for remote access
- 🔒 End-to-end encryption and data security
- 🌐 Hybrid P2P/SFU networking for cost optimization

## Technology Stack

| Component | Technology | Version | Rationale |
|-----------|-----------|---------|-----------|
| Language | Elixir | 1.16+ | Fault-tolerant concurrency for thousands of sessions |
| Web Framework | Phoenix | 1.7+ | Real-time WebSocket engine |
| WebRTC | ex_webrtc | 0.15+ | Native Elixir WebRTC implementation |
| Media Engine | Membrane Framework | Latest | Native Elixir media pipeline (optional) |
| Frontend | Phoenix LiveView | 1.0+ | Server-side rendering with WebSocket UI |
| Database | PostgreSQL | 15+ | Primary relational store |
| Search | Meilisearch | 1.6+ | Fast full-text search for case files |
| Storage | MinIO | Latest | S3-compatible storage with WORM |
| Load Balancer | Nginx / HAProxy | - | SSL termination and WebSocket upgrades |
| Cache | Redis | 7+ | Session store and PubSub |

## Quick Start

### Prerequisites

- Elixir 1.16 or higher
- Erlang/OTP 26 or higher
- PostgreSQL 15+
- Redis 7+
- MinIO (for object storage)

### Installation

```bash
# Clone the repository
git clone https://github.com/pngobiro/jvcs_mvp.git
cd jvcs_mvp

# Install dependencies
mix deps.get

# Configure your database in config/dev.exs
# Then create and migrate the database
mix ecto.create
mix ecto.migrate

# Install frontend dependencies
cd assets && npm install && cd ..

# Start the Phoenix server
mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000) in your browser.

## Project Structure

```
jvcs_mvp/
├── docs/                   # Comprehensive documentation
│   ├── ARCHITECTURE.md     # System architecture and design
│   ├── DEVELOPMENT_GUIDE.md # Development workflow and best practices
│   ├── API_REFERENCE.md    # Complete API documentation
│   ├── DEPLOYMENT.md       # Production deployment guide
│   └── SECURITY.md         # Security policies and procedures
├── lib/
│   ├── judiciary/          # Core application logic
│   │   ├── auth/           # Authentication context
│   │   ├── court/          # Court session management
│   │   ├── media/          # Media processing with Membrane
│   │   ├── collaboration/  # Invitations and sharing
│   │   └── integrations/   # CTS, E-filing APIs
│   └── judiciary_web/      # Web interface
│       ├── live/           # LiveView modules
│       ├── channels/       # Phoenix Channels
│       └── components/     # Reusable UI components
├── mix.exs                 # Project dependencies
└── README.md               # This file
```

## Core Dependencies

```elixir
{:phoenix, "~> 1.7"},
{:phoenix_live_view, "~> 1.0"},
{:ex_webrtc, "~> 0.15.0"},             # Native Elixir WebRTC
# {:membrane_webrtc_plugin, "~> 0.26"}, # Optional: For recording
# {:boombox, "~> 0.2"},                 # Optional: For media processing
{:pow, "~> 1.0"},                      # Authentication
{:ecto_sql, "~> 3.10"},
{:postgrex, ">= 0.0.0"},
{:phoenix_pubsub, "~> 2.1"},
{:jason, "~> 1.4"},
{:oban, "~> 2.17"}                     # Background jobs
```

## Documentation

### WebRTC Implementation

- **[WebRTC Complete Guide](docs/WEBRTC_COMPLETE_GUIDE.md)** - Comprehensive guide for the Elixir-WebRTC implementation:
  - Architecture and implementation details (SFU/Server-side)
  - Configuration, monitoring, and troubleshooting
  - Future enhancements

### General Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[Start Here](docs/START_HERE.md)** - Critical first steps for new developers
- **[Architecture Guide](docs/ARCHITECTURE.md)** - System design, components, and patterns
- **[Server-Side WebRTC](docs/SERVER_SIDE_WEBRTC.md)** - Deep dive into the SFU architecture
- **[Development Guide](docs/DEVELOPMENT_GUIDE.md)** - Setup, workflow, and best practices
- **[API Reference](docs/API_REFERENCE.md)** - Complete API documentation with examples
- **[Deployment Guide](docs/DEPLOYMENT.md)** - Kubernetes deployment and operations
- **[Security Guide](docs/SECURITY.md)** - Security policies and compliance
- **[Recent Fixes & Updates](docs/SUCCESS.md)** - History of recent feature implementations and fixes
  - [Duplicate Presence Fix](docs/DUPLICATE_PRESENCE_FIX.md)
  - [Migration Complete](docs/MIGRATION_COMPLETE.md)

## Architecture Highlights

### Modular Monolith Design

The system follows a modular monolith architecture - logically separated into contexts but deployed as a single release to minimize operational overhead.

**Core Runtime**: BEAM (Erlang Virtual Machine)  
**Orchestration**: Kubernetes (K8s) Cluster  
**Node Discovery**: libcluster (connecting Erlang nodes across K8s pods)

### Network Topology (SFU Approach)

The system currently uses a **Selective Forwarding Unit (SFU)** architecture. Each participant maintains a single WebRTC connection to the Elixir server, which forwards media tracks to other participants.

**SFU Mode**: All media routes through the Elixir WebRTC engine (WebRTCPeer). This reduces client-side CPU usage and ensures the server has access to all streams for recording and transcription.

### Layered Architecture

1. **Presentation Layer**: Phoenix LiveView (Server-side rendering, WebSocket UI)
2. **Signaling Layer**: Phoenix PubSub & Channels (SDP exchange, Chat, Presence)
3. **Media Layer**: Elixir-WebRTC (`ex_webrtc`) - Handles PeerConnections and RTP forwarding.
4. **Data Layer**: PostgreSQL (State), Redis (PubSub), MinIO (Object Storage)

## Key Components

### 1. Court Session (GenServer)

Every active court hearing is backed by a GenServer process ensuring state consistency.

**Module**: `Judiciary.Court.SessionServer`

**Responsibilities**:
- Maintains the waiting room queue
- Tracks active speaker for UI highlighting
- Controls recording state (Start/Stop/Pause)
- Manages user permissions (Muting/Ejecting)

### 2. Media Pipeline (Membrane)

**Module**: `Judiciary.Media.RoomPipeline`

Handles the actual flow of video and audio packets with support for:
- SRTP decryption
- SFU routing to participants
- Recording to MKV format
- Voice Activity Detection (VAD)

### 3. Evidence Integrity (WORM Storage)

Legal requirements dictate that recordings cannot be tampered with:
1. Recording finishes → File saved locally
2. Background job calculates SHA-256 hash
3. File uploaded to MinIO with Governance Mode (7-year retention)
4. Database entry created with Hash and Timestamp

## Security Features

- **Authentication**: SSO via LDAP for internal users, OTP for external users
- **2FA**: Mandatory TOTP for Judges
- **Encryption**: TLS 1.3 for signaling, DTLS-SRTP for media, AES-256 at rest
- **Access Control**: Three types of links (Bench, Summons, Guest)
- **Audit Trail**: Complete logging of all security-relevant events

## Cost Analysis

| Platform | Year 1 | Subsequent Years |
|----------|--------|------------------|
| MS Teams + Zoom (Current) | KES 38M | KES 38M |
| Custom Virtual Court System | KES 30M | KES 10M |
| **Savings** | **KES 8M** | **KES 28M** |

**ROI**: The system pays for itself within the first year and generates annual savings of **KES 28M** thereafter.

## Implementation Roadmap

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| 1. Foundation | 4 Weeks | Setup K8s, Elixir Base, Auth, DB Design |
| 2. Media Core | 8 Weeks | Membrane Integration, P2P/SFU switching |
| 3. Evidence | 4 Weeks | Recording engine, Transcoding, MinIO WORM, Local AI Transcription (OpenAI Whisper via Elixir Bumblebee) |
| 4. Integration | 6 Weeks | CTS API, SMS Gateway, Email Notifications |
| 5. Pilot | 4 Weeks | Deploy to Milimani Commercial & 2 Rural Stations |
| 6. Handover | 2 Weeks | DevOps training, Manuals, Security Audit |

**Total**: 28 weeks

## Future Roadmap / TODO

- [ ] **Sovereign Transcription**: Implement local Speech-to-Text using OpenAI Whisper via `Elixir Bumblebee` and `Nx` for high-accuracy, private court minutes.
- [ ] **Membrane SFU Integration**: Scale from P2P Mesh to Selective Forwarding Unit for large sessions (10+ participants).
- [ ] **Exhibit Management**: Synchronized document sharing (PDF/Images) with automated watermarking and legal timestamping.
- [ ] **Automated Court Minutes**: LLM-assisted summarization of transcribed sessions for faster record processing.
- [ ] **Digital Summons Automation**: Automated SMS and Email notifications with secure "Summons Links" for litigants and advocates.
- [ ] **Private Consultation Breakout Rooms**: Secure, isolated audio/video channels (Side-bars) for advocates to consult with clients privately during recesses.
- [ ] **Virtual Protocol Management**: Implementation of a "Raise Hand" and floor-request queue system managed by the Court Clerk.
- [ ] **Biometric Authentication for the Bench**: Secure biometric or multi-factor authentication (MFA) for Judges and Judicial Officers.
- [ ] **CTS/E-Filing Integration**: Deep integration with the Case Tracking System to pull case files and push session minutes automatically.

## Development Workflow

### Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/judiciary/court_test.exs
```

### Code Quality

```bash
# Format code
mix format

# Run linter
mix credo --strict

# Type checking
mix dialyzer

# Security audit
mix deps.audit
```

## API Example

### Schedule a Hearing

```bash
curl -X POST https://api.court.judiciary.go.ke/api/v1/hearings/schedule \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "case_number": "E034-2026",
    "title": "Republic vs. John Doe",
    "judge_email": "j.okello@judiciary.go.ke",
    "start_time": "2026-03-12T09:00:00Z",
    "participants": [
      {
        "role": "prosecutor",
        "email": "dpp@kenya.go.ke"
      }
    ]
  }'
```

## Contributing

This is a restricted project for the Judiciary of Kenya. For internal contributions:

1. Create a feature branch from `develop`
2. Make your changes with appropriate tests
3. Submit a pull request with detailed description
4. Ensure CI/CD pipeline passes
5. Request review from team lead

## Support

For questions or technical support:

**Directorate of ICT**  
The Judiciary of Kenya  
Email: ict@judiciary.go.ke  
Phone: +254-20-2221221

## License

© 2026 The Judiciary of Kenya. All rights reserved.

This software is proprietary and confidential. Unauthorized copying, distribution, or use is strictly prohibited.

---

**Built with ❤️ for the Judiciary of Kenya**
