# J-VCS API Reference

## Overview

The Judiciary Virtual Court System provides RESTful APIs for integration with external systems including the Case Tracking System (CTS), E-filing platform, and SMS/Email gateways.

## Base URL

```
Production: https://api.court.judiciary.go.ke/api/v1
Staging: https://staging-api.court.judiciary.go.ke/api/v1
Development: http://localhost:4000/api/v1
```

## Authentication

All API requests require authentication using Bearer tokens.

### Obtaining a Token

**Endpoint**: `POST /auth/token`

**Request**:
```json
{
  "client_id": "your_client_id",
  "client_secret": "your_client_secret",
  "grant_type": "client_credentials"
}
```

**Response**:
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

### Using the Token

Include the token in the Authorization header:

```
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

## Error Responses

All endpoints return standard HTTP status codes and error responses:

```json
{
  "error": {
    "code": "invalid_request",
    "message": "The request is missing required parameters",
    "details": {
      "case_number": ["can't be blank"]
    }
  }
}
```

### Status Codes

| Code | Description |
|------|-------------|
| 200 | Success |
| 201 | Created |
| 400 | Bad Request |
| 401 | Unauthorized |
| 403 | Forbidden |
| 404 | Not Found |
| 422 | Unprocessable Entity |
| 500 | Internal Server Error |

## Endpoints

### Sessions

#### Schedule a Hearing

Creates a new court session and sends invitations to participants.

**Endpoint**: `POST /hearings/schedule`

**Request**:
```json
{
  "case_number": "E034-2026",
  "title": "Republic vs. John Doe",
  "judge_email": "j.okello@judiciary.go.ke",
  "start_time": "2026-03-12T09:00:00Z",
  "duration_minutes": 120,
  "court_room": "High Court Courtroom 1",
  "participants": [
    {
      "role": "prosecutor",
      "email": "dpp@kenya.go.ke",
      "name": "Director of Public Prosecutions"
    },
    {
      "role": "defense",
      "email": "advocate@firm.co.ke",
      "phone": "+254700000000",
      "name": "John Kamau"
    },
    {
      "role": "witness",
      "phone": "+254711111111",
      "name": "Jane Wanjiru"
    }
  ],
  "metadata": {
    "case_type": "criminal",
    "priority": "high"
  }
}
```

**Response**: `201 Created`
```json
{
  "status": "success",
  "data": {
    "session_id": "8933-2212-4433-aa12",
    "case_number": "E034-2026",
    "start_time": "2026-03-12T09:00:00Z",
    "status": "scheduled",
    "links": {
      "judge_link": "https://court.judiciary.go.ke/session/8933?token=eyJ...",
      "public_link": "https://court.judiciary.go.ke/public/8933"
    },
    "invitations_sent": 3
  }
}
```

#### Get Session Details

Retrieves information about a specific session.

**Endpoint**: `GET /sessions/:session_id`

**Response**: `200 OK`
```json
{
  "data": {
    "id": "8933-2212-4433-aa12",
    "case_number": "E034-2026",
    "title": "Republic vs. John Doe",
    "status": "live",
    "start_time": "2026-03-12T09:00:00Z",
    "end_time": null,
    "presiding_judge": {
      "id": "judge-uuid",
      "name": "Hon. Justice Okello",
      "email": "j.okello@judiciary.go.ke"
    },
    "participants": [
      {
        "id": "participant-uuid-1",
        "name": "Director of Public Prosecutions",
        "role": "prosecutor",
        "status": "connected",
        "joined_at": "2026-03-12T09:02:15Z"
      }
    ],
    "recording": {
      "enabled": true,
      "started_at": "2026-03-12T09:00:30Z",
      "file_size_mb": 245.6
    },
    "metadata": {
      "case_type": "criminal",
      "priority": "high"
    }
  }
}
```

#### List Sessions

Retrieves a paginated list of sessions.

**Endpoint**: `GET /sessions`

**Query Parameters**:
- `page` (integer): Page number (default: 1)
- `per_page` (integer): Items per page (default: 20, max: 100)
- `status` (string): Filter by status (scheduled, live, completed, cancelled)
- `judge_id` (uuid): Filter by judge
- `case_number` (string): Filter by case number
- `from_date` (datetime): Filter sessions from this date
- `to_date` (datetime): Filter sessions until this date

**Example**: `GET /sessions?status=live&page=1&per_page=20`

**Response**: `200 OK`
```json
{
  "data": [
    {
      "id": "session-uuid-1",
      "case_number": "E034-2026",
      "title": "Republic vs. John Doe",
      "status": "live",
      "start_time": "2026-03-12T09:00:00Z",
      "participant_count": 5
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total_pages": 5,
    "total_count": 95
  }
}
```

#### Update Session

Updates session details.

**Endpoint**: `PATCH /sessions/:session_id`

**Request**:
```json
{
  "title": "Updated Title",
  "start_time": "2026-03-12T10:00:00Z",
  "metadata": {
    "notes": "Rescheduled due to judge availability"
  }
}
```

**Response**: `200 OK`
```json
{
  "status": "success",
  "data": {
    "id": "session-uuid",
    "title": "Updated Title",
    "start_time": "2026-03-12T10:00:00Z",
    "updated_at": "2026-03-11T15:30:00Z"
  }
}
```

#### Cancel Session

Cancels a scheduled session.

**Endpoint**: `DELETE /sessions/:session_id`

**Request**:
```json
{
  "reason": "Case postponed indefinitely",
  "notify_participants": true
}
```

**Response**: `200 OK`
```json
{
  "status": "success",
  "message": "Session cancelled successfully",
  "notifications_sent": 5
}
```

### Participants

#### Add Participant

Adds a participant to an existing session.

**Endpoint**: `POST /sessions/:session_id/participants`

**Request**:
```json
{
  "role": "witness",
  "email": "witness@example.com",
  "phone": "+254722222222",
  "name": "Peter Mwangi",
  "send_invitation": true
}
```

**Response**: `201 Created`
```json
{
  "status": "success",
  "data": {
    "id": "participant-uuid",
    "role": "witness",
    "name": "Peter Mwangi",
    "invitation_link": "https://court.judiciary.go.ke/join?token=...",
    "invitation_sent": true
  }
}
```

#### Remove Participant

Removes a participant from a session.

**Endpoint**: `DELETE /sessions/:session_id/participants/:participant_id`

**Response**: `200 OK`
```json
{
  "status": "success",
  "message": "Participant removed successfully"
}
```

#### Mute/Unmute Participant

Controls participant audio.

**Endpoint**: `POST /sessions/:session_id/participants/:participant_id/mute`

**Request**:
```json
{
  "muted": true
}
```

**Response**: `200 OK`
```json
{
  "status": "success",
  "data": {
    "participant_id": "participant-uuid",
    "muted": true
  }
}
```

### Recordings

#### List Recordings

Retrieves recordings for a session.

**Endpoint**: `GET /sessions/:session_id/recordings`

**Response**: `200 OK`
```json
{
  "data": [
    {
      "id": "recording-uuid",
      "session_id": "session-uuid",
      "file_name": "E034-2026_2026-03-12.mkv",
      "file_size_mb": 1024.5,
      "duration_seconds": 7200,
      "format": "mkv",
      "started_at": "2026-03-12T09:00:30Z",
      "ended_at": "2026-03-12T11:00:30Z",
      "status": "completed",
      "checksum": "sha256:abc123...",
      "download_url": "https://recordings.judiciary.go.ke/...",
      "expires_at": "2026-03-19T11:00:30Z"
    }
  ]
}
```

#### Download Recording

Generates a temporary download URL for a recording.

**Endpoint**: `POST /recordings/:recording_id/download`

**Request**:
```json
{
  "expires_in_hours": 24,
  "reason": "Evidence review"
}
```

**Response**: `200 OK`
```json
{
  "status": "success",
  "data": {
    "download_url": "https://recordings.judiciary.go.ke/secure/...",
    "expires_at": "2026-03-13T11:00:00Z"
  }
}
```

#### Get Recording Metadata

Retrieves detailed metadata about a recording.

**Endpoint**: `GET /recordings/:recording_id`

**Response**: `200 OK`
```json
{
  "data": {
    "id": "recording-uuid",
    "session_id": "session-uuid",
    "case_number": "E034-2026",
    "file_name": "E034-2026_2026-03-12.mkv",
    "file_size_mb": 1024.5,
    "duration_seconds": 7200,
    "format": "mkv",
    "video_codec": "h264",
    "audio_codec": "opus",
    "resolution": "1280x720",
    "bitrate_kbps": 1200,
    "checksum": "sha256:abc123...",
    "signature": "digital_signature_here",
    "created_at": "2026-03-12T11:00:30Z",
    "sealed_at": "2026-03-12T11:05:00Z",
    "retention_until": "2033-03-12T11:00:30Z"
  }
}
```

### Transcriptions

#### Get Transcription

Retrieves the transcription for a session.

**Endpoint**: `GET /sessions/:session_id/transcription`

**Query Parameters**:
- `format` (string): Response format (json, txt, srt, vtt)

**Response**: `200 OK`
```json
{
  "data": {
    "session_id": "session-uuid",
    "case_number": "E034-2026",
    "language": "en",
    "segments": [
      {
        "speaker": "Hon. Justice Okello",
        "start_time": 0.0,
        "end_time": 5.2,
        "text": "This court is now in session.",
        "confidence": 0.98
      },
      {
        "speaker": "Prosecutor",
        "start_time": 5.5,
        "end_time": 12.3,
        "text": "Your Honor, the prosecution would like to present evidence.",
        "confidence": 0.95
      }
    ],
    "word_count": 1250,
    "duration_seconds": 7200,
    "generated_at": "2026-03-12T11:10:00Z"
  }
}
```

### Invitations

#### Generate Invitation Link

Creates a secure invitation link for a participant.

**Endpoint**: `POST /sessions/:session_id/invitations`

**Request**:
```json
{
  "role": "advocate",
  "email": "advocate@firm.co.ke",
  "expires_in_hours": 24,
  "permissions": {
    "can_share_screen": true,
    "can_record": false
  }
}
```

**Response**: `201 Created`
```json
{
  "status": "success",
  "data": {
    "invitation_id": "invitation-uuid",
    "link": "https://court.judiciary.go.ke/join?token=eyJ...",
    "expires_at": "2026-03-13T09:00:00Z",
    "email_sent": true
  }
}
```

#### Revoke Invitation

Revokes an invitation link.

**Endpoint**: `DELETE /invitations/:invitation_id`

**Response**: `200 OK`
```json
{
  "status": "success",
  "message": "Invitation revoked successfully"
}
```

### Statistics

#### Get Session Statistics

Retrieves statistics for a session.

**Endpoint**: `GET /sessions/:session_id/statistics`

**Response**: `200 OK`
```json
{
  "data": {
    "session_id": "session-uuid",
    "duration_seconds": 7200,
    "participant_count": 8,
    "peak_participants": 12,
    "average_participants": 7.5,
    "total_speaking_time": {
      "judge": 3600,
      "prosecutor": 1800,
      "defense": 1500,
      "witness": 300
    },
    "network_quality": {
      "average": "good",
      "poor_quality_duration": 120
    },
    "recording_size_mb": 1024.5,
    "bandwidth_used_gb": 2.5
  }
}
```

#### Get System Statistics

Retrieves overall system statistics.

**Endpoint**: `GET /statistics`

**Query Parameters**:
- `from_date` (datetime): Start date
- `to_date` (datetime): End date

**Response**: `200 OK`
```json
{
  "data": {
    "period": {
      "from": "2026-03-01T00:00:00Z",
      "to": "2026-03-31T23:59:59Z"
    },
    "sessions": {
      "total": 450,
      "completed": 420,
      "cancelled": 30,
      "average_duration_minutes": 120
    },
    "participants": {
      "total_unique": 1250,
      "average_per_session": 7.5
    },
    "recordings": {
      "total": 420,
      "total_size_gb": 512.5,
      "total_duration_hours": 840
    },
    "bandwidth": {
      "total_used_tb": 1.2,
      "average_per_session_gb": 2.7
    }
  }
}
```

## Webhooks

The system can send webhook notifications for various events.

### Configuring Webhooks

**Endpoint**: `POST /webhooks`

**Request**:
```json
{
  "url": "https://your-system.com/webhooks/jvcs",
  "events": [
    "session.started",
    "session.ended",
    "recording.completed",
    "participant.joined",
    "participant.left"
  ],
  "secret": "your_webhook_secret"
}
```

### Webhook Payload

All webhooks include a signature header for verification:

```
X-JVCS-Signature: sha256=abc123...
```

**Example Payload**:
```json
{
  "event": "session.started",
  "timestamp": "2026-03-12T09:00:00Z",
  "data": {
    "session_id": "session-uuid",
    "case_number": "E034-2026",
    "judge_id": "judge-uuid",
    "participant_count": 5
  }
}
```

### Webhook Events

| Event | Description |
|-------|-------------|
| `session.scheduled` | New session scheduled |
| `session.started` | Session started |
| `session.ended` | Session ended |
| `session.cancelled` | Session cancelled |
| `participant.joined` | Participant joined |
| `participant.left` | Participant left |
| `recording.started` | Recording started |
| `recording.stopped` | Recording stopped |
| `recording.completed` | Recording processed and uploaded |
| `transcription.completed` | Transcription completed |

## Rate Limiting

API requests are rate-limited to ensure fair usage:

- **Standard**: 100 requests per minute
- **Burst**: 200 requests per minute (short bursts)

Rate limit headers are included in responses:

```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 95
X-RateLimit-Reset: 1678886400
```

## SDK Examples

### cURL

```bash
# Schedule a hearing
curl -X POST https://api.court.judiciary.go.ke/api/v1/hearings/schedule \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "case_number": "E034-2026",
    "title": "Republic vs. John Doe",
    "judge_email": "j.okello@judiciary.go.ke",
    "start_time": "2026-03-12T09:00:00Z"
  }'
```

### Python

```python
import requests

API_BASE = "https://api.court.judiciary.go.ke/api/v1"
TOKEN = "your_access_token"

headers = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# Schedule a hearing
response = requests.post(
    f"{API_BASE}/hearings/schedule",
    headers=headers,
    json={
        "case_number": "E034-2026",
        "title": "Republic vs. John Doe",
        "judge_email": "j.okello@judiciary.go.ke",
        "start_time": "2026-03-12T09:00:00Z"
    }
)

session = response.json()
print(f"Session ID: {session['data']['session_id']}")
```

### JavaScript/Node.js

```javascript
const axios = require('axios');

const API_BASE = 'https://api.court.judiciary.go.ke/api/v1';
const TOKEN = 'your_access_token';

const client = axios.create({
  baseURL: API_BASE,
  headers: {
    'Authorization': `Bearer ${TOKEN}`,
    'Content-Type': 'application/json'
  }
});

// Schedule a hearing
async function scheduleHearing() {
  const response = await client.post('/hearings/schedule', {
    case_number: 'E034-2026',
    title: 'Republic vs. John Doe',
    judge_email: 'j.okello@judiciary.go.ke',
    start_time: '2026-03-12T09:00:00Z'
  });
  
  console.log('Session ID:', response.data.data.session_id);
}
```

## Support

For API support and questions:

**Email**: api-support@judiciary.go.ke  
**Documentation**: https://docs.court.judiciary.go.ke  
**Status Page**: https://status.court.judiciary.go.ke
