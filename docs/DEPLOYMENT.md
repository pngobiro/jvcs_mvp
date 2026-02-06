# J-VCS Deployment Guide

## Overview

This guide covers deploying the Judiciary Virtual Court System to production using Kubernetes on a self-hosted infrastructure.

## Prerequisites

### Infrastructure Requirements

**Minimum Cluster Specifications**:
- 3 Kubernetes nodes (for high availability)
- 16 vCPUs per node
- 32 GB RAM per node
- 500 GB SSD storage per node
- 1 Gbps network interface

**External Services**:
- PostgreSQL 15+ (managed or self-hosted)
- Redis 7+ (managed or self-hosted)
- MinIO cluster (for object storage)
- Load balancer (Nginx/HAProxy)

### Software Requirements

- Kubernetes 1.28+
- kubectl CLI
- Helm 3.12+
- Docker 24+
- Git

## Pre-Deployment Setup

### 1. Prepare Kubernetes Cluster

```bash
# Verify cluster access
kubectl cluster-info

# Create namespace
kubectl create namespace judiciary-vcs-prod

# Set default namespace
kubectl config set-context --current --namespace=judiciary-vcs-prod
```

### 2. Configure Secrets

Create a secrets file `secrets.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: judiciary-vcs-secrets
  namespace: judiciary-vcs-prod
type: Opaque
stringData:
  # Database
  DATABASE_URL: "ecto://postgres:PASSWORD@postgres.judiciary.local/judiciary_prod"
  
  # Secret Key Base (generate with: mix phx.gen.secret)
  SECRET_KEY_BASE: "your_generated_secret_key_base_here"
  
  # Guardian Secret
  GUARDIAN_SECRET_KEY: "your_guardian_secret_key_here"
  
  # MinIO
  MINIO_ENDPOINT: "https://minio.judiciary.go.ke"
  MINIO_ACCESS_KEY: "your_minio_access_key"
  MINIO_SECRET_KEY: "your_minio_secret_key"
  MINIO_BUCKET: "judiciary-recordings"
  
  # Redis
  REDIS_URL: "redis://redis.judiciary.local:6379"
  
  # LDAP
  LDAP_HOST: "ldap.judiciary.go.ke"
  LDAP_PORT: "636"
  LDAP_BASE_DN: "dc=judiciary,dc=go,dc=ke"
  LDAP_BIND_DN: "cn=admin,dc=judiciary,dc=go,dc=ke"
  LDAP_BIND_PASSWORD: "your_ldap_password"
  
  # SMS Gateway
  SMS_API_KEY: "your_sms_api_key"
  SMS_SENDER_ID: "JUDICIARY"
  
  # Email
  SMTP_HOST: "smtp.judiciary.go.ke"
  SMTP_PORT: "587"
  SMTP_USERNAME: "noreply@judiciary.go.ke"
  SMTP_PASSWORD: "your_smtp_password"
```

Apply secrets:

```bash
kubectl apply -f secrets.yaml
```

### 3. Configure ConfigMap

Create `configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: judiciary-vcs-config
  namespace: judiciary-vcs-prod
data:
  PHX_HOST: "court.judiciary.go.ke"
  PORT: "4000"
  POOL_SIZE: "10"
  LOG_LEVEL: "info"
  ERLANG_COOKIE: "judiciary_vcs_cookie_change_in_production"
```

Apply ConfigMap:

```bash
kubectl apply -f configmap.yaml
```

## Building the Release

### 1. Build Docker Image

Create `Dockerfile`:

```dockerfile
# Build Stage
FROM hexpm/elixir:1.16.0-erlang-26.2.1-alpine-3.19.0 AS build

# Install build dependencies
RUN apk add --no-cache build-base git nodejs npm

# Set working directory
WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy mix files
COPY mix.exs mix.lock ./
COPY config config

# Install dependencies
ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy application files
COPY lib lib
COPY priv priv
COPY assets assets

# Compile assets
RUN cd assets && npm ci && npm run deploy && cd ..
RUN mix phx.digest

# Compile application
RUN mix compile

# Build release
RUN mix release

# Runtime Stage
FROM alpine:3.19.0

# Install runtime dependencies
RUN apk add --no-cache \
    openssl \
    ncurses-libs \
    libstdc++ \
    libgcc

# Create app user
RUN addgroup -g 1000 app && \
    adduser -D -u 1000 -G app app

# Set working directory
WORKDIR /app

# Copy release from build stage
COPY --from=build --chown=app:app /app/_build/prod/rel/judiciary ./

# Set user
USER app

# Expose port
EXPOSE 4000

# Set environment
ENV HOME=/app
ENV MIX_ENV=prod
ENV LANG=C.UTF-8

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD ["/app/bin/judiciary", "rpc", "1 + 1"]

# Start command
CMD ["/app/bin/judiciary", "start"]
```

Build and push image:

```bash
# Build image
docker build -t judiciary-vcs:1.0.0 .

# Tag for registry
docker tag judiciary-vcs:1.0.0 registry.judiciary.go.ke/judiciary-vcs:1.0.0

# Push to registry
docker push registry.judiciary.go.ke/judiciary-vcs:1.0.0
```

### 2. Database Migrations

Create migration job `migration-job.yaml`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: judiciary-vcs-migration
  namespace: judiciary-vcs-prod
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migration
        image: registry.judiciary.go.ke/judiciary-vcs:1.0.0
        command: ["/app/bin/judiciary", "eval", "Judiciary.Release.migrate"]
        envFrom:
        - secretRef:
            name: judiciary-vcs-secrets
        - configMapRef:
            name: judiciary-vcs-config
```

Run migrations:

```bash
kubectl apply -f migration-job.yaml
kubectl wait --for=condition=complete job/judiciary-vcs-migration --timeout=300s
```

## Kubernetes Deployment

### 1. Create Deployment

Create `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: judiciary-vcs
  namespace: judiciary-vcs-prod
  labels:
    app: judiciary-vcs
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: judiciary-vcs
  template:
    metadata:
      labels:
        app: judiciary-vcs
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - judiciary-vcs
              topologyKey: kubernetes.io/hostname
      containers:
      - name: judiciary-vcs
        image: registry.judiciary.go.ke/judiciary-vcs:1.0.0
        ports:
        - containerPort: 4000
          name: http
          protocol: TCP
        envFrom:
        - secretRef:
            name: judiciary-vcs-secrets
        - configMapRef:
            name: judiciary-vcs-config
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: RELEASE_NODE
          value: "judiciary@$(POD_IP)"
        resources:
          requests:
            cpu: "4000m"
            memory: "8Gi"
          limits:
            cpu: "8000m"
            memory: "16Gi"
        livenessProbe:
          httpGet:
            path: /health
            port: 4000
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /health/ready
            port: 4000
          initialDelaySeconds: 10
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        volumeMounts:
        - name: recordings-temp
          mountPath: /tmp/recordings
      volumes:
      - name: recordings-temp
        emptyDir:
          sizeLimit: 10Gi
```

### 2. Create Headless Service (for Erlang Clustering)

Create `service-headless.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: judiciary-vcs-headless
  namespace: judiciary-vcs-prod
spec:
  clusterIP: None
  selector:
    app: judiciary-vcs
  ports:
  - port: 4000
    name: http
  - port: 4369
    name: epmd
```

### 3. Create ClusterIP Service

Create `service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: judiciary-vcs
  namespace: judiciary-vcs-prod
  labels:
    app: judiciary-vcs
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600
  selector:
    app: judiciary-vcs
  ports:
  - port: 80
    targetPort: 4000
    protocol: TCP
    name: http
```

### 4. Create Ingress

Create `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: judiciary-vcs-ingress
  namespace: judiciary-vcs-prod
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/websocket-services: "judiciary-vcs"
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/session-cookie-name: "jvcs-affinity"
    nginx.ingress.kubernetes.io/session-cookie-expires: "3600"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "3600"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - court.judiciary.go.ke
    secretName: judiciary-vcs-tls
  rules:
  - host: court.judiciary.go.ke
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: judiciary-vcs
            port:
              number: 80
```

### 5. Deploy All Resources

```bash
# Apply all configurations
kubectl apply -f service-headless.yaml
kubectl apply -f service.yaml
kubectl apply -f deployment.yaml
kubectl apply -f ingress.yaml

# Verify deployment
kubectl get pods -w
kubectl get services
kubectl get ingress
```

## Horizontal Pod Autoscaler

Create `hpa.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: judiciary-vcs-hpa
  namespace: judiciary-vcs-prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: judiciary-vcs
  minReplicas: 3
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max
```

Apply HPA:

```bash
kubectl apply -f hpa.yaml
```

## Monitoring Setup

### 1. Prometheus ServiceMonitor

Create `servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: judiciary-vcs
  namespace: judiciary-vcs-prod
  labels:
    app: judiciary-vcs
spec:
  selector:
    matchLabels:
      app: judiciary-vcs
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
```

### 2. Grafana Dashboard

Import the provided Grafana dashboard from `monitoring/grafana-dashboard.json`.

Key metrics to monitor:
- Active sessions count
- Participant count
- CPU/Memory usage per pod
- WebSocket connections
- Database connection pool
- Media pipeline health
- Network bandwidth

## Backup and Disaster Recovery

### 1. Database Backups

Create a CronJob for automated backups:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: judiciary-vcs-prod
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:15-alpine
            command:
            - /bin/sh
            - -c
            - |
              pg_dump $DATABASE_URL | gzip > /backups/judiciary_$(date +%Y%m%d_%H%M%S).sql.gz
              # Upload to MinIO
              mc cp /backups/*.sql.gz minio/judiciary-backups/
            envFrom:
            - secretRef:
                name: judiciary-vcs-secrets
            volumeMounts:
            - name: backups
              mountPath: /backups
          volumes:
          - name: backups
            emptyDir: {}
          restartPolicy: OnFailure
```

### 2. Application State Backup

Recordings are automatically backed up to MinIO with versioning enabled.

## Rolling Updates

### Update Application

```bash
# Build new version
docker build -t judiciary-vcs:1.1.0 .
docker tag judiciary-vcs:1.1.0 registry.judiciary.go.ke/judiciary-vcs:1.1.0
docker push registry.judiciary.go.ke/judiciary-vcs:1.1.0

# Update deployment
kubectl set image deployment/judiciary-vcs \
  judiciary-vcs=registry.judiciary.go.ke/judiciary-vcs:1.1.0

# Monitor rollout
kubectl rollout status deployment/judiciary-vcs

# Rollback if needed
kubectl rollout undo deployment/judiciary-vcs
```

## Scaling

### Manual Scaling

```bash
# Scale to 5 replicas
kubectl scale deployment judiciary-vcs --replicas=5

# Verify
kubectl get pods
```

### Automatic Scaling

HPA will automatically scale based on CPU/Memory metrics (configured above).

## Troubleshooting

### View Logs

```bash
# All pods
kubectl logs -l app=judiciary-vcs --tail=100 -f

# Specific pod
kubectl logs judiciary-vcs-xxxxx-yyyyy --tail=100 -f

# Previous container (if crashed)
kubectl logs judiciary-vcs-xxxxx-yyyyy --previous
```

### Debug Pod

```bash
# Get shell access
kubectl exec -it judiciary-vcs-xxxxx-yyyyy -- /bin/sh

# Run IEx console
kubectl exec -it judiciary-vcs-xxxxx-yyyyy -- /app/bin/judiciary remote
```

### Check Events

```bash
kubectl get events --sort-by='.lastTimestamp'
```

### Check Resource Usage

```bash
kubectl top pods
kubectl top nodes
```

## Security Hardening

### 1. Network Policies

Create `networkpolicy.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: judiciary-vcs-netpol
  namespace: judiciary-vcs-prod
spec:
  podSelector:
    matchLabels:
      app: judiciary-vcs
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 4000
  egress:
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 5432  # PostgreSQL
    - protocol: TCP
      port: 6379  # Redis
    - protocol: TCP
      port: 9000  # MinIO
```

### 2. Pod Security Policy

```yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: judiciary-vcs-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
  - ALL
  volumes:
  - 'configMap'
  - 'emptyDir'
  - 'secret'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
  readOnlyRootFilesystem: false
```

## Performance Tuning

### BEAM VM Configuration

Add to deployment environment:

```yaml
env:
- name: ERL_FLAGS
  value: "+K true +A 64 +SDio 64 +SDcpu 16"
- name: ELIXIR_ERL_OPTIONS
  value: "+sssdio 128"
```

### Database Connection Pool

Adjust in `config/prod.exs`:

```elixir
config :judiciary, Judiciary.Repo,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  queue_target: 5000,
  queue_interval: 1000
```

## Maintenance Windows

### Planned Maintenance

```bash
# Drain node
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data

# Perform maintenance
# ...

# Uncordon node
kubectl uncordon node-1
```

## Disaster Recovery Procedures

### Complete System Failure

1. **Restore Database**:
```bash
gunzip -c backup.sql.gz | psql $DATABASE_URL
```

2. **Restore MinIO Data**:
```bash
mc mirror minio-backup/judiciary-recordings minio/judiciary-recordings
```

3. **Redeploy Application**:
```bash
kubectl apply -f deployment.yaml
```

4. **Verify System Health**:
```bash
kubectl get pods
curl https://court.judiciary.go.ke/health
```

## Post-Deployment Checklist

- [ ] All pods are running and healthy
- [ ] Ingress is accessible from external network
- [ ] SSL certificates are valid
- [ ] Database migrations completed successfully
- [ ] Monitoring dashboards showing data
- [ ] Alerts configured and tested
- [ ] Backup jobs running successfully
- [ ] Load testing completed
- [ ] Security scan passed
- [ ] Documentation updated

## Support

For deployment support:

**DevOps Team**: devops@judiciary.go.ke  
**Emergency Hotline**: +254-20-XXXXXXX  
**Runbook**: https://docs.judiciary.go.ke/runbook
