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

**`kubectl`** is the standard Kubernetes CLI — all commands in this lab use it.

**`k9s`** is a terminal UI that lets you navigate cluster resources interactively without typing long `kubectl` commands. Launch it with `k9s`, then use `:` to switch resource type (e.g. `:pods`, `:namespaces`), `/` to filter, `d` to describe, and `l` for logs.

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

---

## Lab 6 — Policy enforcement with Kyverno

Kyverno is a policy engine for Kubernetes. Policies are plain Kubernetes resources — no new language to learn. They intercept every admission request and can **validate**, **mutate**, or **generate** resources.

### The three policy actions

| Action | What it does | Developer visibility |
|---|---|---|
| **Validate** | Checks a resource against a rule. Blocks it (`Enforce`) or logs it (`Audit`). | Blocked deployments show a clear error message |
| **Mutate** | Modifies a resource silently before it is saved to etcd | Transparent — developers can inspect the live pod spec to see what was added |
| **Generate** | Creates a new resource when a trigger event occurs (e.g. namespace created) | Automatic — no action needed from the developer |

### Policy modes

| Mode | Behaviour |
|---|---|
| `Audit` | Violations are recorded in a `PolicyReport` but the resource is still created. Use this first to measure impact. |
| `Enforce` | Violations block admission — the resource is rejected with a human-readable error. |

> **Lab strategy:** the mutate policy and the resource-limit cap are set to `Enforce` immediately (safe, demos already comply). All other validate policies start in `Audit` — observe the reports before deciding to enforce.

---

### 6a — Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  -n kyverno \
  --create-namespace
```

Wait for Kyverno to be ready:
```bash
kubectl get pods -n kyverno -w
```

### 6b — Apply all policies

```bash
kubectl apply -f kyverno/policies/
```

Verify they were created:
```bash
kubectl get clusterpolicy
```

You should see all policies listed with their action (`Enforce` or `Audit`) in the `VALIDATIONFAILUREACTION` column.

---

### Policy 1 — Mutate: inject default resource requests and limits

**File:** `kyverno/policies/mutate-default-resources.yaml`

If a container does not define `requests` or `limits`, Kyverno patches the pod spec silently before it is written to etcd. The `+` operator means "only set if absent" — it never overwrites values a developer has explicitly defined.

| Field | Injected default |
|---|---|
| `requests.cpu` | `100m` |
| `requests.memory` | `128Mi` |
| `limits.cpu` | `500m` |
| `limits.memory` | `256Mi` |

**Test it:** deploy a pod without resource definitions and inspect the live spec:

```bash
kubectl run test-mutate --image=nginx:1.25 -n valkey-demo
kubectl get pod test-mutate -n valkey-demo -o jsonpath='{.spec.containers[0].resources}' | jq
kubectl delete pod test-mutate -n valkey-demo
```

The output will show the injected defaults even though you never specified them.

---

### Policy 2 — Validate (Enforce): hard cap on resource limits

**File:** `kyverno/policies/validate-resource-limits.yaml`

Blocks any container that declares more than **2 CPU** or **4 Gi RAM** in its limits. Complements the mutate policy: mutation adds safe defaults, this policy rejects anything that explicitly asks for too much.

**Test — should be rejected:**

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-limits
  namespace: valkey-demo
spec:
  containers:
    - name: hungry
      image: nginx:1.25
      resources:
        limits:
          cpu: "8"
          memory: "8Gi"
YAML
```

Expected: admission blocked with `Resource limits are too high. Max allowed: 2 CPU / 4Gi RAM.`

---

### Policy 3 — Validate (Audit): block NodePort services

**File:** `kyverno/policies/validate-block-nodeport.yaml`

All external traffic must go through an `HTTPRoute` on a managed Gateway — not through raw NodePort. Set to `Audit` because Envoy Gateway itself creates NodePort services in `envoy-gateway-system` (excluded by the policy).

**See current violations:**
```bash
kubectl get policyreport -A
kubectl describe policyreport -n valkey-demo
```

**Switch to Enforce when ready:**
```bash
kubectl patch clusterpolicy validate-block-nodeport \
  --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
```

---

### Policy 4 — Validate (Audit): forbid the `latest` tag

**File:** `kyverno/policies/validate-no-latest-tag.yaml`

Using `latest` makes deployments non-reproducible: two identical manifests applied at different times may run different code. This policy flags any container image using `:latest` or no tag at all.

Our `redis-commander` deployment currently uses `latest` — you will see it in the audit report.

**See the violation:**
```bash
kubectl get policyreport -n valkey-demo -o yaml | grep -A5 "policy: validate-no-latest-tag"
```

**Fix it** by pinning the tag in `valkey-demo/app.yaml`:
```yaml
# Before
image: rediscommander/redis-commander:latest
# After
image: rediscommander/redis-commander:0.8.0
```

---

### Policy 5 — Validate (Audit): approved image registries

**File:** `kyverno/policies/validate-allowed-registries.yaml`

Only images from approved registries are allowed. Lab-approved list:

| Registry | Usage |
|---|---|
| `docker.io` | Docker Hub (used by lab demos) |
| `ghcr.io` | GitHub Container Registry |
| `registry.k8s.io` | Official Kubernetes images |
| `quay.io` | Red Hat Quay |

Edit the policy file to match your organisation's approved registries before switching to `Enforce`.

---

### Policy 6 — Validate (Audit): require liveness and readiness probes

**File:** `kyverno/policies/validate-require-probes.yaml`

Without probes, Kubernetes cannot detect a stuck application and routes traffic to pods before they are ready. This policy is in `Audit` — our lab demos do not define probes, so the report will show violations. Use this to prioritise which workloads to fix first.

**See all probe violations:**
```bash
kubectl get policyreport -A -o yaml | grep -B2 "policy: validate-require-probes"
```

---

### Policy 7 — Generate: default-deny NetworkPolicy on namespace creation

**File:** `kyverno/policies/generate-default-deny-netpol.yaml`

When a new namespace is created, Kyverno automatically generates a `default-deny-all` NetworkPolicy in it. Zero-trust by default: all ingress and egress is blocked until an explicit policy allows it.

**Test it:**
```bash
kubectl create namespace test-generate
kubectl get networkpolicy -n test-generate
```

Expected: a `default-deny-all` NetworkPolicy appears immediately, labelled `generated-by: kyverno`.

```bash
kubectl delete namespace test-generate
```

---

### Policy 8 — Pod Security Standards (native Kubernetes)

**File:** `kyverno/policies/pss-example-namespace.yaml`

Kubernetes ships built-in pod security profiles applied via namespace labels. No Kyverno required for this.

| Label | Profile | Effect |
|---|---|---|
| `enforce: baseline` | Baseline | Blocks privileged containers, hostPID, hostNetwork, etc. at admission |
| `warn: restricted` | Restricted | Prints a warning for anything not meeting the stricter hardened profile |

Apply to your own namespace:
```bash
kubectl label namespace valkey-demo \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted
```

Test that a privileged pod is blocked:
```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-pss
  namespace: valkey-demo
spec:
  containers:
    - name: priv
      image: nginx:1.25
      securityContext:
        privileged: true
YAML
```

Expected: blocked with `violates PodSecurity "baseline"`.

---

### Reading policy reports

All `Audit` violations are collected in `PolicyReport` resources (namespaced) and a `ClusterPolicyReport` (cluster-scoped).

**With kubectl:**
```bash
# Summary across all namespaces
kubectl get policyreport -A

# Detailed results for one namespace
kubectl describe policyreport -n valkey-demo

# Filter by policy name
kubectl get policyreport -A -o json | jq \
  '.items[].results[] | select(.policy == "validate-no-latest-tag")'
```

**With the Kyverno CLI (`kyverno`):**

The Kyverno CLI lets you test policies locally against manifests before applying them to the cluster — no running cluster needed.

Test a policy against a manifest file:
```bash
kyverno apply kyverno/policies/validate-no-latest-tag.yaml \
  --resource valkey-demo/app.yaml
```

Test all policies at once against a folder of manifests:
```bash
kyverno apply kyverno/policies/ \
  --resource valkey-demo/
```

The output shows each rule result — `pass`, `fail`, or `skip` — with the violation message. Use this in CI pipelines to catch policy violations before resources ever reach the cluster.

Each result includes the resource name, rule name, violation message, and timestamp.


**To tear down the cluster entirely:**
```bash
sudo k0s stop
sudo k0s reset
```