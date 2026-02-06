# J-VCS Security Guide

## Overview

This document outlines the security architecture, policies, and best practices for the Judiciary Virtual Court System. Given the sensitive nature of judicial proceedings, security is paramount.

## Security Principles

1. **Defense in Depth**: Multiple layers of security controls
2. **Least Privilege**: Minimal access rights for users and services
3. **Zero Trust**: Verify every request regardless of source
4. **Data Sovereignty**: All data remains within Kenyan borders
5. **Audit Trail**: Complete logging of all security-relevant events

## Authentication

### Internal Users (Judges, Clerks, Staff)

**Method**: Single Sign-On (SSO) via LDAP/Active Directory

**Implementation**:

```elixir
defmodule Judiciary.Auth.LDAP do
  def authenticate(username, password) do
    with {:ok, conn} <- connect_ldap(),
         {:ok, user_dn} <- search_user(conn, username),
         :ok <- bind_user(conn, user_dn, password),
         {:ok, attributes} <- get_user_attributes(conn, user_dn) do
      {:ok, build_user(attributes)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect_ldap do
    :eldap.open(
      [System.get_env("LDAP_HOST")],
      port: String.to_integer(System.get_env("LDAP_PORT")),
      ssl: true,
      timeout: 5000
    )
  end
end
```

**Security Features**:
- TLS 1.3 for LDAP connections
- Account lockout after 5 failed attempts
- Password complexity requirements enforced by AD
- Session timeout after 30 minutes of inactivity

### External Users (Advocates, Witnesses, Public)

**Method**: One-Time Password (OTP) via SMS/Email

**Implementation**:

```elixir
defmodule Judiciary.Auth.OTP do
  @otp_length 6
  @otp_validity_minutes 10

  def generate_otp(user_identifier) do
    otp = :crypto.strong_rand_bytes(@otp_length)
          |> Base.encode32()
          |> binary_part(0, @otp_length)

    # Store in Redis with expiry
    Redix.command(:redix, [
      "SETEX",
      "otp:#{user_identifier}",
      @otp_validity_minutes * 60,
      otp
    ])

    {:ok, otp}
  end

  def verify_otp(user_identifier, otp) do
    case Redix.command(:redix, ["GET", "otp:#{user_identifier}"]) do
      {:ok, ^otp} ->
        # Delete OTP after successful verification
        Redix.command(:redix, ["DEL", "otp:#{user_identifier}"])
        {:ok, :verified}

      {:ok, _} ->
        {:error, :invalid_otp}

      {:ok, nil} ->
        {:error, :expired_otp}
    end
  end
end
```

**Security Features**:
- 6-digit numeric OTP
- 10-minute validity period
- Single-use only
- Rate limiting: 3 attempts per 15 minutes
- SMS delivery via secure gateway

### Two-Factor Authentication (2FA)

**Requirement**: Mandatory for Judges when starting sessions

**Implementation**: Time-based One-Time Password (TOTP)

```elixir
defmodule Judiciary.Auth.TOTP do
  def generate_secret do
    :crypto.strong_rand_bytes(20)
    |> Base.encode32()
  end

  def generate_qr_code(user, secret) do
    uri = "otpauth://totp/JVCS:#{user.email}?secret=#{secret}&issuer=Judiciary"
    QRCode.create(uri)
  end

  def verify_token(secret, token) do
    expected = :pot.totp(secret)
    
    # Allow 30-second window for clock drift
    cond do
      token == expected -> {:ok, :verified}
      token == :pot.totp(secret, datetime: DateTime.add(DateTime.utc_now(), -30)) -> {:ok, :verified}
      token == :pot.totp(secret, datetime: DateTime.add(DateTime.utc_now(), 30)) -> {:ok, :verified}
      true -> {:error, :invalid_token}
    end
  end
end
```

## Authorization

### Role-Based Access Control (RBAC)

**Roles**:

| Role | Permissions |
|------|-------------|
| Judge | Start/end sessions, admit participants, control recording, mute/unmute, access all case files |
| Clerk | Schedule sessions, admit participants, manage waiting room, access assigned cases |
| Advocate | Join assigned sessions, share screen, view case documents |
| Prosecutor | Join assigned sessions, share screen, view case documents |
| Witness | Join when admitted, audio/video only (no screen share) |
| Public | View public sessions (audio/video only, no interaction) |

**Implementation**:

```elixir
defmodule Judiciary.Auth.Policy do
  def authorize(user, action, resource) do
    case {user.role, action, resource} do
      {:judge, :start_session, %Session{presiding_judge_id: judge_id}} 
        when judge_id == user.id -> :ok
      
      {:judge, :mute_participant, _} -> :ok
      
      {:clerk, :admit_participant, %Session{} = session} ->
        if assigned_to_clerk?(session, user), do: :ok, else: :error
      
      {:advocate, :join_session, %Session{} = session} ->
        if invited_to_session?(session, user), do: :ok, else: :error
      
      {:witness, :share_screen, _} -> :error
      
      {:public, :interact, _} -> :error
      
      _ -> :error
    end
  end

  defp assigned_to_clerk?(session, clerk) do
    session.clerk_id == clerk.id
  end

  defp invited_to_session?(session, user) do
    Judiciary.Collaboration.has_valid_invitation?(session.id, user.email)
  end
end
```

### Attribute-Based Access Control (ABAC)

For fine-grained permissions:

```elixir
defmodule Judiciary.Auth.ABAC do
  def can_access_recording?(user, recording) do
    cond do
      # Judge who presided can always access
      recording.session.presiding_judge_id == user.id -> true
      
      # Participants can access for 30 days after session
      is_participant?(user, recording.session) and 
      within_days?(recording.created_at, 30) -> true
      
      # Admins can access sealed recordings
      user.role == :admin and recording.is_sealed -> true
      
      # Public recordings are accessible to all
      recording.is_public -> true
      
      true -> false
    end
  end
end
```

## Encryption

### Data in Transit

**WebSocket/HTTPS**: TLS 1.3

```nginx
# Nginx configuration
ssl_protocols TLSv1.3;
ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';
ssl_prefer_server_ciphers off;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
ssl_stapling on;
ssl_stapling_verify on;
```

**WebRTC Media**: DTLS-SRTP

```elixir
defmodule Judiciary.Media.Security do
  def configure_dtls do
    %{
      dtls_srtp: true,
      ice_transport_policy: "relay",  # Force TURN for sensitive sessions
      rtcp_mux_policy: "require"
    }
  end
end
```

### Data at Rest

**Database**: Transparent Data Encryption (TDE)

```sql
-- PostgreSQL encryption
ALTER DATABASE judiciary_prod SET encryption = 'AES256';

-- Encrypt specific columns
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE sensitive_data (
  id UUID PRIMARY KEY,
  encrypted_field BYTEA,
  -- Store encrypted with application key
  CONSTRAINT check_encrypted CHECK (encrypted_field IS NOT NULL)
);
```

**Object Storage**: Server-Side Encryption (SSE-C)

```elixir
defmodule Judiciary.Storage do
  def upload_recording(file_path, session_id) do
    encryption_key = get_encryption_key()
    
    ExAws.S3.put_object(
      "judiciary-recordings",
      "#{session_id}/recording.mkv",
      File.read!(file_path),
      server_side_encryption: "AES256",
      server_side_encryption_customer_algorithm: "AES256",
      server_side_encryption_customer_key: Base.encode64(encryption_key),
      server_side_encryption_customer_key_md5: :crypto.hash(:md5, encryption_key) |> Base.encode64()
    )
    |> ExAws.request()
  end

  defp get_encryption_key do
    # Retrieve from secure key management system
    System.get_env("RECORDING_ENCRYPTION_KEY")
    |> Base.decode64!()
  end
end
```

### Key Management

**Storage**: HashiCorp Vault

```elixir
defmodule Judiciary.Vault do
  def get_secret(path) do
    Vault.read("secret/data/judiciary/#{path}")
  end

  def rotate_key(key_name) do
    # Generate new key
    new_key = :crypto.strong_rand_bytes(32)
    
    # Store in Vault
    Vault.write("secret/data/judiciary/keys/#{key_name}", %{
      key: Base.encode64(new_key),
      created_at: DateTime.utc_now(),
      version: get_next_version(key_name)
    })
    
    # Re-encrypt data with new key
    schedule_reencryption(key_name)
  end
end
```

## Session Security

### Secure Session Management

```elixir
defmodule JudiciaryWeb.SessionPlug do
  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> put_session_options()
    |> validate_session()
    |> check_session_timeout()
  end

  defp put_session_options(conn) do
    Plug.Conn.put_session(conn, :_csrf_token, Plug.CSRFProtection.get_csrf_token())
    |> Plug.Conn.configure_session(
      renew: true,
      secure: true,
      http_only: true,
      same_site: "Strict",
      max_age: 1800  # 30 minutes
    )
  end

  defp validate_session(conn) do
    case get_session(conn, :user_id) do
      nil -> conn
      user_id ->
        # Verify session in Redis
        case Redix.command(:redix, ["GET", "session:#{user_id}"]) do
          {:ok, session_data} when not is_nil(session_data) ->
            assign(conn, :current_user, Jason.decode!(session_data))
          _ ->
            conn
            |> clear_session()
            |> halt()
        end
    end
  end

  defp check_session_timeout(conn) do
    last_activity = get_session(conn, :last_activity)
    
    if last_activity && DateTime.diff(DateTime.utc_now(), last_activity) > 1800 do
      conn
      |> clear_session()
      |> halt()
    else
      put_session(conn, :last_activity, DateTime.utc_now())
    end
  end
end
```

## Input Validation & Sanitization

### SQL Injection Prevention

**Use Ecto Parameterized Queries**:

```elixir
# GOOD - Parameterized query
def get_session_by_case_number(case_number) do
  from(s in Session, where: s.case_number == ^case_number)
  |> Repo.one()
end

# BAD - String interpolation (vulnerable)
def get_session_by_case_number_bad(case_number) do
  Repo.query("SELECT * FROM sessions WHERE case_number = '#{case_number}'")
end
```

### XSS Prevention

**Phoenix HTML Escaping**:

```heex
<!-- Automatically escaped -->
<p><%= @user_input %></p>

<!-- Raw HTML (use with caution) -->
<p><%= raw(@trusted_html) %></p>

<!-- Safe with Phoenix.HTML.Tag -->
<%= content_tag :div, @content, class: "safe" %>
```

### CSRF Protection

```elixir
# Enabled by default in Phoenix
plug :protect_from_forgery

# In forms
<%= form_for @changeset, @action, fn f -> %>
  <%= csrf_meta_tag() %>
  <!-- form fields -->
<% end %>
```

## API Security

### Rate Limiting

```elixir
defmodule JudiciaryWeb.RateLimiter do
  use Plug.Builder

  plug :rate_limit

  def rate_limit(conn, _opts) do
    identifier = get_identifier(conn)
    
    case check_rate_limit(identifier) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
        |> put_resp_header("x-ratelimit-limit", "100")
      
      {:error, :rate_limited} ->
        conn
        |> put_status(429)
        |> json(%{error: "Rate limit exceeded"})
        |> halt()
    end
  end

  defp check_rate_limit(identifier) do
    key = "rate_limit:#{identifier}"
    
    case Redix.command(:redix, ["INCR", key]) do
      {:ok, 1} ->
        Redix.command(:redix, ["EXPIRE", key, 60])
        {:ok, 99}
      
      {:ok, count} when count <= 100 ->
        {:ok, 100 - count}
      
      {:ok, _} ->
        {:error, :rate_limited}
    end
  end

  defp get_identifier(conn) do
    # Use API key or IP address
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> to_string(:inet_parse.ntoa(conn.remote_ip))
    end
  end
end
```

### API Authentication

```elixir
defmodule JudiciaryWeb.APIAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Guardian.decode_and_verify(token),
         {:ok, user} <- get_user_from_claims(claims) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "Unauthorized"})
        |> halt()
    end
  end
end
```

## Audit Logging

### Security Event Logging

```elixir
defmodule Judiciary.Audit do
  require Logger

  def log_security_event(event_type, user, details) do
    event = %{
      event_type: event_type,
      user_id: user.id,
      user_email: user.email,
      user_role: user.role,
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      timestamp: DateTime.utc_now(),
      details: details
    }

    # Log to database
    %AuditLog{}
    |> AuditLog.changeset(event)
    |> Repo.insert()

    # Log to file
    Logger.info("SECURITY_EVENT", event)

    # Send to SIEM if critical
    if critical_event?(event_type) do
      send_to_siem(event)
    end
  end

  defp critical_event?(event_type) do
    event_type in [
      :unauthorized_access_attempt,
      :privilege_escalation_attempt,
      :data_breach_attempt,
      :session_hijacking_attempt
    ]
  end
end
```

### Events to Log

- Authentication attempts (success/failure)
- Authorization failures
- Session creation/destruction
- Privilege escalation attempts
- Data access (recordings, transcripts)
- Configuration changes
- User management actions
- API calls
- File uploads/downloads

## Network Security

### Firewall Rules

```bash
# Allow only necessary ports
iptables -A INPUT -p tcp --dport 443 -j ACCEPT  # HTTPS
iptables -A INPUT -p tcp --dport 80 -j ACCEPT   # HTTP (redirect to HTTPS)
iptables -A INPUT -p udp --dport 3478 -j ACCEPT # STUN
iptables -A INPUT -p udp --dport 49152:65535 -j ACCEPT # WebRTC media

# Drop all other incoming traffic
iptables -P INPUT DROP
```

### DDoS Protection

```nginx
# Nginx rate limiting
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;

server {
  location /api/ {
    limit_req zone=api burst=20 nodelay;
  }

  location /auth/login {
    limit_req zone=login burst=5;
  }
}
```

## Vulnerability Management

### Dependency Scanning

```bash
# Check for vulnerable dependencies
mix deps.audit

# Update dependencies
mix deps.update --all

# Security audit
mix sobelow --config
```

### Automated Security Testing

```yaml
# .github/workflows/security.yml
name: Security Scan

on: [push, pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Run dependency audit
        run: mix deps.audit
      
      - name: Run Sobelow
        run: mix sobelow --config
      
      - name: Run OWASP ZAP
        run: |
          docker run -t owasp/zap2docker-stable zap-baseline.py \
            -t https://staging.court.judiciary.go.ke
```

## Incident Response

### Security Incident Procedure

1. **Detection**: Automated alerts via monitoring
2. **Containment**: Isolate affected systems
3. **Investigation**: Analyze logs and audit trail
4. **Eradication**: Remove threat and patch vulnerabilities
5. **Recovery**: Restore services from clean backups
6. **Lessons Learned**: Document and improve

### Emergency Contacts

- **Security Team Lead**: security@judiciary.go.ke
- **DevOps On-Call**: +254-XXX-XXXXXX
- **Management Escalation**: cio@judiciary.go.ke

## Compliance

### Data Protection

- **GDPR Compliance**: Right to access, rectification, erasure
- **Kenya Data Protection Act**: Local data residency
- **Judicial Records Retention**: 7-year minimum retention

### Regular Audits

- **Quarterly**: Internal security review
- **Annually**: External penetration testing
- **Continuously**: Automated vulnerability scanning

## Security Checklist

### Development

- [ ] All dependencies up to date
- [ ] No hardcoded secrets
- [ ] Input validation on all user inputs
- [ ] Output encoding to prevent XSS
- [ ] Parameterized queries to prevent SQL injection
- [ ] CSRF protection enabled
- [ ] Security headers configured

### Deployment

- [ ] TLS 1.3 configured
- [ ] Secrets stored in Vault
- [ ] Network policies applied
- [ ] Firewall rules configured
- [ ] Monitoring and alerting active
- [ ] Backup and recovery tested
- [ ] Audit logging enabled

### Operations

- [ ] Regular security updates applied
- [ ] Access logs reviewed weekly
- [ ] Incident response plan tested
- [ ] Security training completed
- [ ] Compliance audit passed

## Resources

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [Elixir Security Guide](https://hexdocs.pm/phoenix/security.html)
- [Kenya Data Protection Act](https://www.odpc.go.ke/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
