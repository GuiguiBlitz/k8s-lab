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
brew install kubectl helm kyverno k9s
```

---

## Step 2 — Bootstrap the cluster

### Install k0s

```bash
curl -sSf https://get.k0s.sh | sudo sh
sudo k0s install controller --single
sudo k0s start
```

Wait for the node to be ready (takes ~60 seconds):
```bash
sudo k0s kubectl get nodes
```

### Configure kubectl

```bash
mkdir -p ~/.kube
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes
```

> **Behind a proxy?** Edit `~/.kube/config` and change the server IP to `localhost`.

### Install the local-path StorageClass

Required for any PersistentVolumeClaim (used by GitLab):
```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.26/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

### Install Envoy Gateway and the GatewayClass

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.1 \
  -n envoy-gateway-system \
  --create-namespace
kubectl apply -f cluster/
```

Verify everything is ready:
```bash
kubectl get nodes
kubectl get storageclass
kubectl get gatewayclass
```

---

## Demo 1 — Valkey + Redis Commander

A [Valkey](https://valkey.io/) (Redis-compatible) store and a Redis Commander web UI, exposed via Gateway API.

```bash
kubectl apply -f valkey-demo/
```

Wait for pods to be ready:
```bash
kubectl get pods -n valkey-demo -w
```

Find the access URL:
```bash
# Node IP — shown in the ADDRESS column
kubectl get gateway -n valkey-demo valkey-demo-gateway

# NodePort — shown in the PORT(S) column
kubectl get svc -n envoy-gateway-system | grep valkey
```

Open `http://<NODE-IP>:<NODEPORT>/` in your browser. You should see the Redis Commander UI connected to Valkey.

**Tear down:**
```bash
kubectl delete -f valkey-demo/
```

<details>
<summary>What's in valkey-demo/</summary>

| File | Contents |
|---|---|
| `00-namespace.yaml` | `valkey-demo` namespace |
| `valkey.yaml` | Valkey `Deployment` + `Service` (port 6379) |
| `app.yaml` | Redis Commander `Deployment` + `Service` |
| `gateway.yaml` | `EnvoyProxy` (NodePort) + `Gateway` + `HTTPRoute` |

</details>

---

## Demo 2 — GitLab CE + PostgreSQL + Adminer

GitLab CE via the official Helm chart, backed by a dedicated PostgreSQL instance. Adminer provides a web UI for the database. Both are exposed via Gateway API using port-based routing.

### 2a — Apply namespace, PostgreSQL and Adminer

```bash
kubectl apply -f gitlab/00-namespace.yaml
kubectl apply -f gitlab/postgres.yaml
kubectl apply -f gitlab/adminer.yaml
```

Verify PostgreSQL starts cleanly:
```bash
kubectl get pods -n gitlab -w
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

GitLab takes several minutes to fully start. Watch progress:
```bash
kubectl get pods -n gitlab -w
```

All pods should eventually show `Running` or `Completed`.

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
# Node IP — ADDRESS column
kubectl get gateway gitlab-gateway -n gitlab

# NodePorts — PORT(S) column shows 80:<GITLAB-PORT>/TCP,8080:<ADMINER-PORT>/TCP
kubectl get svc -n envoy-gateway-system | grep gitlab
```

Example output:
```
envoy-gitlab-gitlab-gateway-xxx   NodePort   ...   80:31051/TCP,8080:31118/TCP
#                                                      ^GitLab        ^Adminer
```

### 2f — Access

No `/etc/hosts` changes needed — routing is port-based:

| Service | URL | Credentials |
|---|---|---|
| GitLab | `http://<NODE-IP>:<GITLAB-PORT>` | `root` / password from step 2d |
| Adminer | `http://<NODE-IP>:<ADMINER-PORT>` | server: `postgres`, user: `gitlab`, password: `gitlab-lab-password`, db: `gitlabhq_production` |

**Tear down:**
```bash
helm uninstall gitlab -n gitlab
kubectl delete -f gitlab/
```

<details>
<summary>What's in gitlab/</summary>

| File | Contents |
|---|---|
| `00-namespace.yaml` | `gitlab` namespace |
| `postgres.yaml` | PostgreSQL 15 `Deployment` + `Service` + `PVC` + password `Secret` |
| `adminer.yaml` | Adminer `Deployment` + `Service` |
| `gitlab-values.yaml` | Base Helm values — external PostgreSQL, no nginx-ingress, no cert-manager, no registry |
| `gateway.yaml` | `EnvoyProxy` (NodePort) + `Gateway` + `HTTPRoute` for GitLab and Adminer |

</details>

---

## Lab 3 — Network Policies: GitLab (built-in via Helm)

The GitLab Helm chart includes network policies for every component. They are not active by default — `gitlab/labs/netpol-values.yaml` adds the required configuration on top of the base values.

Enable them with a Helm upgrade:

```bash
helm upgrade gitlab gitlab/gitlab \
  -n gitlab \
  -f gitlab/gitlab-values.yaml \
  -f gitlab/labs/netpol-values.yaml \
  --timeout 600s
```

### Verify the policies were created

```bash
kubectl get networkpolicy -n gitlab
```

You will see one policy per component (webservice, sidekiq, gitaly, kas, etc.).

### Inspect a policy

```bash
kubectl describe networkpolicy gitlab-webservice-default -n gitlab
```

Read the `Ingress` and `Egress` sections — they show exactly which ports and pod selectors are allowed. Notice that every component only permits the traffic it strictly needs.

---

## Lab 4 — Network Policies: Valkey (hand-crafted)

In Demo 1 the Valkey namespace has no network policies — any pod in the cluster can reach Valkey. This lab locks it down using hand-written policies based on pod labels.

### Understand the labels

We added extra labels to both deployments so our policies can be precise and readable:

| Pod | Key labels |
|---|---|
| `valkey` | `app=valkey`, `role=cache`, `tier=backend` |
| `redis-commander` | `app=redis-commander`, `role=ui`, `tier=frontend` |

Verify them on the running pods:
```bash
kubectl get pods -n valkey-demo --show-labels
```

### Traffic model

```
Browser → Envoy (envoy-gateway-system ns) → redis-commander:8081 → valkey:6379
```

The policies enforce exactly this path and nothing else.

### Apply the network policies

```bash
kubectl apply -f valkey-demo/labs/netpol.yaml
```

### What was applied

```bash
kubectl get networkpolicy -n valkey-demo
```

| Policy | Effect |
|---|---|
| `default-deny-ingress` | Blocks all ingress to every pod in the namespace by default |
| `allow-gateway-to-redis-commander` | Allows Envoy pods (from `envoy-gateway-system`) into `redis-commander` on port 8081 |
| `allow-redis-commander-to-valkey` | Allows `redis-commander` into `valkey` on port 6379 (ingress side on valkey) |
| `allow-dns-egress` | Allows all pods to reach DNS on port 53 so service names resolve |
| `allow-redis-commander-egress-to-valkey` | Allows `redis-commander` to dial out to `valkey:6379` (egress side) |

> **Why two policies for the same connection?**
> NetworkPolicy is directional. The ingress rule on `valkey` permits the connection arriving. But as soon as any `Egress` policy exists in the namespace (the DNS one), Kubernetes enforces egress on *all* pods — so `redis-commander` also needs an explicit egress allowance, otherwise its outbound traffic to Valkey is silently dropped.

Verify Redis Commander still works in your browser after applying the policies.

---

## Lab 5 — Testing and monitoring network policies

### View all policies in the cluster

```bash
kubectl get networkpolicy -A
```

### Inspect a specific policy

```bash
kubectl describe networkpolicy allow-redis-commander-to-valkey -n valkey-demo
```

### Test: allowed connection (should succeed)

Spawn a temporary pod with the same labels as redis-commander and try to reach Valkey:

```bash
kubectl run test-allowed -n valkey-demo --rm -it --restart=Never \
  --labels="app=redis-commander,role=ui" \
  --image=nicolaka/netshoot -- \
  nc -zv valkey 6379
```

Expected: `valkey [172.x.x.x] 6379 (redis) open`

### Test: blocked connection (should fail)

Spawn a pod with no matching labels — it must not reach Valkey:

```bash
kubectl run test-blocked -n valkey-demo --rm -it --restart=Never \
  --image=nicolaka/netshoot -- \
  nc -zv -w3 valkey 6379
```

Expected: connection times out after 3 seconds.

### Test: blocked cross-namespace connection

Try from outside the namespace entirely (default namespace):

```bash
kubectl run test-cross-ns --rm -it --restart=Never \
  --image=nicolaka/netshoot -- \
  nc -zv -w3 valkey.valkey-demo.svc.cluster.local 6379
```

Expected: connection times out.

### Monitor events

```bash
kubectl get events -n valkey-demo -w
```

> **Note:** Dropped packet visibility at the event level depends on the CNI. k0s ships with kube-router which enforces NetworkPolicy. For richer observability (per-flow logs, a policy map UI) consider Cilium as the CNI.


**To tear down the cluster entirely:**
```bash
sudo k0s stop
sudo k0s reset
```