# Lab — Policy enforcement with Kyverno

Kyverno is a policy engine for Kubernetes. Policies are plain Kubernetes resources — no new language to learn. They intercept every admission request and can **validate**, **mutate**, or **generate** resources.

## The three policy actions

| Action | What it does | Developer visibility |
|---|---|---|
| **Validate** | Checks a resource against a rule. Blocks it (`Enforce`) or logs it (`Audit`). | Blocked deployments show a clear error message |
| **Mutate** | Modifies a resource silently before it is saved to etcd | Transparent — developers can inspect the live pod spec to see what was added |
| **Generate** | Creates a new resource when a trigger event occurs (e.g. namespace created) | Automatic — no action needed from the developer |

## Policy modes

| Mode | Behaviour |
|---|---|
| `Audit` | Violations are recorded in a `PolicyReport` but the resource is still created. Use this first to measure impact. |
| `Enforce` | Violations block admission — the resource is rejected with a human-readable error. |

> **Lab strategy:** the mutate policy and the resource-limit cap are set to `Enforce` immediately (safe, demos already comply). All other validate policies start in `Audit` — observe the reports before deciding to enforce.

---

## Install Kyverno

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

## Apply all policies

```bash
kubectl apply -f kyverno/policies/
```

Verify they were created:
```bash
kubectl get clusterpolicy
```

You should see all policies listed with their action (`Enforce` or `Audit`) in the `VALIDATIONFAILUREACTION` column.

---

## Policy 1 — Mutate: inject default resource requests and limits

**File:** `policies/mutate-default-resources.yaml`

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

## Policy 2 — Validate (Enforce): hard cap on resource limits

**File:** `policies/validate-resource-limits.yaml`

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

## Policy 3 — Validate (Audit): block NodePort services

**File:** `policies/validate-block-nodeport.yaml`

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

## Policy 4 — Validate (Audit): forbid the `latest` tag

**File:** `policies/validate-no-latest-tag.yaml`

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

## Policy 5 — Validate (Audit): approved image registries

**File:** `policies/validate-allowed-registries.yaml`

Only images from approved registries are allowed. Lab-approved list:

| Registry | Usage |
|---|---|
| `docker.io` | Docker Hub (used by lab demos) |
| `ghcr.io` | GitHub Container Registry |
| `registry.k8s.io` | Official Kubernetes images |
| `quay.io` | Red Hat Quay |

Edit the policy file to match your organisation's approved registries before switching to `Enforce`.

---

## Policy 6 — Validate (Audit): require liveness and readiness probes

**File:** `policies/validate-require-probes.yaml`

Without probes, Kubernetes cannot detect a stuck application and routes traffic to pods before they are ready. This policy is in `Audit` — our lab demos do not define probes, so the report will show violations. Use this to prioritise which workloads to fix first.

**See all probe violations:**
```bash
kubectl get policyreport -A -o yaml | grep -B2 "policy: validate-require-probes"
```

---

## Policy 7 — Generate: default-deny NetworkPolicy on namespace creation

**File:** `policies/generate-default-deny-netpol.yaml`

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

## Policy 8 — Pod Security Standards (native Kubernetes)

**File:** `policies/pss-example-namespace.yaml`

Kubernetes ships built-in pod security profiles applied via namespace labels — no Kyverno required.

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

## Reading policy reports

All `Audit` violations are collected in `PolicyReport` resources (namespaced) and a `ClusterPolicyReport` (cluster-scoped).

### Policy Reporter — web UI

The official [Policy Reporter](https://kyverno.github.io/policy-reporter/) project provides a web dashboard that shows all violations across namespaces with filtering, charts, and per-policy drill-down.

Install it:
```bash
helm repo add policy-reporter https://kyverno.github.io/policy-reporter
helm repo update policy-reporter
helm install policy-reporter policy-reporter/policy-reporter \
  -n policy-reporter \
  --create-namespace \
  --set ui.enabled=true \
  --set plugin.kyverno.enabled=true
```

Access the UI via the shared Gateway (port 9090):
```bash
# Find the NodePort for port 9090
kubectl get svc -n envoy-gateway-system | grep shared-gateway
# Access at http://<node-ip>:<nodeport>
```

Apply the companion network policies and HTTPRoute immediately after install:
```bash
kubectl apply -f kyverno/policy-reporter-netpol.yaml
kubectl apply -f kyverno/policy-reporter-route.yaml
```

### With kubectl (quick checks)

```bash
# Summary across all namespaces
kubectl get policyreport -A

# Filter by policy name
kubectl get policyreport -A -o json | jq \
  '.items[].results[] | select(.policy == "validate-no-latest-tag")'
```

### With the Kyverno CLI (offline / CI)

Test policies locally against manifests before applying them to the cluster — no running cluster needed:

```bash
# Test one policy against one manifest
kyverno apply kyverno/policies/validate-no-latest-tag.yaml \
  --resource valkey-demo/app.yaml

# Test all policies against a folder of manifests
kyverno apply kyverno/policies/ \
  --resource valkey-demo/
```

The output shows each rule result — `pass`, `fail`, or `skip` — with the violation message. Use this in CI pipelines to catch violations before resources ever reach the cluster.
