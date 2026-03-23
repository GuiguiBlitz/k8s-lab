# Demo 1 — Valkey + Redis Commander

A [Valkey](https://valkey.io/) (Redis-compatible) store and a Redis Commander web UI, exposed via Gateway API.

## Deploy

```bash
kubectl apply -f valkey-demo/
```

Wait for pods to be ready:
```bash
kubectl get pods -n valkey-demo -w
```

Find the access URL:
```bash
# The shared Gateway handles all lab services — find the NodePort for port 8081 (valkey listener)
kubectl get svc -n envoy-gateway-system | grep shared-gateway
```

The `PORT(S)` column shows `8081:<NODEPORT>/TCP` — open `http://<NODE-IP>:<NODEPORT>/` in your browser.

**Tear down:**
```bash
kubectl delete -f valkey-demo/
```

<details>
<summary>What's in this folder</summary>

| File | Contents |
|---|---|
| `00-namespace.yaml` | `valkey-demo` namespace |
| `valkey.yaml` | Valkey `Deployment` + `Service` (port 6379) |
| `app.yaml` | Redis Commander `Deployment` + `Service` |
| `gateway.yaml` | `HTTPRoute` pointing to the shared Gateway in the `gateway` namespace |

</details>

---

## Lab — Network Policies (hand-crafted)

In the base demo, any pod in the cluster can reach Valkey. This lab locks it down using hand-written policies based on pod labels.

### Understand the labels

Both deployments carry extra labels to make policy selectors precise and readable:

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

Verify what was created:
```bash
kubectl get networkpolicy -n valkey-demo
```

| Policy | Effect |
|---|---|
| `default-deny-ingress` | Blocks all ingress to every pod in the namespace by default |
| `allow-gateway-to-redis-commander` | Allows Envoy pods (from `envoy-gateway-system`) into `redis-commander` on port 8081 |
| `allow-redis-commander-to-valkey` | Allows `redis-commander` into `valkey` on port 6379 (ingress side) |
| `allow-dns-egress` | Allows all pods to reach DNS on port 53 so service names resolve |
| `allow-redis-commander-egress-to-valkey` | Allows `redis-commander` to dial out to `valkey:6379` (egress side) |

> **Why two policies for the same connection?**
> NetworkPolicy is directional. The ingress rule on `valkey` permits the connection arriving. But as soon as any `Egress` policy exists in the namespace (the DNS one), Kubernetes enforces egress on *all* pods — so `redis-commander` also needs an explicit egress allowance, otherwise its outbound traffic to Valkey is silently dropped.

Verify Redis Commander still works in your browser after applying the policies.

### Test the policies

**Allowed connection (should succeed):**

Spawn a temporary pod with the same labels as redis-commander:
```bash
kubectl run test-allowed -n valkey-demo --rm -it --restart=Never \
  --labels="app=redis-commander,role=ui" \
  --image=nicolaka/netshoot -- \
  nc -zv valkey 6379
```
Expected: `valkey [172.x.x.x] 6379 (redis) open`

**Blocked connection (should fail):**

Spawn a pod with no matching labels:
```bash
kubectl run test-blocked -n valkey-demo --rm -it --restart=Never \
  --image=nicolaka/netshoot -- \
  nc -zv -w3 valkey 6379
```
Expected: connection times out after 3 seconds.

**Blocked cross-namespace connection:**

Try from outside the namespace (default namespace):
```bash
kubectl run test-cross-ns --rm -it --restart=Never \
  --image=nicolaka/netshoot -- \
  nc -zv -w3 valkey.valkey-demo.svc.cluster.local 6379
```
Expected: connection times out.

**Inspect a policy:**
```bash
kubectl describe networkpolicy allow-redis-commander-to-valkey -n valkey-demo
```

**View all policies in the cluster:**
```bash
kubectl get networkpolicy -A
```

> **Note:** Dropped packet visibility at the event level depends on the CNI. k0s ships with kube-router which enforces NetworkPolicy. For richer observability (per-flow logs, a policy map UI) consider Cilium as the CNI.
