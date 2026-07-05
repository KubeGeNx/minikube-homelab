# Minikube Homelab Platform

A GitOps-managed platform stack on Minikube: bootstrap Minikube + Argo CD with a
script, then let Argo CD (app-of-apps pattern) declaratively install and
reconcile everything else — networking, security, storage, observability, and
backup.

## Architecture

```
install-prereqs.sh -> scripts/00-prereqs.sh   installs Homebrew (if missing) + minikube/kubectl/helm/envsubst/jq/python3

bootstrap.sh
 ├─ scripts/00-prereqs.sh           same script as install-prereqs.sh
 ├─ scripts/01-minikube.sh          starts Minikube (defaults: 6 CPU / 36GB RAM, override via MINIKUBE_CPUS / MINIKUBE_MEMORY)
 ├─ scripts/02-foundational-crds.sh Gateway API CRDs + VolumeSnapshot CRDs/controller
 ├─ scripts/03-argocd.sh            installs Argo CD via Helm
 └─ scripts/04-apply-apps.sh        applies namespaces + the platform ApplicationSet
      └─ scripts/build-applicationset.sh -> build-applicationset.py
           reads gitops/apps/*.yaml + versions.env + components.env,
           writes ONE ApplicationSet to gitops/rendered/applicationset.yaml
```

**The platform ApplicationSet is the parent resource that controls
everything below Argo CD.** `gitops/apps/*.yaml` holds one file per
component (chart repo, chart name, Helm values) -- these are the *source*
files, never applied directly. `build-applicationset.py` reads all of them
plus `versions.env` (which version) and `components.env` (which components
are enabled) and generates a single Argo CD `ApplicationSet` with a List
generator: one element per **enabled** component. `04-apply-apps.sh`
`kubectl apply`s that one generated file.

From there it's entirely Argo CD's job. The `applicationset-controller`
(part of the standard Argo CD Helm chart) reconciles the set of child
`Application` resources to match the generator's element list — creating,
updating, or deleting them as `versions.env`/`components.env` change and you
re-run `04-apply-apps.sh`. Every generated child has
`syncPolicy.automated.{prune,selfHeal}` and the
`resources-finalizer.argocd.argoproj.io` finalizer, so it stays reconciled
to its chart and cascades cleanly if removed.

### Versions, components, and config — three files, one rebuild step

Everything about a component lives in exactly one of three places:

| What | Where | Example |
|---|---|---|
| Which chart version | `versions.env` | `CERT_MANAGER_VERSION=v1.15.3` |
| Whether it's installed at all | `components.env` | `MINIO_ENABLED=true` |
| Chart repo, chart name, Helm values | `gitops/apps/<component>.yaml` | `01-cert-manager.yaml`'s `spec.source` |

**After changing any of the three, rebuild and re-apply the ApplicationSet:**

```bash
./scripts/04-apply-apps.sh
```

This regenerates `gitops/rendered/applicationset.yaml` from the current
state of all three inputs and applies it. Argo CD's applicationset-controller
then does the actual work — diffing the new element list against what
currently exists and creating, deleting, or updating child `Application`
objects as needed:

- **Bump a version** (edit `versions.env`, or run `./update-versions.sh` to
  do it automatically) → the matching child `Application`'s `targetRevision`
  changes → Argo CD's `selfHeal` reconciles it to the new chart version. Only
  that one component restarts; everything else is untouched since its
  generated `Application` spec didn't change.
- **Change a component's config** (edit its `values:` block in
  `gitops/apps/<file>.yaml`) → same thing, just that component updates.
- **Turn a component off** (`<NAME>_ENABLED=false` in `components.env`) →
  its element disappears from the list → Argo CD deletes the child
  `Application` → the `resources-finalizer.argocd.argoproj.io` finalizer
  every child carries makes that cascade to the component's actual
  resources (Helm release, namespace contents), not just the `Application`
  object itself.
- **Turn it back on** → flip the flag back, rebuild, re-apply → Argo CD
  recreates it.

Nothing here is a bash script deciding to `kubectl delete` anything — the
ApplicationSet's element list is the desired state, and Argo CD's own
controller is the thing reconciling the cluster to match it, exactly like a
single `Application` does for one Helm release. Review `git diff` on
whichever of the three files you touched before rolling out to a cluster
you care about; not every chart bump is backward compatible (cert-manager in
particular can have breaking CRD changes between minor versions).

Gateway API CRDs and the CSI VolumeSnapshot CRDs/controller are installed
directly by `02-foundational-crds.sh`, not via the ApplicationSet — they're
cluster-wide prerequisites other components depend on at admission time, so
they need to exist first.

Every generated `Application` also gets a `platform-wave` label (from the
`wave` column in `scripts/lib-components.sh`'s component table) and a
matching `argocd.argoproj.io/sync-wave` annotation. The List generator
doesn't stage installs by that wave today — all enabled components sync
concurrently, and Helm/Kubernetes' own retry+backoff resolves ordering
(e.g. a PVC stays `Pending` until its StorageClass exists, then binds), which is fine for a homelab. If you want Argo CD to *enforce*
strict ordering, the label is already there to drive an ApplicationSet
`strategy: RollingSync` with `steps` matching on `platform-wave` — not
wired up here, but `scripts/build-applicationset.py` is where you'd add
`spec.strategy` to the generated ApplicationSet if you want to take this
further.

### What's included (recommended homelab subset)

- **Core**: Minikube, CoreDNS (built-in), Metrics Server. CNI: minikube default, or set `MINIKUBE_CNI=cilium` (or `calico`) before bootstrap — fixed at cluster creation, changing it needs `minikube delete`
- **Networking**: Gateway API, Envoy Gateway (shared TLS'd `platform` Gateway exposing every UI at `https://<app>.lab.local`), cert-manager (SelfSigned → homelab CA `ClusterIssuer`, wildcard `*.lab.local` cert), MetalLB *(disabled by default — `METALLB_ENABLED=false`; see `gitops/apps/02-metallb.yaml`)*
- **Traffic**: Gateway API HTTPRoute/TCPRoute/TLSRoute (experimental channel CRDs installed), sample manifests in `examples/`
- **GitOps**: Argo CD, Helm, Kustomize (available via `kubectl kustomize` / `kustomize` CLI, used ad hoc — no separate install needed)
- **Policy & Security**: External Secrets Operator
- **Storage**: Minikube default hostPath StorageClass, MinIO (object storage), VolumeSnapshot CRDs + CSI Snapshot Controller
- **Observability**: Prometheus, Grafana, Loki, Tempo (traces), Alloy (unified collector: logs → Loki, annotated-pod metrics → Prometheus remote-write, OTLP traces → Tempo), kube-state-metrics, node-exporter. Loki + Tempo are pre-wired as Grafana datasources
- **Backup & DR**: Velero (AWS plugin, file-system backup via node agent), backing up to MinIO. No CSI plugin/snapshots: the standalone CSI plugin was merged into Velero core in 1.14, and Minikube's default hostPath provisioner isn't CSI anyway — `defaultVolumesToFsBackup` is what actually backs up volume data here.
- **Operators**: OLM *(disabled by default — `OLM_ENABLED=false`; official manifests via `scripts/06-olm.sh`, not Helm)*
- **AI / ML**: Kubeflow full suite *(disabled by default — `KUBEFLOW_ENABLED=false`)* — see below, needs extra setup before enabling

### AI / ML: Kubeflow

**Kubeflow** ships in the repo but is off by default — it's the heaviest and
least "just works" component here. It's the full suite (Pipelines, Notebooks, Katib, Training
Operator, KServe, Dashboard). Unlike everything else here, it doesn't
install via a Helm chart — its official path is a git+kustomize bundle
(`kubeflow/manifests`, `example` kustomization), so it doesn't fit the
ApplicationSet's uniform template. It's handled as a standalone Application
at `gitops/special/16-kubeflow.yaml`, controlled by `KUBEFLOW_ENABLED` in
`components.env` but applied/pruned directly by `scripts/04-apply-apps.sh`'s
"Special (non-Helm) components" step rather than going through
`build-applicationset.py`. Two things worth knowing before flipping it on:

- **Resources**: this is heavy on top of everything else in this platform.
  Raise `MINIKUBE_CPUS`/`MINIKUBE_MEMORY` well beyond this repo's default
  6 CPU/36GB, or disable other components to make room, before enabling it.
- **Convergence time**: Kubeflow's manifests are known for needing several
  sync passes on a fresh install (some resources reference CRDs from a
  different part of the bundle that hasn't landed yet). The Application has
  `SkipDryRunOnMissingResource=true`, `ServerSideApply=true`, and a retry/backoff
  policy to handle this — the commonly documented pattern for installing
  Kubeflow via Argo CD — but expect it to take minutes, not seconds, and
  check `kubectl -n argocd get application kubeflow` if it seems stuck.

`./update-versions.sh` doesn't track `KUBEFLOW_VERSION` (a git tag/branch,
not a chart version) — check
[kubeflow/manifests releases](https://github.com/kubeflow/manifests)
manually for that one.

### Deliberately skipped (optional heavy add-ons)

These were in the original wishlist but excluded from the default install to
keep the cluster lean. Each can be added later as its own `gitops/apps/*.yaml`
Application, same pattern as everything else:

- **Falco** (runtime security) — `helm repo add falcosecurity https://falcosecurity.github.io/charts`, chart `falcosecurity/falco`. Heavy (eBPF/kernel module), can destabilize a homelab VM.
- **Sealed Secrets** — `helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets`, chart `sealed-secrets/sealed-secrets`. Redundant with External Secrets Operator unless you specifically want git-committable encrypted secrets.
- **OpenTelemetry Collector** — Alloy already covers OTLP collection here; add the OTel Collector only if you need its processors specifically.

## Prerequisites

- macOS with Docker Desktop (or another Minikube driver) running
- Everything else (Homebrew, `minikube`, `kubectl`, `helm`, `envsubst`, `jq`,
  `python3`) is installed for you by `./install-prereqs.sh` — see below
- At least 6 CPUs / 36GB RAM free for the VM (the defaults — override with
  `MINIKUBE_CPUS` / `MINIKUBE_MEMORY`, e.g. `MINIKUBE_MEMORY=8g` for a
  smoke-test-sized run)

## Usage

```bash
cd minikube-homelab
./install-prereqs.sh   # optional standalone step -- also runs automatically as part of bootstrap.sh
./bootstrap.sh
```

`install-prereqs.sh` installs Homebrew itself if it's missing (non-interactive,
may prompt for your sudo password), then `minikube`, `kubectl`, `helm`,
`envsubst` (via the `gettext` formula), `jq` (used by `update-versions.sh`),
and `python3` (used by `scripts/build-applicationset.py`). Anything already
installed is left alone. Run it standalone any time, or just run
`./bootstrap.sh` directly — it calls the same script as its first step.

`bootstrap.sh` then runs: prereqs → starts Minikube → installs foundational
CRDs (versions from `versions.env`) → installs Argo CD (version from
`versions.env`) → builds the platform ApplicationSet from
`gitops/apps/*.yaml` + `versions.env` + `components.env` → applies
namespaces + that one ApplicationSet.

Get the Argo CD admin password and UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443
# open https://localhost:8080  (user: admin)
```

Watch everything come up:

```bash
kubectl get applications -n argocd
kubectl get pods -A
```

In a second terminal, keep this running so LoadBalancer services (Envoy
Gateway) get real IPs:

```bash
minikube tunnel
```

### Grafana datasources (Loki, Tempo)

`kube-prometheus-stack` already ships Grafana, so `loki-stack`'s own Grafana
is disabled to avoid running two. Loki and Tempo are pre-wired as Grafana
datasources via `additionalDataSources` in
`gitops/apps/08-kube-prometheus-stack.yaml` — nothing manual to do. Note
promtail is disabled in `11-loki-stack.yaml`: Alloy ships pod logs to Loki
(re-enable promtail if you turn Alloy off).

### Gateway API exposure, TLS, and lab.local DNS

`scripts/08-platform-gateway.sh` (run automatically by `04-apply-apps.sh`)
applies a SelfSigned → CA `ClusterIssuer` chain, a wildcard `*.lab.local`
Certificate, one shared `platform` Gateway (Envoy), and an HTTPRoute per
enabled component (`gitops/platform/routes/`):
`https://argocd.lab.local`, `https://grafana.lab.local`,
`https://prometheus.lab.local`, `https://minio.lab.local`,
`https://tempo.lab.local`.

Keep `minikube tunnel` running (docker driver), then point the hostnames at
the Gateway IP — `make hosts` prints the `/etc/hosts` line, or add the same
names to your internal DNS. The TLS chain is signed by the generated
`homelab-root-ca`; export and trust it to silence browser warnings:

```bash
kubectl -n cert-manager get secret homelab-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

To migrate to Let's Encrypt or an internal PKI later, add a new
`ClusterIssuer` and swap the `issuerRef` in `gitops/platform/gateway.yaml`.

### Makefile: per-component installs

Every component has a `make` target that ensures the base platform
(minikube → CRDs → Argo CD) exists, then enables the component **plus its
dependencies** in `components.env` and applies — even if a dependency
wasn't asked for or was previously disabled:

```bash
make velero    # also enables minio (backup target)
make alloy     # also enables kube-prometheus-stack, loki-stack, tempo
make metallb   # then scripts/07-metallb-config.sh sets the address pool
make olm       # official manifests via scripts/06-olm.sh
```

The dependency graph lives in `scripts/enable-component.sh` (`deps_of`).
Other targets: `make bootstrap`, `make apply`, `make gateway`, `make hosts`,
`make status`, `make clean` (keep VM), `make destroy`. Run `make help` for
the full list.

### Finishing Velero's backup target

Velero needs S3 credentials for MinIO. After MinIO's pod is running, run:

```bash
./scripts/05-velero-secret.sh
```

This creates the `velero-minio-credentials` secret in the `velero` namespace
from MinIO's root credentials before Velero's Application syncs (wave 4). In
a more mature setup, External Secrets Operator would manage this instead of a
plain kubectl-created secret — worth migrating to once you're comfortable
with ESO.

### Legacy files: `render-apps.sh` and `root-app.yaml`

Earlier versions of this repo applied one flat `Application` file per
component directly (`scripts/render-apps.sh` + a bash wave-loop), and had an
optional git-backed `gitops/root-app.yaml` app-of-apps for native
prune-on-delete behavior. The platform ApplicationSet now does what both of
those were for — component enable/disable *and* Argo CD-native reconciliation
— without needing a git remote. Both files are still in the repo but aren't
used by `bootstrap.sh` / `04-apply-apps.sh` anymore; `root-app.yaml` is worth
revisiting only if you specifically want a git-audited history of every
rendered manifest (point it at `gitops/rendered/applicationset.yaml` instead
of the old per-app directory, and commit that file after every
`build-applicationset.sh` run).

## Teardown

```bash
./cleanup.sh                  # tear down every component, then delete the Minikube VM entirely
./cleanup.sh --keep-minikube  # tear down components + Argo CD + CRDs, but leave the VM running
./cleanup.sh --yes            # skip the "are you sure" prompt (either mode)
```

It deletes the platform `ApplicationSet` first (which cascades through Argo
CD to every enabled component's actual resources), then sweeps any
`Application` left over from before it had a finalizer or was applied
manually, *then* uninstalls Argo CD, then (by default) deletes the whole
Minikube profile. Order matters — Applications are removed while Argo CD's
controllers are still running so the cascade actually fires; `minikube
delete` at the end guarantees a fully clean slate either way, since nothing
survives the VM going away.

If you'd rather skip the script and just nuke everything in one step:

```bash
minikube delete -p homelab
```

(The `-p homelab` matters — this platform uses the `homelab` profile, so a
bare `minikube delete` would only touch the default profile.)

That alone is equivalent to `./cleanup.sh` with no `--keep-minikube` — the
graceful cascade step is a courtesy, not a requirement, since deleting the
VM removes everything regardless of whether Argo CD finished cleaning up
first.

## Keeping versions current

Versions in `versions.env` were current as of mid-2025 knowledge. Run
`./update-versions.sh` any time to check every component (Helm charts via
`helm search repo`, Envoy Gateway / Gateway API / external-snapshotter via
GitHub releases) against upstream and update `versions.env` in place. It
prints a before/after table and only touches lines that actually changed.
