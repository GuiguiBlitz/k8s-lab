# K8S Lab

A local Kubernetes lab built on [k0s](https://k0sproject.io/) with [Envoy Gateway](https://gateway.envoyproxy.io/) for Gateway API support.

---

## Step 1 — Install tooling

Install brew:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install CLI tools:
```bash
brew install kubectl helm cilium-cli kyverno fluxcd/tap/flux k9s
```

---

## Step 2 — Bootstrap the cluster

```bash
make
```

This installs k0s, starts the controller, writes `~/.kube/config`, installs the `local-path` StorageClass, and sets up Envoy Gateway with the `eg` GatewayClass.

> **Behind a proxy?** Edit `~/.kube/config` and change the server IP to `localhost`.

---

## Demo 1 — Valkey + Redis Commander

A [Valkey](https://valkey.io/) (Redis-compatible) store and a Redis Commander web UI, exposed via Gateway API.

**Apply:**
```bash
kubectl apply -f valkey-demo/
```

**Find the access URL:**
```bash
# Node IP is shown in the ADDRESS column
kubectl get gateway -n valkey-demo valkey-demo-gateway

# Find the NodePort assigned to this gateway's envoy service
kubectl get svc -n envoy-gateway-system
```

Open `http://<NODE-IP>:<NODEPORT>/` in your browser.

**Tear down:**
```bash
kubectl delete -f valkey-demo/
```

**What's in the folder:**

| File | Contents |
|---|---|
| `00-namespace.yaml` | `valkey-demo` namespace |
| `valkey.yaml` | Valkey `Deployment` + `Service` (port 6379) |
| `app.yaml` | Redis Commander `Deployment` + `Service` |
| `gateway.yaml` | `EnvoyProxy` (NodePort) + `Gateway` + `HTTPRoute` |

---

## Demo 2 — GitLab CE + PostgreSQL + Adminer

GitLab CE via the official Helm chart, backed by a dedicated PostgreSQL instance. Adminer provides a web UI for the database. Both are exposed via Gateway API.

> **Prerequisite:** `make install-storage` must have been run (GitLab needs PVCs).

### 2a — Apply namespace, PostgreSQL and Adminer

```bash
kubectl apply -f gitlab/00-namespace.yaml
kubectl apply -f gitlab/postgres.yaml
kubectl apply -f gitlab/adminer.yaml
```

### 2b — Install GitLab via Helm

```bash
helm repo add gitlab https://charts.gitlab.io/
helm repo update
helm upgrade --install gitlab gitlab/gitlab \
  -n gitlab \
  -f gitlab/gitlab-values.yaml \
  --timeout 600s
```

> GitLab takes several minutes to start. Watch progress with `kubectl get pods -n gitlab -w`.

### 2c — Apply the Gateway and HTTPRoutes

```bash
kubectl apply -f gitlab/gateway.yaml
```

### 2d — Get the initial root password

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 -d && echo
```

### 2e — Find the node IP and NodePorts

```bash
# Node IP (ADDRESS column)
kubectl get gateway gitlab-gateway -n gitlab

# NodePorts — look for the PORT(S) column, format is 80:<GITLAB-PORT>/TCP,8080:<ADMINER-PORT>/TCP
kubectl get svc -n envoy-gateway-system | grep gitlab
```

Example output:
```
envoy-gitlab-gitlab-gateway-xxx   NodePort   ...   80:31051/TCP,8080:31118/TCP
#                                                      ^GitLab        ^Adminer
```

### 2f — Access

No `/etc/hosts` changes needed — routing is port-based:

| Service | Port | URL | Credentials |
|---|---|---|---|
| GitLab | 80 NodePort | `http://<NODE-IP>:<GITLAB-PORT>` | `root` / printed password |
| Adminer | 8080 NodePort | `http://<NODE-IP>:<ADMINER-PORT>` | server: `postgres`, user: `gitlab`, password: `gitlab-lab-password`, db: `gitlabhq_production` |

**Tear down:**
```bash
helm uninstall gitlab -n gitlab
kubectl delete -f gitlab/
```

**What's in the folder:**

| File | Contents |
|---|---|
| `00-namespace.yaml` | `gitlab` namespace |
| `postgres.yaml` | PostgreSQL 15 `Deployment` + `Service` + `PVC` + password `Secret` |
| `adminer.yaml` | Adminer `Deployment` + `Service` |
| `gitlab-values.yaml` | Helm values — external PostgreSQL, no nginx-ingress, no cert-manager, no registry |
| `gateway.yaml` | `EnvoyProxy` (NodePort) + `Gateway` + `HTTPRoute` for GitLab and Adminer |
