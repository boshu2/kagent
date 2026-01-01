# Enterprise Reference Architecture

This document provides reference architectures for deploying kagent in enterprise environments. It covers single-cluster, multi-cluster, air-gapped, high-availability, and multi-tenant deployment patterns with security and compliance considerations.

## Table of Contents

- [Overview](#overview)
- [Component Architecture](#component-architecture)
- [Deployment Patterns](#deployment-patterns)
  - [Single-Cluster Production Deployment](#single-cluster-production-deployment)
  - [Multi-Cluster with Shared Control Plane](#multi-cluster-with-shared-control-plane)
  - [Air-Gapped / Disconnected Environments](#air-gapped--disconnected-environments)
  - [High-Availability Configurations](#high-availability-configurations)
  - [Multi-Tenancy Patterns](#multi-tenancy-patterns)
- [Security Architecture](#security-architecture)
  - [Security Boundaries](#security-boundaries)
  - [Network Policies](#network-policies)
  - [RBAC Patterns](#rbac-patterns)
- [Compliance Considerations](#compliance-considerations)
  - [FIPS Requirements](#fips-requirements)
  - [Audit Logging](#audit-logging)
  - [Data Residency](#data-residency)
- [Observability](#observability)
- [Disaster Recovery](#disaster-recovery)

---

## Overview

kagent is a Kubernetes-native platform for deploying and managing AI agents. Enterprise deployments require careful consideration of:

- **High Availability**: Ensuring agent services remain available during failures and maintenance
- **Security**: Implementing defense-in-depth with proper isolation and access controls
- **Compliance**: Meeting regulatory requirements for audit, encryption, and data handling
- **Scalability**: Supporting growth in agents, users, and workloads
- **Operations**: Enabling monitoring, alerting, and incident response

### Core Components

| Component | Description | Scaling Model |
|-----------|-------------|---------------|
| Controller | Manages agent lifecycle, reconciles CRDs | Leader-elected, HA with replicas |
| UI | Web interface for agent management | Stateless, horizontal scaling |
| Agent Pods | Individual AI agent workloads | Per-agent, managed by controller |
| ToolServers | MCP tool servers for agent capabilities | Per-toolserver, independent scaling |
| Database | Stores conversation history, state | SQLite (dev) or PostgreSQL (prod) |

---

## Component Architecture

### Topology Diagram

```
                                    +---------------------------+
                                    |     External Traffic      |
                                    |   (Users, API Clients)    |
                                    +-------------+-------------+
                                                  |
                                                  | HTTPS (TLS)
                                                  v
                              +-------------------+-------------------+
                              |           Ingress Controller          |
                              |     (NGINX / OpenShift Router)        |
                              +-------------------+-------------------+
                                                  |
                    +-----------------------------+-----------------------------+
                    |                             |                             |
                    v                             v                             v
          +---------+---------+       +-----------+-----------+       +---------+---------+
          |      kagent       |       |        kagent         |       |      Metrics      |
          |        UI         |       |      Controller       |       |     Endpoint      |
          |   (Port 8080)     |       |     (Port 8083)       |       |   (Port 8083)     |
          +-------------------+       +-----------+-----------+       +-------------------+
                    |                             |
                    |                             | Reconcile Loop
                    |                             v
                    |               +-------------+-------------+
                    |               |    Kubernetes API Server  |
                    |               +-------------+-------------+
                    |                             |
                    +-----------------------------+
                                                  |
                                    +-------------+-------------+
                                    |       kagent CRDs         |
                                    | (Agents, ModelConfigs,    |
                                    |  ToolServers, Memories)   |
                                    +-------------+-------------+
                                                  |
                    +-----------------------------+-----------------------------+
                    |                             |                             |
                    v                             v                             v
          +---------+---------+       +-----------+-----------+       +---------+---------+
          |    Agent Pod 1    |       |     Agent Pod 2       |       |    Agent Pod N    |
          |  (k8s-agent)      |       |  (observability)      |       |    (custom)       |
          +-------------------+       +-----------+-----------+       +-------------------+
                    |                             |                             |
                    +-----------------------------+-----------------------------+
                                                  |
                                    +-------------+-------------+
                                    |       ToolServers         |
                                    |  (MCP Protocol Servers)   |
                                    +---------------------------+
```

### Data Flow Diagram

```
+------------+     +------------+     +------------+     +---------------+
|   User     | --> |    UI      | --> | Controller | --> | Agent Pod     |
| (Browser)  |     | (Next.js)  |     |   (Go)     |     | (Python/A2A)  |
+------------+     +------------+     +------------+     +---------------+
                         |                  |                    |
                         v                  v                    v
                   +----------+      +------------+      +---------------+
                   | REST API |      | K8s API    |      | LLM Provider  |
                   | (CRUD)   |      | (CRDs)     |      | (OpenAI/etc)  |
                   +----------+      +------------+      +---------------+
                                           |                    |
                                           v                    v
                                    +------------+      +---------------+
                                    | Database   |      | ToolServers   |
                                    | (PG/SQLite)|      | (MCP)         |
                                    +------------+      +---------------+
```

---

## Deployment Patterns

### Single-Cluster Production Deployment

The single-cluster pattern is suitable for organizations with a centralized Kubernetes platform or those starting their kagent journey.

#### Architecture

```
+-----------------------------------------------------------------------+
|                         Production Cluster                             |
|                                                                        |
|  +------------------+    +------------------+    +------------------+  |
|  |  kagent (NS)     |    | kagent-agents-   |    | kagent-agents-   |  |
|  |                  |    |    dev (NS)      |    |    prod (NS)     |  |
|  | - Controller     |    |                  |    |                  |  |
|  | - UI             |    | - Dev Agents     |    | - Prod Agents    |  |
|  | - ToolServers    |    | - Dev ModelCfgs  |    | - Prod ModelCfgs |  |
|  +------------------+    +------------------+    +------------------+  |
|           |                      |                       |             |
|           +----------------------+-----------------------+             |
|                                  |                                     |
|                    +-------------+-------------+                       |
|                    |      PostgreSQL           |                       |
|                    |   (HA / Managed)          |                       |
|                    +---------------------------+                       |
+-----------------------------------------------------------------------+
```

#### Configuration

```yaml
# values-production-single-cluster.yaml

# Database: Use PostgreSQL for persistence
database:
  type: postgres
  postgres:
    url: postgres://kagent:${POSTGRES_PASSWORD}@postgresql.kagent.svc.cluster.local:5432/kagent?sslmode=require

# High Availability
controller:
  replicas: 2
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 2
      memory: 1Gi

ui:
  replicas: 2
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 1
      memory: 512Mi

pdb:
  enabled: true
  controller:
    minAvailable: 1
  ui:
    minAvailable: 1

# Security hardening (see docs/security-context.md)
podSecurityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault

# Observability
otel:
  tracing:
    enabled: true
    exporter:
      otlp:
        endpoint: http://otel-collector.observability.svc.cluster.local:4317
        insecure: false

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

#### Namespace Strategy

```bash
# Create namespaces with appropriate labels
kubectl create namespace kagent
kubectl label namespace kagent kagent.dev/component=control-plane

kubectl create namespace kagent-agents-dev
kubectl label namespace kagent-agents-dev kagent.dev/managed=true kagent.dev/environment=development

kubectl create namespace kagent-agents-prod
kubectl label namespace kagent-agents-prod kagent.dev/managed=true kagent.dev/environment=production
```

---

### Multi-Cluster with Shared Control Plane

For organizations requiring geographic distribution, workload isolation, or regulatory separation.

#### Architecture

```
+---------------------------+         +---------------------------+
|    Management Cluster     |         |    Workload Cluster A     |
|                           |         |      (Region: US-East)    |
|  +--------------------+   |         |                           |
|  | kagent Controller  |---+-------->|  +--------------------+   |
|  | (Primary)          |   |         |  |    Agent Pods      |   |
|  +--------------------+   |         |  |  - prod-agents     |   |
|                           |         |  |  - customer-A      |   |
|  +--------------------+   |         |  +--------------------+   |
|  |    kagent UI       |   |         |                           |
|  +--------------------+   |         |  +--------------------+   |
|                           |         |  |   ToolServers      |   |
|  +--------------------+   |         |  +--------------------+   |
|  |   PostgreSQL HA    |   |         +---------------------------+
|  +--------------------+   |
+---------------------------+         +---------------------------+
            |                         |    Workload Cluster B     |
            |                         |      (Region: EU-West)    |
            +------------------------>|                           |
                                      |  +--------------------+   |
                                      |  |    Agent Pods      |   |
                                      |  |  - prod-agents     |   |
                                      |  |  - customer-B      |   |
                                      |  +--------------------+   |
                                      |                           |
                                      |  +--------------------+   |
                                      |  |   ToolServers      |   |
                                      |  +--------------------+   |
                                      +---------------------------+
```

#### Implementation Options

**Option 1: Cluster API + GitOps**

Use Cluster API to provision workload clusters and ArgoCD/Flux to deploy kagent agents:

```yaml
# ApplicationSet for multi-cluster agent deployment
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: kagent-agents
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            kagent.dev/workload-cluster: "true"
  template:
    metadata:
      name: 'kagent-agents-{{name}}'
    spec:
      project: kagent
      source:
        repoURL: https://github.com/your-org/kagent-config
        targetRevision: main
        path: 'clusters/{{name}}/agents'
      destination:
        server: '{{server}}'
        namespace: kagent-agents
```

**Option 2: Controller WatchNamespaces**

Configure the controller to watch specific namespaces representing different clusters (using namespace-as-cluster pattern):

```yaml
# values-management-cluster.yaml
controller:
  watchNamespaces:
    - kagent-cluster-us-east
    - kagent-cluster-eu-west
    - kagent-cluster-ap-south
```

---

### Air-Gapped / Disconnected Environments

For environments without direct internet access, common in government, defense, and regulated industries.

#### Architecture

```
+------------------------------------------------------------------+
|                    Air-Gapped Environment                         |
|                                                                   |
|  +----------------------+      +----------------------------+     |
|  |  Internal Registry   |      |    kagent Cluster          |     |
|  |  (Harbor/Quay)       |      |                            |     |
|  |                      |      |  +---------------------+   |     |
|  | - kagent/controller  |----->|  |  kagent Deployment  |   |     |
|  | - kagent/ui          |      |  +---------------------+   |     |
|  | - kagent/app         |      |                            |     |
|  | - ollama:latest      |      |  +---------------------+   |     |
|  +----------------------+      |  |  Ollama (Local LLM) |   |     |
|            ^                   |  +---------------------+   |     |
|            |                   +----------------------------+     |
|            |                                                      |
+------------------------------------------------------------------+
            |
            | Secure Transfer (USB/DVD/Diode)
            |
+------------------------------------------------------------------+
|                    Connected Environment                          |
|                                                                   |
|  +----------------------+                                         |
|  |  Image Staging       |                                         |
|  |                      |                                         |
|  | podman pull          |                                         |
|  | podman save          |                                         |
|  | (create tarball)     |                                         |
|  +----------------------+                                         |
+------------------------------------------------------------------+
```

#### Image Mirroring Process

```bash
#!/bin/bash
# air-gap-mirror.sh - Run in connected environment

KAGENT_VERSION="v0.1.0"
INTERNAL_REGISTRY="registry.internal.example.com"

# Images to mirror
IMAGES=(
  "cr.kagent.dev/kagent-dev/kagent/controller:${KAGENT_VERSION}"
  "cr.kagent.dev/kagent-dev/kagent/ui:${KAGENT_VERSION}"
  "cr.kagent.dev/kagent-dev/kagent/app:${KAGENT_VERSION}"
  "ghcr.io/kagent-dev/doc2vec/mcp:1.1.14"
)

# Pull and save images
for img in "${IMAGES[@]}"; do
  podman pull "$img"
done

podman save -m -o kagent-images.tar "${IMAGES[@]}"

# Transfer kagent-images.tar to air-gapped environment
# Then load on air-gapped side:
# podman load -i kagent-images.tar
# podman tag <image> ${INTERNAL_REGISTRY}/<image>
# podman push ${INTERNAL_REGISTRY}/<image>
```

#### Air-Gapped Values

```yaml
# values-airgapped.yaml

# Point to internal registry
registry: registry.internal.example.com/kagent

imagePullSecrets:
  - name: internal-registry-secret

controller:
  image:
    registry: registry.internal.example.com
    repository: kagent/controller

ui:
  image:
    registry: registry.internal.example.com
    repository: kagent/ui

# Use local LLM (Ollama)
providers:
  default: ollama
  ollama:
    provider: Ollama
    model: "llama3.2"
    config:
      host: ollama.kagent.svc.cluster.local:11434

# Disable external dependencies
querydoc:
  enabled: false

grafana-mcp:
  enabled: false
```

#### Local LLM Deployment

```yaml
# ollama-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: kagent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: registry.internal.example.com/ollama/ollama:latest
          ports:
            - containerPort: 11434
          resources:
            requests:
              cpu: 2
              memory: 8Gi
              # nvidia.com/gpu: 1  # Uncomment for GPU acceleration
            limits:
              cpu: 8
              memory: 32Gi
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: kagent
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
```

---

### High-Availability Configurations

#### HA Architecture

```
                            +------------------+
                            |   Load Balancer  |
                            +--------+---------+
                                     |
              +----------------------+----------------------+
              |                      |                      |
              v                      v                      v
     +--------+--------+   +--------+--------+   +--------+--------+
     |   UI Pod 1      |   |   UI Pod 2      |   |   UI Pod 3      |
     | (zone-a)        |   | (zone-b)        |   | (zone-c)        |
     +-----------------+   +-----------------+   +-----------------+
              |                      |                      |
              +----------------------+----------------------+
                                     |
                                     v
     +---------------------------------------------------------------+
     |                    Controller (HA with Leader Election)       |
     |                                                               |
     |   +-----------------+   +-----------------+                   |
     |   | Controller Pod 1|   | Controller Pod 2|                   |
     |   | (Leader)        |   | (Standby)       |                   |
     |   | zone-a          |   | zone-b          |                   |
     |   +-----------------+   +-----------------+                   |
     +---------------------------------------------------------------+
                                     |
                                     v
     +---------------------------------------------------------------+
     |                    PostgreSQL HA Cluster                      |
     |                                                               |
     |   +-----------------+   +-----------------+                   |
     |   |    Primary      |<->|    Replica      |                   |
     |   |    zone-a       |   |    zone-b       |                   |
     |   +-----------------+   +-----------------+                   |
     +---------------------------------------------------------------+
```

#### HA Configuration

```yaml
# values-ha.yaml

# Controller HA
controller:
  replicas: 2
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 2
      memory: 2Gi

  # Pod anti-affinity for zone distribution
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/component: controller
            topologyKey: topology.kubernetes.io/zone

# UI HA
ui:
  replicas: 3
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchLabels:
                app.kubernetes.io/component: ui
            topologyKey: topology.kubernetes.io/zone

# PodDisruptionBudgets
pdb:
  enabled: true
  controller:
    minAvailable: 1
  ui:
    minAvailable: 2

# Database HA
database:
  type: postgres
  postgres:
    # Use connection pooler (PgBouncer) for resilience
    url: postgres://kagent:${POSTGRES_PASSWORD}@pgbouncer.kagent.svc.cluster.local:5432/kagent?sslmode=require
```

#### PostgreSQL HA Options

**Option 1: CloudNativePG (Recommended)**

```yaml
# cloudnative-pg-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: kagent-postgres
  namespace: kagent
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: premium-rwo
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_connections: "100"
  bootstrap:
    initdb:
      database: kagent
      owner: kagent
  backup:
    barmanObjectStore:
      destinationPath: s3://kagent-backups/postgres
      s3Credentials:
        accessKeyId:
          name: s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: s3-creds
          key: SECRET_ACCESS_KEY
```

**Option 2: Managed PostgreSQL**

Use cloud-managed PostgreSQL services (AWS RDS, Azure Database, GCP Cloud SQL) for operational simplicity.

---

### Multi-Tenancy Patterns

#### Namespace-Based Multi-Tenancy

```
+------------------------------------------------------------------+
|                        Shared Cluster                             |
|                                                                   |
|  +----------------------+                                         |
|  |   kagent (NS)        |  <-- Control Plane (Cluster Admin)      |
|  |   - Controller       |                                         |
|  |   - UI               |                                         |
|  +----------------------+                                         |
|            |                                                      |
|            | Watches labeled namespaces                           |
|            v                                                      |
|  +------------------+  +------------------+  +------------------+ |
|  | tenant-a (NS)   |  | tenant-b (NS)   |  | tenant-c (NS)   | |
|  |                  |  |                  |  |                  | |
|  | - Agents         |  | - Agents         |  | - Agents         | |
|  | - ModelConfigs   |  | - ModelConfigs   |  | - ModelConfigs   | |
|  | - ToolServers    |  | - ToolServers    |  | - ToolServers    | |
|  |                  |  |                  |  |                  | |
|  | ResourceQuota    |  | ResourceQuota    |  | ResourceQuota    | |
|  | NetworkPolicy    |  | NetworkPolicy    |  | NetworkPolicy    | |
|  | LimitRange       |  | LimitRange       |  | LimitRange       | |
|  +------------------+  +------------------+  +------------------+ |
+------------------------------------------------------------------+
```

#### Tenant Namespace Setup

```yaml
# tenant-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    kagent.dev/managed: "true"
    kagent.dev/tenant: "tenant-a"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-a
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    secrets: "20"
    configmaps: "20"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-limits
  namespace: tenant-a
spec:
  limits:
    - default:
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:
        cpu: "100m"
        memory: "128Mi"
      type: Container
```

#### Controller Configuration for Multi-Tenancy

```yaml
# values-multi-tenant.yaml

controller:
  # Watch specific tenant namespaces
  watchNamespaces:
    - tenant-a
    - tenant-b
    - tenant-c

  # Or use label selector (implemented via namespace labels)
  # The controller will only reconcile resources in namespaces
  # with the kagent.dev/managed=true label
```

#### Tenant Network Isolation

```yaml
# tenant-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-isolation
  namespace: tenant-a
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from same namespace
    - from:
        - podSelector: {}
    # Allow traffic from kagent control plane
    - from:
        - namespaceSelector:
            matchLabels:
              kagent.dev/component: control-plane
  egress:
    # Allow DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Allow traffic to kagent control plane
    - to:
        - namespaceSelector:
            matchLabels:
              kagent.dev/component: control-plane
    # Allow traffic to LLM providers (customize per tenant)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
```

---

## Security Architecture

### Security Boundaries

```
+------------------------------------------------------------------+
|                     Cluster Boundary                              |
|                                                                   |
|  +------------------------------------------------------------+  |
|  |                  Network Policy Boundary                    |  |
|  |                                                              |  |
|  |  +------------------+      +------------------+              |  |
|  |  |  kagent NS       |      |  Tenant NS       |              |  |
|  |  |                  |      |                  |              |  |
|  |  | +-------------+  |      | +-------------+  |              |  |
|  |  | | Controller  |  |      | | Agent Pod   |  |              |  |
|  |  | | (SA: ctrl)  |  |      | | (SA: agent) |  |              |  |
|  |  | +------+------+  |      | +------+------+  |              |  |
|  |  |        |         |      |        |         |              |  |
|  |  |        | RBAC    |      |        | RBAC    |              |  |
|  |  |        v         |      |        v         |              |  |
|  |  | +-------------+  |      | +-------------+  |              |  |
|  |  | | Secrets     |  |      | | Secrets     |  |              |  |
|  |  | | ConfigMaps  |  |      | | ConfigMaps  |  |              |  |
|  |  | +-------------+  |      | +-------------+  |              |  |
|  |  +------------------+      +------------------+              |  |
|  +------------------------------------------------------------+  |
|                                                                   |
|  +------------------------------------------------------------+  |
|  |                   Pod Security Boundary                     |  |
|  |  - runAsNonRoot: true                                       |  |
|  |  - readOnlyRootFilesystem: true                             |  |
|  |  - allowPrivilegeEscalation: false                          |  |
|  |  - capabilities: drop ALL                                   |  |
|  |  - seccompProfile: RuntimeDefault                           |  |
|  +------------------------------------------------------------+  |
+------------------------------------------------------------------+
```

### Network Policies

#### Control Plane Network Policy

```yaml
# kagent-control-plane-netpol.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kagent-control-plane
  namespace: kagent
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow ingress from ingress controller
    - from:
        - namespaceSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080  # UI
        - protocol: TCP
          port: 8083  # Controller API
    # Allow Prometheus scraping
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
      ports:
        - protocol: TCP
          port: 8083  # Metrics
  egress:
    # Allow DNS resolution
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Allow Kubernetes API access
    - to:
        - ipBlock:
            cidr: 10.0.0.0/8  # Adjust for your cluster
      ports:
        - protocol: TCP
          port: 443
        - protocol: TCP
          port: 6443
    # Allow PostgreSQL access
    - to:
        - podSelector:
            matchLabels:
              app: postgresql
      ports:
        - protocol: TCP
          port: 5432
```

#### Agent Network Policy

```yaml
# agent-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kagent-agents
  namespace: kagent-agents-prod
spec:
  podSelector:
    matchLabels:
      kagent.dev/component: agent
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic from controller for A2A
    - from:
        - namespaceSelector:
            matchLabels:
              kagent.dev/component: control-plane
          podSelector:
            matchLabels:
              app.kubernetes.io/component: controller
      ports:
        - protocol: TCP
          port: 8000  # A2A port
  egress:
    # Allow DNS
    - to:
        - namespaceSelector: {}
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
    # Allow LLM provider access (OpenAI)
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
    # Allow ToolServer access
    - to:
        - podSelector:
            matchLabels:
              kagent.dev/component: toolserver
```

### RBAC Patterns

#### Cluster-Wide RBAC (Default)

kagent ships with two ClusterRoles:

```yaml
# Getter role - read-only access to kagent and Kubernetes resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-getter-role
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "toolservers", "memories", "remotemcpservers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get", "list", "watch"]
  # ... additional rules for apps, batch, rbac, etc.

---
# Writer role - full access to kagent resources
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kagent-writer-role
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "toolservers", "memories", "remotemcpservers"]
    verbs: ["create", "update", "patch", "delete"]
  # ... additional rules
```

#### Tenant-Scoped RBAC

For multi-tenant deployments, create namespace-scoped roles:

```yaml
# tenant-admin-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kagent-tenant-admin
  namespace: tenant-a
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "toolservers"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "create", "update", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kagent-tenant-admin-binding
  namespace: tenant-a
subjects:
  - kind: Group
    name: tenant-a-admins
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: kagent-tenant-admin
  apiGroup: rbac.authorization.k8s.io
```

#### Read-Only Access for Developers

```yaml
# developer-readonly-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kagent-developer-readonly
  namespace: tenant-a
rules:
  - apiGroups: ["kagent.dev"]
    resources: ["agents", "modelconfigs", "toolservers"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
```

---

## Compliance Considerations

### FIPS Requirements

For FIPS 140-2/140-3 compliance in US Government deployments:

#### FIPS-Compliant Container Images

```yaml
# values-fips.yaml

# Use FIPS-validated base images
controller:
  image:
    registry: registry.internal.example.com
    repository: kagent/controller-fips
    tag: "v0.1.0-fips"

ui:
  image:
    registry: registry.internal.example.com
    repository: kagent/ui-fips
    tag: "v0.1.0-fips"

# Use FIPS-compliant PostgreSQL
database:
  type: postgres
  postgres:
    url: postgres://kagent:${POSTGRES_PASSWORD}@postgresql-fips.kagent.svc.cluster.local:5432/kagent?sslmode=verify-full
```

#### FIPS Considerations

| Component | FIPS Requirement | Implementation |
|-----------|------------------|----------------|
| TLS | FIPS-approved algorithms only | Use TLS 1.2+ with approved cipher suites |
| Database | Encrypted connections | PostgreSQL with SSL/TLS, FIPS-mode OpenSSL |
| Secrets | At-rest encryption | Kubernetes secrets encryption with KMS |
| Container Runtime | FIPS-validated | Use RHEL/UBI FIPS images |

### Audit Logging

#### Kubernetes Audit Policy

```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log all kagent resource modifications
  - level: RequestResponse
    resources:
      - group: "kagent.dev"
        resources: ["agents", "modelconfigs", "toolservers", "memories"]
    verbs: ["create", "update", "patch", "delete"]

  # Log secret access (API keys)
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets"]
    namespaces: ["kagent", "kagent-agents-prod"]

  # Log authentication events
  - level: Metadata
    users: ["system:serviceaccount:kagent:*"]
```

#### OpenTelemetry Audit Traces

```yaml
# values-audit.yaml
otel:
  tracing:
    enabled: true
    exporter:
      otlp:
        endpoint: http://otel-collector.observability.svc.cluster.local:4317
        insecure: false
  logging:
    enabled: true
    exporter:
      otlp:
        endpoint: http://otel-collector.observability.svc.cluster.local:4317
        insecure: false
```

#### Audit Log Retention

```yaml
# fluent-bit-config.yaml (example)
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: logging
data:
  fluent-bit.conf: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/kagent-*.log
        Tag               kagent.*
        Parser            docker

    [FILTER]
        Name              kubernetes
        Match             kagent.*
        Kube_URL          https://kubernetes.default.svc:443
        Merge_Log         On

    [OUTPUT]
        Name              s3
        Match             kagent.*
        bucket            audit-logs
        region            us-east-1
        total_file_size   50M
        upload_timeout    10m
        s3_key_format     /kagent/audit/%Y/%m/%d/$TAG_%H%M%S.log
```

### Data Residency

For organizations with data sovereignty requirements:

```yaml
# values-eu-residency.yaml

# Deploy in EU region
controller:
  nodeSelector:
    topology.kubernetes.io/region: eu-west-1

ui:
  nodeSelector:
    topology.kubernetes.io/region: eu-west-1

# Use EU-based LLM providers or self-hosted
providers:
  default: azureOpenAI
  azureOpenAI:
    provider: AzureOpenAI
    model: "gpt-4"
    config:
      azureEndpoint: "https://your-instance.openai.azure.com"
      # Azure OpenAI deployed in EU region
```

---

## Observability

### Metrics Architecture

```
+------------------+     +------------------+     +------------------+
|  kagent         |     |   Prometheus     |     |    Grafana       |
|  Controller     |---->|   (scrape)       |---->|   (dashboards)   |
|  /metrics       |     |                  |     |                  |
+------------------+     +------------------+     +------------------+
                               |
                               v
                        +------------------+
                        |  AlertManager    |
                        |  (alerts)        |
                        +------------------+
```

### Prometheus Configuration

```yaml
# values-monitoring.yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus
    interval: 30s
    scrapeTimeout: 10s

  prometheusRule:
    enabled: true
    labels:
      release: prometheus
    defaultRules:
      controllerDown: true
      highErrorRate: true
      highLatency: true
    thresholds:
      errorRatePercent: 0.05
      latencySeconds: 5
```

### Example Grafana Dashboard Query

```promql
# Agent execution latency (p99)
histogram_quantile(0.99,
  sum(rate(kagent_agent_execution_duration_seconds_bucket[5m])) by (le, agent)
)

# Agent error rate
sum(rate(kagent_agent_execution_errors_total[5m])) by (agent)
/
sum(rate(kagent_agent_execution_total[5m])) by (agent)

# Active agent pods
count(kube_pod_status_phase{namespace=~"kagent.*", phase="Running"})
```

---

## Disaster Recovery

### Backup Strategy

| Component | Backup Method | Frequency | Retention |
|-----------|---------------|-----------|-----------|
| PostgreSQL | pg_dump / CloudNativePG backup | Hourly | 30 days |
| Kubernetes CRDs | Velero / GitOps | Continuous | Indefinite |
| Secrets | Sealed Secrets / External Secrets | On change | Indefinite |
| Configuration | Git repository | On change | Indefinite |

### PostgreSQL Backup (CloudNativePG)

```yaml
# cloudnative-pg-backup.yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: kagent-postgres-backup
  namespace: kagent
spec:
  schedule: "0 0 * * *"  # Daily at midnight
  backupOwnerReference: self
  cluster:
    name: kagent-postgres
  immediate: true
```

### Velero Backup Schedule

```yaml
# velero-backup-schedule.yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: kagent-backup
  namespace: velero
spec:
  schedule: "0 */6 * * *"  # Every 6 hours
  template:
    includedNamespaces:
      - kagent
      - kagent-agents-prod
    includedResources:
      - agents.kagent.dev
      - modelconfigs.kagent.dev
      - toolservers.kagent.dev
      - secrets
      - configmaps
    storageLocation: default
    ttl: 720h  # 30 days
```

### Recovery Procedure

1. **Restore PostgreSQL database** from backup
2. **Restore Kubernetes resources** via Velero or GitOps sync
3. **Verify controller health** and leader election
4. **Validate agent connectivity** and LLM provider access
5. **Run smoke tests** against restored agents

---

## Related Documentation

- [OpenShift Deployment Guide](./openshift-deployment-guide.md) - OpenShift-specific deployment instructions
- [Security Context Configuration](./security-context.md) - Detailed security context settings for agents
- [Helm Chart Values](../helm/kagent/values.yaml) - Complete configuration reference

## References

- [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
- [OpenShift Security Context Constraints](https://docs.openshift.com/container-platform/latest/authentication/managing-security-context-constraints.html)
- [NIST FIPS 140-2](https://csrc.nist.gov/publications/detail/fips/140/2/final)
- [CloudNativePG](https://cloudnative-pg.io/)
- [Velero Backup](https://velero.io/)
