# AGENTS.md — Project Context for AI Agents

This file describes the k8s-lab project for AI coding agents working in this repository.

## What this project is

A personal Kubernetes lab environment for experimenting with cloud-native tooling. It runs a single-node cluster locally using [k0s](https://k0sproject.io/) and uses [Envoy Gateway](https://gateway.envoyproxy.io/) as the Gateway API implementation. The README is written as a student step-by-step guide.

## Cluster setup

- **Distro:** k0s (single-node, controller+worker in one process)
- **kubeconfig:** `~/.kube/config` (generated via `sudo k0s kubeconfig admin`)
- **Cluster init:** `make` — installs k0s binary, sets up controller, writes kubeconfig
- **Proxy note:** The kubeconfig server address may need to be manually changed to `localhost` if behind a proxy

## Cluster-wide prerequisites (installed once)

| Component | How | Notes |
|---|---|---|
| local-path-provisioner | `make install-storage` | Provides `local-path` StorageClass, set as default |
| Envoy Gateway v1.7.1 | `make install-envoy-gateway` | Installs into `envoy-gateway-system`, applies `cluster/` |

## Makefile philosophy

The `makefile` only contains:
1. Cluster bootstrap targets (`make`, `make install-storage`, `make install-envoy-gateway`)
2. Nothing else — demo installs are done with plain `kubectl` / `helm` commands documented in the README

Do NOT add demo install targets to the makefile. The README is the student guide.

## Gateway API conventions

- GatewayClass name: **`eg`** (cluster-scoped, lives in `cluster/gatewayclass.yaml`)
- All demos define their own `Gateway` + `EnvoyProxy` (NodePort) per namespace
- `EnvoyProxy` with `envoyService.type: NodePort` is required on bare k0s (no cloud LB)
- HTTPRoutes use hostname-based routing (`hostnames: ["foo.local"]`)
- `gateway.networking.k8s.io/v1` API version for Gateway and HTTPRoute
- `gateway.envoyproxy.io/v1alpha1` API version for EnvoyProxy

## Repository structure

```
k8s-lab/
├── makefile              # Cluster bootstrap only
├── README.md             # Student step-by-step guide
├── AGENTS.md             # This file
├── cluster/              # Cluster-scoped resources (applied by make install-envoy-gateway)
│   └── gatewayclass.yaml # GatewayClass "eg"
├── valkey-demo/          # Demo 1: Valkey + Redis Commander
│   ├── 00-namespace.yaml
│   ├── valkey.yaml
│   ├── app.yaml
│   └── gateway.yaml
└── gitlab/               # Demo 2: GitLab CE + PostgreSQL + Adminer
    ├── 00-namespace.yaml
    ├── postgres.yaml
    ├── adminer.yaml
    ├── gitlab-values.yaml  # Helm values, not a kubectl-apply file
    └── gateway.yaml
```

## Demos

### valkey-demo (`valkey-demo` namespace)

- **Valkey** (`valkey/valkey:8-alpine`) — Redis-compatible store, port 6379
- **Redis Commander** (`rediscommander/redis-commander`) — web UI, `REDIS_HOSTS=valkey:valkey:6379`, port 8081
- **Gateway** — NodePort, no hostname filtering (catches all traffic)
- Install: `kubectl apply -f valkey-demo/`

### gitlab (`gitlab` namespace)

- **PostgreSQL 15** — `gitlabhq_production` DB, user `gitlab`, password from Secret `gitlab-postgres-password`
- **Adminer** — web DB UI, exposed at `adminer.local`
- **GitLab CE** — installed via `gitlab/gitlab` Helm chart with external PostgreSQL; bundled Redis, Minio; no nginx-ingress, no cert-manager, no registry, no runner
- **Gateway** — NodePort, hostname routing: `gitlab.local` → `gitlab-webservice-default:8181` (Workhorse), `adminer.local` → `adminer:80`
- GitLab webservice service name: `gitlab-webservice-default` (Helm release name `gitlab`)
- Workhorse port 8181 is the correct public port (not Puma's 8080)
- Initial root password: `kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d`

## Conventions for new demos

- Each demo gets its own subdirectory and namespace
- Namespace file named `00-namespace.yaml` so it sorts and applies first
- Each demo has its own `Gateway` in its namespace (do not share gateways across namespaces)
- Always include `EnvoyProxy` with `envoyService.type: NodePort` alongside the `Gateway`
- Use hostname-based routing for multi-service gateways
- Include resource `requests` and `limits` on all containers
- PVCs must specify `storageClassName: local-path`
- Document demo install/teardown steps in README as plain kubectl/helm commands
