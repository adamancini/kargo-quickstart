# Kargo + Akuity Platform Quickstart

This repository extends the [Kargo Quickstart tutorial](https://docs.akuity.io/tutorials/kargo-quickstart/) with a real-world fediverse deployment: [Akkoma](https://akkoma.social) (an ActivityPub/Mastodon-compatible social server) and [soju](https://soju.im) (an IRC bouncer), promoted through **dev → staging → prod** using Kargo on the Akuity Platform.

---

## Repository Layout

```
akuity/               # ArgoCD instance config (applied via `akuity argocd apply`)
  argocd.yaml         # ArgoCD instance definition
  cluster.yaml        # Registered cluster
  akkoma-appset.yaml  # ApplicationSet for akkoma (all stages)
  soju-appset.yaml    # ApplicationSet for soju (all stages)
  cert-manager-app.yaml       # Infrastructure: cert-manager
  cluster-issuers-app.yaml    # Infrastructure: ClusterIssuers
  guestbook-app-set.yaml      # Tutorial guestbook (baseline example)

kargo/
  akkoma/
    project.yaml      # Kargo Project + auto-promote policy
    warehouse.yaml    # Watches ghcr.io/adamancini/charts/{akkoma,soju}
    stages.yaml       # dev, staging, prod Stage definitions

infra/cert-manager/
  cluster-issuers.yaml  # Self-signed CA chain + letsencrypt ClusterIssuer

argocd-rbac.yaml      # ClusterRole for argocd-application-controller
app/                  # Kustomize overlays for guestbook (tutorial baseline)
```

---

## Architecture

```
                        Akuity Cloud
                   ┌─────────────────────┐
                   │  ArgoCD Control     │
                   │  Plane (cplane)     │
                   │  my-argocd-instance │
                   └────────┬────────────┘
                            │ ArgoCD API
                   ┌────────▼────────────┐
Local Cluster      │  akuity namespace   │
(k3d)              │  ├─ app-controller  │
                   │  │   └─ syncer      │◄── proxies via localhost:8001
                   │  ├─ repo-server     │
                   │  └─ redis           │
                   └────────┬────────────┘
                            │ Syncs to namespaces:
               ┌────────────┼────────────┐
          akkoma-dev    akkoma-staging  akkoma-prod
          soju-dev      soju-staging    soju-prod
          cert-manager
```

**Key Akuity Platform detail:** ArgoCD runs locally in the `akuity` namespace, not `argocd`. However, its service account identity is still `system:serviceaccount:argocd:argocd-application-controller` — RBAC on the cluster must use that subject (see Bug 1).

### Promotion Pipeline

```
Warehouse (akkoma-charts)
  watches: oci://ghcr.io/adamancini/charts/{akkoma,soju}
       │
       ▼  auto-promote
      dev  ──────────────────────────────────────────────►  argocd-update only
       │
       ▼  manual promote
    staging  ─────────────────────────────────────────────►  argocd-update only
       │
       ▼  manual promote
      prod  ────────────────────────────────────────────────►  git-writeback + argocd-update
```

The prod stage writes promoted chart versions back to `akuity/akkoma-appset.yaml` and `akuity/soju-appset.yaml` in git, so the AppSet bootstrap version stays current with what Kargo last approved.

---

## Applications Deployed

| Application | Chart | Registry | Notes |
|---|---|---|---|
| akkoma | `akkoma` | `ghcr.io/adamancini/charts` | ActivityPub server, embedded postgres |
| soju | `soju` | `ghcr.io/adamancini/charts` | IRC bouncer with gamja web client |
| cert-manager | `cert-manager` | `charts.jetstack.io` | CRDs installed via `crds.enabled: true` |
| ClusterIssuers | raw manifests | this repo | Self-signed CA chain named `letsencrypt` |

### Stages and Domains

| Stage | Akkoma domain | Soju domain | Storage class |
|---|---|---|---|
| dev | `akkoma.dev.annarchy.net` | `irc.dev.annarchy.net` | `local-path` |
| staging | `akkoma.staging.annarchy.net` | `irc.staging.annarchy.net` | `local-path` |
| prod | `akkoma.annarchy.net` | `irc.annarchy.net` | `local-path` |

---

## Key Design Decisions and Tradeoffs

### 1. Single Kargo project for two apps (`akkoma`)

Both akkoma and soju are promoted together from one Warehouse and one set of Stages. They share a deployment cadence — soju is akkoma's companion IRC bouncer, so it makes sense to keep them in lock-step. A separate Kargo project per app would give independent promotion control at the cost of more coordination overhead.

### 2. ApplicationSet with `ignoreApplicationDifferences`

The AppSet controller normally reconciles `targetRevision` back to the template value on every sync, which would immediately undo Kargo's promotions. Adding `ignoreApplicationDifferences` on `/spec/source/targetRevision` tells the AppSet controller to leave that field alone — Kargo owns it exclusively via `argocd-update`.

The template still has a hardcoded concrete version (e.g. `0.4.4`) so fresh Application creates are clean. Kargo overwrites it on the next promotion cycle.

### 3. Git-writeback only on prod

The prod stage runs `git-clone` → `yaml-update` → `git-commit` → `git-push` to write the promoted chart version back into the AppSet YAML files before calling `argocd-update`. Dev and staging do not do this — writing a dev-only version into the AppSet file would regress the "last known good" bootstrap version tracked in git.

Tradeoff: git history for AppSet version bumps is slightly noisy (automated commits), but fresh cluster installs always start from the last prod-approved version rather than a stale pinned constant.

### 4. Self-signed ClusterIssuer named `letsencrypt`

The cert-manager ClusterIssuer chain uses a self-signed CA but is named `letsencrypt`. This means all chart annotations and Ingress TLS config (`cert-manager.io/cluster-issuer: letsencrypt`) work without modification when swapping to a real ACME issuer — just replace the ClusterIssuer spec.

Tradeoff: browsers will show certificate warnings since the CA is not trusted. Acceptable for local k3d.

### 5. Explicit secrets in `helm.valuesObject`

To prevent postgres password drift (see Bug 8), stable secret values are set directly in the AppSet's `valuesObject`. ArgoCD renders charts via `helm template` (not `helm upgrade`), which does not invoke Helm's `lookup` function — so charts that generate random secrets on first install will regenerate them on every ArgoCD sync.

**Security tradeoff:** Secrets are in plaintext in git. This is acceptable only for a local quickstart. For production: use SOPS/Sealed Secrets or the chart's `existingSecret` options backed by an external secrets manager.

### 6. Cluster name over `kubernetes.default.svc`

All AppSet destinations use `name: kargo-quickstart` instead of `server: https://kubernetes.default.svc`. On Akuity's hosted ArgoCD, `kubernetes.default.svc` resolves to Akuity's own cloud cluster, not the registered user cluster. Using the cluster name is unambiguous.

---

## Assumptions

- Cluster is running k3d with Traefik pre-installed in `kube-system` (k3d default).
- Kargo has credentials to push to GitHub (for git-writeback on prod) and pull from `ghcr.io/adamancini/charts`.
- All three stages run on the same k3d cluster (different namespaces only). k3d ships with `local-path` as the only storage class, so all stages use it.
- The Kargo project is named `akkoma` and the ArgoCD Application names follow `akkoma-<stage>` / `soju-<stage>` patterns.

---

## Quick Reference

```bash
# Apply ArgoCD instance config
akuity argocd apply -f akuity

# Apply Kargo resources
kargo apply -f kargo
kargo apply -f kargo/akkoma

# Verify namespace RBAC
kubectl auth can-i get namespaces \
  --as=system:serviceaccount:argocd:argocd-application-controller
# expected: yes

# Check sync status
kubectl get applications -n argocd
kubectl get stages -n akkoma
```

## Local Access (Port Forwarding)

All three stages run on the same k3d cluster. A `Makefile` is provided to forward app ports to localhost for browser access:

```bash
make pf          # start all port forwards
make pf-dev      # akkoma dev only      → http://localhost:4000
make pf-staging  # akkoma staging only  → http://localhost:4001
make pf-prod     # akkoma prod only     → http://localhost:4002
make pf-soju     # soju gamja web IRC   → http://localhost:8080
make pf-stop     # kill all port forwards
make pf-status   # show active forwards
```

**Note:** The `akkoma-dev` Service selector matches both the app pod and the postgres pod (both share `app.kubernetes.io/name=akkoma`). The Makefile uses `app.kubernetes.io/component!=database` to target only the app pod, and resolves the pod name dynamically so it survives pod restarts.

---

## Troubleshooting Notes

These document every non-obvious issue hit during setup, in the order encountered.

### Bug 1: Namespace auto-creation forbidden

**Error:** `namespaces "akkoma-dev" is forbidden: User "system:serviceaccount:argocd:argocd-application-controller" cannot get resource "namespaces"`

**Cause:** Akuity's agent sidecar authenticates to the cluster using this identity. The `argocd` namespace does not exist locally (ArgoCD runs in `akuity`), but the service account subject name still includes `namespace: argocd`. The cluster had no RBAC for this identity.

**Fix:** `argocd-rbac.yaml` — ClusterRole + ClusterRoleBinding granting namespace CRUD to `system:serviceaccount:argocd:argocd-application-controller`.

---

### Bug 2: `kubernetes.default.svc` targets wrong cluster

**Symptom:** Namespace forbidden error persisted even after fixing RBAC.

**Cause:** On Akuity's hosted ArgoCD, `server: https://kubernetes.default.svc` maps to Akuity's cloud `in-cluster` credentials, not the user's registered cluster. The guestbook AppSet hints at this by explicitly excluding `in-cluster` from its generator.

**Fix:** Replace `server: https://kubernetes.default.svc` with `name: kargo-quickstart` in all AppSet `destination` blocks.

---

### Bug 3: `authorized-stage` annotation wrong project name

**Error:** `Argo CD Application "akkoma-dev" in namespace "argocd" is not authorized`

**Cause:** AppSet had `kargo.akuity.io/authorized-stage: "fediverse:{{stage}}"` — the Kargo project name was wrong (it's `akkoma`, not `fediverse`). The annotation format is `<kargo-project-name>:<stage>`.

**Fix:** Change annotation to `"akkoma:{{stage}}"`.

---

### Bug 4: Wrong template syntax in Kargo stage steps

**Error:** `unable to find Argo CD Application "akkoma-{{ctx.stage}}"` (literal string, not interpolated)

**Cause:** Kargo promotion step config used `{{ctx.stage}}` (ArgoCD AppSet syntax). Kargo uses a different expression syntax.

**Fix:** Replace all `{{ctx.stage}}` with `${{ ctx.stage }}` in `kargo/akkoma/stages.yaml`.

**Rule:** ArgoCD AppSet templates use `{{var}}` | Kargo step expressions use `${{ expr }}`

---

### Bug 5: ServiceMonitor CRD not installed

**Error:** `kind: ServiceMonitor — the server could not find the requested resource` → `synchronization tasks are not valid`

**Cause:** `metrics.serviceMonitor.enabled: true` and `metrics.grafana.enabled: true` were on by default. Neither Prometheus Operator nor Grafana Operator is installed.

**Fix:** Set both to `false` in `akuity/akkoma-appset.yaml`.

---

### Bug 6: cert-manager CRDs not installed (soju TLS)

**Error:** `kind: Certificate — the server could not find the requested resource` and pod crash: `failed to listen on "ircs://0.0.0.0:6697": missing TLS configuration`

**Cause:** soju's `certificate.enabled: true` emits a `cert-manager.io/v1/Certificate`. cert-manager was not installed. Additionally, `listeners.ircs: true` fails at pod startup without a valid cert in place.

**Fix sequence:**
1. Temporarily disable `certificate.enabled` and `listeners.ircs`.
2. Deploy cert-manager (`akuity/cert-manager-app.yaml`) from `https://charts.jetstack.io` with `crds.enabled: true`.
3. Deploy ClusterIssuers (`akuity/cluster-issuers-app.yaml`) from `infra/cert-manager/`.
4. Re-enable `certificate.enabled: true` and `listeners.ircs: true`.

**ClusterIssuer chain:** `selfsigned-root` (selfSigned) → issues CA cert `selfsigned-ca` → `letsencrypt` ClusterIssuer (CA type). Swap the `letsencrypt` issuer spec to ACME for production.

---

### Bug 7: Akkoma ingress not configured

**Fix:** Add to `akuity/akkoma-appset.yaml` under `helm.valuesObject`:
```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  tls:
    enabled: true
    secretName: akkoma-tls
```

Traefik was already present in `kube-system` (k3d default) — no additional install needed.

---

### Bug 8: Postgres password drift on every ArgoCD sync

**Error:** `FATAL 28P01 (invalid_password) password authentication failed for user "akkoma"` — recurring after every sync.

**Cause:** ArgoCD renders Helm charts via `helm template`, not `helm upgrade`. Helm's `lookup` function (used by akkoma's chart to preserve the existing postgres password) **never runs** during `helm template`. Every sync re-renders a fresh random password into the Secret, which does not match the password postgres already has on-disk.

**Fixes (escalating):**

| Approach | When to use |
|---|---|
| `kubectl exec psql ALTER USER akkoma PASSWORD '...'` | Emergency one-off fix |
| `ignoreDifferences` + `RespectIgnoreDifferences=true` on the Secret | Interim — suppresses drift detection |
| Explicit stable values in `helm.valuesObject` (current) | Preferred — deterministic renders, no drift |
| Chart `existingSecret` + external secrets manager | Production-grade |

Current approach: `secrets.*` and `postgresql.password` are set to stable values directly in the AppSet, so `helm template` output is deterministic.

---

### Pain Point: AppSet controller overwrites Kargo-managed `targetRevision`

**Problem:** The ApplicationSet controller reconciles Application specs back to the template on every cycle. After Kargo promotes `akkoma-dev` to chart version `0.4.4`, the AppSet sees the live Application has drifted from the template and reverts `targetRevision`, leaving the Application perpetually `OutOfSync`.

**Fix:**
1. Pin a concrete version in the AppSet template (`targetRevision: "0.4.4"`) — not a wildcard.
2. Add `ignoreApplicationDifferences` to the AppSet spec:

```yaml
spec:
  ignoreApplicationDifferences:
    - jsonPointers:
        - /spec/source/targetRevision
```

**Ownership model:** AppSet owns all Application config _except_ `targetRevision`. Kargo exclusively owns `targetRevision` via `argocd-update`.

**Git-writeback (prod only):** The prod Stage promotion writes the new version back to the AppSet YAML in git before calling `argocd-update`, keeping the bootstrap version current with the last Kargo-approved release.

---

### Akuity admission webhook

**Context:** The webhook at `apphook.argocd.akuity.io` blocks the cluster agent SA from patching Application specs. This appears in logs when ArgoCD tries to normalize a resolved `targetRevision`. It is by design — Akuity prevents cluster agents from overwriting CI/CD-managed Application definitions. This does **not** block Kargo's `argocd-update` step, which goes through the ArgoCD API directly. The error clears once Kargo has promoted at least once and set a concrete `targetRevision`.

---

## Enhancements Beyond the Base Tutorial

- **Real applications:** Replaced the guestbook with akkoma (ActivityPub) and soju (IRC bouncer) — two interrelated fediverse services promoted together as a unit.
- **Custom OCI Helm charts:** Charts at `ghcr.io/adamancini/charts` support explicit secret values to prevent drift under ArgoCD's `helm template` rendering.
- **Infrastructure-as-code:** cert-manager and ClusterIssuers managed as ArgoCD Applications alongside app workloads.
- **Git-writeback on prod:** Kargo's prod Stage writes promoted versions back to git, keeping the AppSet bootstrap version in sync with last prod-approved.
- **Auto-promotion for dev:** dev auto-promotes on new freight; staging and prod require manual approval.
- **Per-stage parameterization:** Storage class and domain are parameterized per stage via the AppSet generator list.
