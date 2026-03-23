# AGENTS.md — Project Context for AI Agents

This file describes the k8s-lab project for AI coding agents working in this repository.

## What this project is

A personal Kubernetes lab environment for experimenting with cloud-native tooling. It runs a single-node cluster locally using [k0s](https://k0sproject.io/) and uses [Envoy Gateway](https://gateway.envoyproxy.io/) as the Gateway API implementation. The README is written as a student step-by-step guide.

## Cluster setup

- **Distro:** k0s (single-node, controller+worker in one process)
- **kubeconfig:** `~/.kube/config` (generated via `sudo k0s kubeconfig admin`)
- **Cluster init:** manual steps in README Step 2 — install k0s, start controller, configure kubectl
- **Proxy note:** The kubeconfig server address may need to be manually changed to `localhost` if behind a proxy

## Cluster-wide prerequisites (installed once)

| Component | How | Notes |
|---|---|---|
| local-path-provisioner | `kubectl apply` (URL) | Provides `local-path` StorageClass, set as default |
| Envoy Gateway v1.7.1 | `helm install` + `kubectl apply -f cluster/` | Installs into `envoy-gateway-system`, creates `eg` GatewayClass |

## Makefile

There is no makefile. All setup steps are plain shell commands documented in the README. This is intentional — students follow the README step by step.

## Gateway API conventions

- GatewayClass name: **`eg`** (cluster-scoped, lives in `cluster/gatewayclass.yaml`)
- A **single shared Gateway** lives in the `gateway` namespace (`cluster/gateway/`), replacing per-namespace gateways
- `EnvoyProxy` with `envoyService.type: NodePort` is required on bare k0s (no cloud LB)
- HTTPRoutes live in their app namespaces and cross-reference the shared Gateway via `parentRefs.namespace: gateway`
- The Gateway listeners use `allowedRoutes.namespaces.from: All` to accept routes from any namespace
- No `ReferenceGrant` is needed for HTTPRoute → Gateway (allowed by `allowedRoutes.namespaces.from: All`)
- `gateway.networking.k8s.io/v1` API version for Gateway and HTTPRoute
- `gateway.envoyproxy.io/v1alpha1` API version for EnvoyProxy

## Shared Gateway listeners

| Listener name | Port | Service |
|---|---|---|
| `gitlab` | 80 | `gitlab-webservice-default:8181` in `gitlab` ns |
| `adminer` | 8080 | `adminer:80` in `gitlab` ns |
| `valkey` | 8081 | `redis-commander:80` in `valkey-demo` ns |
| `policy-reporter` | 9090 | `policy-reporter-ui:8080` in `policy-reporter` ns |

To find NodePorts: `kubectl get svc -n envoy-gateway-system | grep shared-gateway`

## Repository structure

```
k8s-lab/
├── README.md             # Student step-by-step guide (source of truth for all commands)
├── AGENTS.md             # This file
├── cluster/              # Cluster-scoped resources (applied during setup)
│   ├── gatewayclass.yaml # GatewayClass "eg"
│   └── gateway/          # Shared Gateway (applied after Envoy Gateway install)
│       ├── 00-namespace.yaml  # gateway namespace
│       └── gateway.yaml       # EnvoyProxy (NodePort) + Gateway with all listeners
├── valkey-demo/          # Demo 1: Valkey + Redis Commander
│   ├── 00-namespace.yaml
│   ├── valkey.yaml
│   ├── app.yaml
│   ├── gateway.yaml      # HTTPRoute only (binds to shared-gateway, sectionName: valkey)
│   └── labs/
│       └── netpol.yaml   # Applied in Lab 4 only
├── gitlab/               # Demo 2: GitLab CE + PostgreSQL + Adminer
│   ├── 00-namespace.yaml
│   ├── postgres.yaml
│   ├── adminer.yaml
│   ├── gateway.yaml      # HTTPRoutes for gitlab + adminer (binds to shared-gateway)
│   ├── gitlab-values.yaml          # Base Helm values
│   └── labs/
│       └── netpol-values.yaml      # Add-on values for Lab 3 (network policies)
└── kyverno/              # Lab 6: policy enforcement
    ├── policies/
    │   ├── mutate-default-resources.yaml      # Mutate — inject default requests/limits (Enforce, excludes system ns)
    │   ├── validate-resource-limits.yaml      # Validate — hard cap 2CPU/4Gi (Enforce, excludes system ns)
    │   ├── validate-block-nodeport.yaml       # Validate — no NodePort services (Audit)
    │   ├── validate-no-latest-tag.yaml        # Validate — no :latest image tag (Audit)
    │   ├── validate-allowed-registries.yaml   # Validate — approved registries only (Audit)
    │   ├── validate-require-probes.yaml       # Validate — require liveness+readiness (Audit)
    │   ├── generate-default-deny-netpol.yaml  # Generate — default-deny NetworkPolicy on ns create
    │   └── pss-example-namespace.yaml         # Example namespace with PSS labels (baseline/restricted)
    ├── policy-reporter-netpol.yaml  # NetworkPolicies for policy-reporter namespace
    └── policy-reporter-route.yaml   # HTTPRoute for Policy Reporter UI → shared-gateway
```

## Demos

### valkey-demo (`valkey-demo` namespace)

- **Valkey** (`valkey/valkey:8-alpine`) — Redis-compatible store, port 6379
- **Redis Commander** (`rediscommander/redis-commander`) — web UI, `REDIS_HOSTS=valkey:valkey:6379`, port 8081
- **Gateway** — all services routed via shared Gateway in `gateway` namespace (listener `valkey`, port 8081)
- Install: `kubectl apply -f valkey-demo/`

### gitlab (`gitlab` namespace)

- **PostgreSQL 15** — `gitlabhq_production` DB, user `gitlab`, password from Secret `gitlab-postgres-password`
- **Adminer** — web DB UI
- **GitLab CE** — installed via `gitlab/gitlab` Helm chart with external PostgreSQL; bundled Redis, Minio; no nginx-ingress, no cert-manager, no registry, no runner
- **Gateway** — shared Gateway in `gateway` namespace, listeners `gitlab` (port 80 → Workhorse 8181) and `adminer` (port 8080)
- GitLab webservice service name: `gitlab-webservice-default` (Helm release name `gitlab`)
- Workhorse port 8181 is the correct public port (not Puma's 8080)
- Initial root password: `kubectl get secret gitlab-gitlab-initial-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d`

## Conventions for new demos

- Each demo gets its own subdirectory and namespace
- Namespace file named `00-namespace.yaml` so it sorts and applies first
- Add a new listener to `cluster/gateway/gateway.yaml` and create an HTTPRoute in the app namespace
- HTTPRoute `parentRefs` must include `namespace: gateway` and `sectionName: <listener-name>`
- **IMPORTANT:** The `mutate-default-resources` policy uses server-side-apply SSA field conflict with Envoy Gateway — always exclude `envoy-gateway-system` and `gateway` from mutate/validate policies applied to system namespaces
- Include resource `requests` and `limits` on all containers
- PVCs must specify `storageClassName: local-path`
- Document demo install/teardown steps in README as plain kubectl/helm commands
