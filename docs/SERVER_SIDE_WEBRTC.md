# Server-Side WebRTC Architecture

## Overview

This application uses a **full server-side WebRTC SFU (Selective Forwarding Unit)** implementation. All WebRTC peer connections are managed by the Elixir server, eliminating the complexity of client-side peer-to-peer connections.

## Architecture

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│  Client A   │         │   Server    │         │  Client B   │
│             │         │             │         │             │
│  Browser    │◄───────►│  Elixir     │◄───────►│  Browser    │
│  WebRTC     │  1 conn │  WebRTC     │  1 conn │  WebRTC     │
│             │         │  SFU        │         │             │
└─────────────┘         └─────────────┘         └─────────────┘
                              │
                              │ Forwards media
                              ▼
                        All participants
```

### Key Principles

1. **One Connection Per Client**: Each client maintains a single WebRTC connection to the server
2. **Server-Side Routing**: Server forwards RTP packets between clients (SFU pattern)
3. **Simplified Client**: JavaScript only handles media capture and UI
4. **Centralized State**: All WebRTC state managed in Elixir GenServers

## Components

### 1. WebRTCPeer (`lib/judiciary/media/webrtc_peer.ex`)

Manages individual peer connections using `ex_webrtc`.

**Responsibilities:**
- Create and manage PeerConnection
- Handle SDP offer/answer negotiation
- Process ICE candidates
- Receive media tracks from client
- Forward RTP packets to RoomSession

**Key Functions:**
```elixir
# Start a peer connection
WebRTCPeer.start_link(room_id: 123, peer_id: "abc", metadata: %{name: "John"})

# Create offer to client
WebRTCPeer.create_offer(room_id, peer_id)

# Handle signal from client
WebRTCPeer.handle_signal(room_id, peer_id, from_peer_id, signal)

# Add ICE candidate
WebRTCPeer.add_ice_candidate(room_id, peer_id, candidate)
```

### 2. RoomSession (`lib/judiciary/media/room_session.ex`)

Manages room state and coordinates media forwarding between peers.

**Responsibilities:**
- Track all peers in a room
- Start/stop WebRTCPeer processes
- Forward RTP packets between peers (SFU)
- Monitor peer health
- Handle peer join/leave

**Key Functions:**
```elixir
# Add peer to room
RoomSession.add_peer(room_id, peer_id, metadata)

# Remove peer from room
RoomSession.remove_peer(room_id, peer_id)

# Send signal from client
RoomSession.send_signal(room_id, from_peer_id, to_peer_id, payload)

# Get all peers
RoomSession.get_peers(room_id)
```

### 3. LiveView (`lib/judiciary_web/live/activity_live/room.ex`)

Handles UI and routes WebRTC signals between client and server.

**Responsibilities:**
- Register peer with RoomSession on mount
- Route WebRTC signals from client to WebRTCPeer
- Push WebRTC signals from server to client
- Handle presence tracking
- Manage UI state

**Signal Flow:**
```
Client → LiveView → RoomSession → WebRTCPeer
                                      ↓
                                  PeerConnection
                                      ↓
Client ← LiveView ← RoomSession ← WebRTCPeer
```

### 4. JavaScript Hook (`assets/js/hooks/WebRTCSimple.js`)

Simplified client-side WebRTC handler.

**Responsibilities:**
- Capture local media (camera/microphone)
- Create single PeerConnection to server
- Handle SDP offer/answer from server
- Send ICE candidates to server
- Display remote video streams
- UI controls (mute, video toggle)

**Does NOT handle:**
- ❌ Peer-to-peer connections
- ❌ Multiple peer connections
- ❌ Signaling logic
- ❌ Connection state management

## Signal Flow

### Important: Loop Prevention
To prevent infinite signaling loops, `RoomSession` is configured to **ignore** `{:webrtc_signal_to_client, ...}` messages on PubSub. These signals are broadcast by `WebRTCPeer` and consumed directly by the relevant `LiveView`. `RoomSession` must not re-broadcast them.

### 1. Peer Joins Room

```
1. Client mounts LiveView
2. LiveView registers peer with RoomSession
3. RoomSession starts WebRTCPeer process
4. WebRTCPeer creates offer
5. Offer sent to client via LiveView
6. Client creates answer
7. Answer sent back via LiveView to WebRTCPeer
8. ICE candidates exchanged
9. Connection established
```

### 2. Media Streaming

```
1. Client captures local media
2. Client sends RTP packets to server
3. WebRTCPeer receives packets
4. WebRTCPeer sends to RoomSession
5. RoomSession forwards to other WebRTCPeers
6. Other WebRTCPeers send to their clients
7. Clients display remote video
```

### 3. Peer Leaves Room

```
1. Client disconnects
2. LiveView terminate callback
3. RoomSession removes peer
4. WebRTCPeer process stopped
5. Other peers notified
```

## Benefits

### Compared to Client-Side P2P

✅ **Simpler Client Code**: No complex peer-to-peer logic
✅ **Single Source of Truth**: All state in Elixir
✅ **Better Control**: Server can inspect/modify media
✅ **Easier Debugging**: All signaling in server logs
✅ **Recording Ready**: Server has access to all streams
✅ **Scalable**: Can add transcoding, layout control, etc.

### Trade-offs

⚠️ **Server Load**: More CPU/bandwidth on server
⚠️ **Latency**: Extra hop through server
⚠️ **Scaling**: Need to consider server capacity

## Configuration

### ICE Servers

Configured in `lib/judiciary/media/webrtc_peer.ex`:

```elixir
@ice_servers [
  %{urls: "stun:stun.l.google.com:19302"},
  %{urls: "stun:stun1.l.google.com:19302"}
]
```

For production, add TURN servers for NAT traversal:

```elixir
@ice_servers [
  %{urls: "stun:stun.l.google.com:19302"},
  %{
    urls: "turn:your-turn-server.com:3478",
    username: "user",
    credential: "pass"
  }
]
```

### Supervision Tree

```
Application
└── Judiciary.Media.Supervisor
    ├── RoomRegistry (Registry)
    ├── PeerRegistry (Registry)
    ├── RoomSupervisor (DynamicSupervisor)
    │   └── RoomSession (per room)
    │       └── WebRTCPeer (per peer)
    └── PeerSupervisor (DynamicSupervisor)
```

## Testing

### Manual Testing

1. Start application: `docker-compose up`
2. Login as judge: `judge@judiciary.go.ke` / `password123`
3. Login as clerk: `clerk@judiciary.go.ke` / `password123`
4. Join same room
5. Admit clerk from lobby
6. Verify video/audio connection

### Debugging

Enable detailed logging:

```elixir
# In config/dev.exs
config :logger, level: :debug
```

Check logs for:
- `[info] Initializing WebRTC peer`
- `[debug] Received offer from client`
- `[debug] Sending answer to server`
- `[info] Peer connection state: connected`

## Future Enhancements

### Recording

Server has access to all media streams, can record:

```elixir
def handle_info({:ex_webrtc, _pc, {:rtp, track_id, packet}}, state) do
  # Send to recording pipeline
  RecordingPipeline.write_packet(state.room_id, track_id, packet)
  {:noreply, state}
end
```

### Transcoding

Can transcode to different formats/bitrates:

```elixir
# Use Membrane Framework for transcoding
def handle_info({:peer_track_added, from_peer_id, track}, state) do
  # Transcode track before forwarding
  transcoded_track = Membrane.transcode(track, format: :h264, bitrate: 500_000)
  forward_to_peers(transcoded_track)
end
```

### Layout Control

Server can compose multiple streams:

```elixir
# Create grid layout
def compose_layout(streams) do
  Membrane.VideoComposer.grid(streams, rows: 2, cols: 2)
end
```

## Troubleshooting

### Connection Fails

1. Check ICE candidates are being exchanged
2. Verify STUN servers are reachable
3. Add TURN server for restrictive NATs
4. Check firewall allows UDP traffic

### No Video/Audio

1. Verify browser permissions granted
2. Check tracks are being added to PeerConnection
3. Verify RTP packets are being forwarded
4. Check remote video elements are created

### High Latency

1. Use TURN server closer to users
2. Optimize RTP forwarding logic
3. Consider regional server deployment
4. Monitor server CPU/bandwidth usage

## References

- [Elixir-WebRTC](https://github.com/elixir-webrtc/ex_webrtc)
- [WebRTC Specification](https://www.w3.org/TR/webrtc/)
- [SFU Architecture](https://webrtcglossary.com/sfu/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
