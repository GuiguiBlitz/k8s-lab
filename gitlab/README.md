# Demo 2 — GitLab CE + PostgreSQL + Adminer

GitLab CE via the official Helm chart, backed by a dedicated PostgreSQL instance. Adminer provides a web UI for the database. Both are exposed via Gateway API using port-based routing.

## Deploy

### 1 — Apply namespace, PostgreSQL and Adminer

```bash
kubectl apply -f gitlab/00-namespace.yaml
kubectl apply -f gitlab/postgres.yaml
kubectl apply -f gitlab/adminer.yaml
```

Verify PostgreSQL starts cleanly:
```bash
kubectl get pods -n gitlab -w
```

### 2 — Install GitLab via Helm

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

### 3 — Apply the Gateway and HTTPRoutes

```bash
kubectl apply -f gitlab/gateway.yaml
```

### 4 — Get the initial root password

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 -d && echo
```

### 5 — Find the node IP and NodePorts

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

### 6 — Access

No `/etc/hosts` changes needed — routing is port-based:

| Service | URL | Credentials |
|---|---|---|
| GitLab | `http://<NODE-IP>:<GITLAB-PORT>` | `root` / password from step 4 |
| Adminer | `http://<NODE-IP>:<ADMINER-PORT>` | server: `postgres`, user: `gitlab`, password: `gitlab-lab-password`, db: `gitlabhq_production` |

**Tear down:**
```bash
helm uninstall gitlab -n gitlab
kubectl delete -f gitlab/
```

<details>
<summary>What's in this folder</summary>

| File | Contents |
|---|---|
| `00-namespace.yaml` | `gitlab` namespace |
| `postgres.yaml` | PostgreSQL 15 `Deployment` + `Service` + `PVC` + password `Secret` |
| `adminer.yaml` | Adminer `Deployment` + `Service` |
| `gitlab-values.yaml` | Base Helm values — external PostgreSQL, no nginx-ingress, no cert-manager, no registry |
| `gateway.yaml` | `EnvoyProxy` (NodePort) + `Gateway` + `HTTPRoute` for GitLab and Adminer |

</details>

---

## Lab — Network Policies (built-in via Helm)

The GitLab Helm chart includes network policies for every component. They are not active in the base install — `labs/netpol-values.yaml` adds the required configuration on top.

### Enable them

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

You will see one policy per component (webservice, sidekiq, gitaly, kas, etc.), each allowing only the traffic that component legitimately needs.

### Inspect a policy

```bash
kubectl describe networkpolicy gitlab-webservice-default -n gitlab
```

Read the `Ingress` and `Egress` sections — they show exactly which ports and pod selectors are allowed.
