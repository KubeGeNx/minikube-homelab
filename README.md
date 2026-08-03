# Minikube Homelab Platform

A complete Kubernetes platform on your Mac, managed the GitOps way: one
bootstrap command installs Minikube + Argo CD, and Argo CD then installs and
continuously reconciles everything else — networking, TLS, storage,
observability, and backup.

## Quick start

```bash
git clone <this-repo> && cd minikube-homelab
./bootstrap.sh        # or: make bootstrap
```

That's it. Bootstrap installs any missing tools (Homebrew, minikube, kubectl,
helm, jq, python3), starts the cluster (defaults: 6 CPUs / 36 GB RAM), installs
Argo CD, and hands everything else to Argo CD. Watch it come up:

```bash
make status           # Argo CD Applications + all pods
```

Then open the UIs — see [Accessing the UIs](#accessing-the-uis) below.

**Requirements:** macOS with Docker Desktop running, and at least 6 CPUs /
36 GB RAM allocated to Docker. Too big? `MINIKUBE_MEMORY=8g ./bootstrap.sh`
works as a smoke test (don't expect the full stack to fit).

## Everyday commands

| Command | What it does |
|---|---|
| `make bootstrap` | Full install from zero |
| `make <component>` | Install one component **and its dependencies** (see below) |
| `make apply` | Re-apply current config (safe anytime — only changes what changed) |
| `make update-versions` | Pin every component to its latest release, then apply |
| `make tunnel` | `minikube tunnel` for this cluster's profile (keep it running) |
| `make hosts` | Print the `/etc/hosts` line for the `*.lab.local` URLs |
| `make gateway` | Re-apply the TLS Gateway + HTTPRoutes |
| `make status` | Applications + pods overview |
| `make clean` | Remove all components but keep the VM |
| `make destroy` | Delete everything including the VM |
| `make help` | Full target list |

### Installing a single component

Every component has its own target. Dependencies install automatically, even
if they were disabled:

```bash
make velero     # also installs minio (its backup target)
make alloy      # also installs kube-prometheus-stack, loki-stack, tempo
make kagent     # AI agent framework -- needs an API key first, see below
make agentgateway  # agentic-traffic gateway (LLM/MCP/A2A + HTTP), see below
make gitlab     # GitLab CE -- heavy! read the GitLab notes first
make kubeflow   # heavy! read the Kubeflow notes first
```

The dependency graph lives in `scripts/enable-component.sh`.

### Uninstalling a component

Set its flag to `false` in `components.env`, then `make apply`. Argo CD
deletes the component and everything it created (cascading via finalizer):

```bash
sed -i '' 's/^VELERO_ENABLED=.*/VELERO_ENABLED=false/' components.env
make apply
```

## What's installed

| Area | Components | Default |
|---|---|---|
| Core | Minikube, CoreDNS, Metrics Server | on |
| GitOps | Argo CD (owns everything below) | on |
| Networking | Gateway API, Envoy Gateway (shared TLS Gateway), cert-manager (self-signed CA) | on |
| Networking | MetalLB (`make metallb`) | off |
| Secrets | External Secrets Operator | on |
| Policy | Kyverno (`make kyverno`), ClusterPolicy admission control | off |
| Storage | MinIO (S3-compatible object storage), hostPath StorageClass, VolumeSnapshot CRDs | on |
| Observability | Prometheus, Grafana, Alertmanager, Loki (logs), Tempo (traces), Alloy (collector), kube-state-metrics, node-exporter | on |
| Backup | Velero (backs up to MinIO) | on |
| AI agents | kagent (`make kagent`, needs LLM API key) | off |
| AI gateway | agentgateway (`make agentgateway`) | off |
| Autoscaling | KEDA (`make keda`), event-driven ScaledObject/ScaledJob autoscaling | off |
| Autoscaling | VPA (`make vpa`), right-sizes pod CPU/memory requests | off |
| Source control & CI | GitLab CE (`make gitlab`, very heavy) + GitLab Runner (`make gitlab-runner`) | off |
| Operators | OLM / OperatorHub (`make olm`) | off |
| ML platform | Kubeflow full suite (`make kubeflow`, very heavy) | off |

How the observability pieces fit together: Alloy collects pod logs → Loki,
scrapes `prometheus.io/scrape`-annotated pods → Prometheus, and receives OTLP
traces → Tempo. Loki and Tempo are pre-wired as Grafana datasources — nothing
to configure by hand.

CNI: minikube's default, or set `MINIKUBE_CNI=cilium` (or `calico`) before
bootstrap. The CNI is fixed at cluster creation — changing it later means
`minikube delete -p homelab` and re-bootstrapping.

## Accessing the UIs

No port-forwarding needed. Everything is exposed through one shared Envoy
Gateway with TLS (`*.lab.local` wildcard cert from the built-in CA).

**1. Keep the tunnel running** (own terminal — it may ask for your sudo
password):

```bash
make tunnel
```

**2. Add the hostnames once:**

```bash
make hosts | head -1 | sudo tee -a /etc/hosts
```

**3. Open:**

| URL | Credentials |
|---|---|
| https://argocd.lab.local | `admin` / see below |
| https://grafana.lab.local | `admin` / password in `gitops/apps/08-kube-prometheus-stack.yaml` |
| https://prometheus.lab.local | — |
| https://minio.lab.local | credentials in `gitops/apps/12-minio.yaml` |
| https://tempo.lab.local | — |

Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

**Silencing browser certificate warnings:** the certs are signed by the
generated `homelab-root-ca`. Export it and mark it trusted in Keychain
Access:

```bash
kubectl -n cert-manager get secret homelab-root-ca \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
```

To migrate to Let's Encrypt or an internal PKI later, add a new
`ClusterIssuer` and swap the `issuerRef` in `gitops/platform/gateway.yaml`.

## How it works

```
bootstrap.sh
 ├─ 00-prereqs.sh            install missing CLI tools
 ├─ 01-minikube.sh           start the cluster (profile: homelab)
 ├─ 02-foundational-crds.sh  Gateway API + VolumeSnapshot CRDs
 ├─ 03-argocd.sh             install Argo CD (Helm)
 └─ 04-apply-apps.sh         build + apply the platform ApplicationSet,
                             then the TLS Gateway, routes, and secrets
```

Three files control everything; each answers one question:

| File | Question it answers | Example |
|---|---|---|
| `components.env` | Is this component installed? | `MINIO_ENABLED=true` |
| `versions.env` | Which version? | `CERT_MANAGER_VERSION=v1.15.3` |
| `gitops/apps/<component>.yaml` | Which chart, with what config? | Helm `values:` block |

After editing any of them, run `make apply`. That regenerates
`gitops/rendered/applicationset.yaml` — a single Argo CD `ApplicationSet`
with one entry per **enabled** component — and applies it. From there Argo CD
does the real work: it diffs the new list against the cluster and creates,
upgrades, or deletes child `Application`s to match. No bash script ever
decides to delete your resources; the ApplicationSet's list *is* the desired
state and Argo CD reconciles to it.

That's also why `make apply` is always safe to re-run: unchanged components
produce byte-identical specs, so Argo CD touches nothing. Only components
whose flag, version, or values changed get reconciled.

A few things live outside the ApplicationSet because they don't fit the
uniform Helm template:

- **Foundational CRDs** (Gateway API, VolumeSnapshot) — installed first by
  script, since other components need them at admission time.
- **OLM** — official release manifests, handled by `scripts/06-olm.sh`.
- **Kubeflow** — a git+kustomize bundle, handled as a standalone Application
  (`gitops/special/16-kubeflow.yaml`).
- **Glue secrets** — Velero↔MinIO credentials (`scripts/05-velero-secret.sh`)
  and the kagent API key (`scripts/09-kagent-secret.sh`).

All of these are still driven by the same `components.env` flags and run
automatically inside `make apply`.

<details>
<summary>More internals: sync waves, legacy files</summary>

Every generated `Application` carries a `platform-wave` label and matching
`argocd.argoproj.io/sync-wave` annotation (wave column in
`scripts/lib-components.sh`). Installs aren't staged by wave today — all
components sync concurrently and Kubernetes' own retry/backoff resolves
ordering, which is fine for a homelab. To enforce strict ordering, add an
ApplicationSet `strategy: RollingSync` keyed on that label in
`scripts/build-applicationset.py`.

`scripts/render-apps.sh` and `gitops/root-app.yaml` are leftovers from an
earlier flat-Application design and are no longer used by bootstrap.
`root-app.yaml` is only worth revisiting if you want a git-audited app-of-apps
pointing at the rendered ApplicationSet.

</details>

## Optional components

### kagent (AI agents)

[kagent.dev](https://kagent.dev) needs an LLM provider API key before it's
useful:

```bash
KAGENT_PROVIDER_API_KEY=sk-... ./scripts/09-kagent-secret.sh
make kagent
```

kagent's chart evolves quickly — verify the Helm value that consumes the
`kagent-model-provider` secret against `helm show values kagent/kagent` for
your pinned version (see the commented block in `gitops/apps/15-kagent.yaml`).

### agentgateway (AI/agentic-traffic gateway)

[agentgateway.dev](https://agentgateway.dev) is a Gateway API-native proxy
for agentic traffic — LLM providers, MCP servers, agent-to-agent (A2A) — and
plain HTTP. Two Argo CD Applications (`agentgateway-crds` + `agentgateway`,
OCI charts from `cr.agentgateway.dev/charts`) install the control plane into
`agentgateway-system`; it then creates an `agentgateway` GatewayClass and
spins up a proxy Deployment per Gateway you create.

```bash
make agentgateway                          # install
./scripts/10-agentgateway-sample-test.sh   # end-to-end test with the official
                                           # httpbin sample (add --keep to keep it)
```

The test applies `examples/agentgateway-httpbin-sample.yaml` (Gateway +
httpbin + HTTPRoute, from the [official sample-app guide](https://agentgateway.dev/docs/kubernetes/latest/install/sample-app/)),
port-forwards the proxy, and checks that
`curl localhost:18080/headers -H "host: www.example.com"` returns 200.
Inspect routes in the read-only Admin UI:
`kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 15000`
→ http://localhost:15000/ui/.

### Kyverno (policy engine)

[kyverno.io](https://kyverno.io) enforces `ClusterPolicy`/`Policy` CRDs
(validate, mutate, generate, cleanup) via a `ValidatingAdmissionWebhook` --
Kubernetes-native policy-as-code, no separate policy language needed. One
Argo CD Application installs the admission/background/cleanup/reports
controllers plus CRDs (`crds.install: true`, the chart default) into the
`kyverno` namespace.

```bash
make kyverno
```

Nothing is enforced out of the box -- the chart ships no built-in policies.
Add your own `ClusterPolicy` resources (or the community pack at
[kyverno/policies](https://github.com/kyverno/policies)) once it's running.
Try enforcement with `examples/kyverno-policy-sample.yaml` (a `require-team-label`
policy plus a Pod that violates it and one that complies).

### KEDA (event-driven autoscaling)

[keda.sh](https://keda.sh) adds `ScaledObject`/`ScaledJob` CRDs so workloads
can scale on event sources (queues, Kafka, Prometheus metrics, cron, etc.),
on top of what the stock HPA can do off CPU/memory alone. One Argo CD
Application installs the operator + metrics server into the `keda`
namespace.

```bash
make keda
```

Try it with `examples/keda-scaledobject-sample.yaml` (a CPU-triggered
`ScaledObject` on the classic `hpa-example` image, self-contained -- no
external event source needed).

### VPA (Vertical Pod Autoscaler)

Right-sizes container CPU/memory *requests* from observed usage, via
`VerticalPodAutoscaler` CRDs -- complementary to KEDA/HPA, which scale
*replica count* instead. Uses the
[fairwinds-stable/vpa](https://github.com/FairwindsOps/charts/tree/master/stable/vpa)
chart (a packaging of `kubernetes/autoscaler`'s VPA); installs recommender +
updater + admission controller into the `vpa` namespace.

```bash
make vpa
```

Don't run VPA and an HPA/KEDA `ScaledObject` on the same resource metric
(e.g. both on CPU) for one workload -- they'll fight over the same knob.

Try it with `examples/vpa-sample.yaml` (a CPU/memory-hungry `stress`
container plus a `VerticalPodAutoscaler` in `Auto` mode).

### GitLab CE + GitLab Runner (self-hosted git + CI, on top of Argo CD)

Argo CD is already installed and always on (it's the GitOps engine that
owns everything in this platform) -- this section adds the other two legs
of a fully self-hosted push-to-deploy loop: **GitLab CE** to host git repos
(and your `.gitlab-ci.yml`), and **GitLab Runner** to actually execute
those CI pipelines. Push code -> GitLab Runner builds/tests it -> Argo CD
(pointed at your gitops repo, hosted on the same GitLab CE) picks up the
result and deploys it -- no external SaaS required.

**HEAVY**, comparable to Kubeflow: the official chart
(`gitlab/gitlab`, `global.edition: ce`) brings its own Gitaly, Webservice,
Sidekiq, container registry, Postgres, Redis, and a *second* dedicated
Envoy Gateway instance -- expect 15-20+ pods. Bump
`MINIKUBE_CPUS`/`MINIKUBE_MEMORY` well beyond the defaults before enabling,
and expect to babysit the first sync (`kubectl get pods -n gitlab`) the way
you would Kubeflow's.

```bash
make gitlab                                             # install GitLab CE
# once it's Running: create an instance runner in its UI --
# Settings > CI/CD > Runners > "New instance runner" -- then:
GITLAB_RUNNER_TOKEN=glrt-... ./scripts/11-gitlab-runner-secret.sh
make gitlab-runner                                       # install the Runner
```

Notes and known trade-offs (see `gitops/apps/22-gitlab.yaml` for the exact
values):

- **TLS is off by default** (`global.hosts.https: false`) -- GitLab CE is
  reachable at `http://gitlab.lab.local/`, not through the shared
  `*.lab.local` Gateway the rest of the platform uses. Wiring its Gateway
  API TLS listeners to the platform's `homelab-ca` ClusterIssuer is left as
  a manual follow-up; the chart's cert-manager integration is
  version-specific enough that it isn't pinned down here.
- It installs its **own dedicated Envoy Gateway + GatewayClass**
  (`installEnvoy: true`) rather than reusing the platform's shared one, so
  it gets its own LoadBalancer IP -- check `kubectl get gateway -A` for it.
- `installCertmanager: false` -- it reuses the platform's own cert-manager
  install instead of deploying a second one (two Helm releases both trying
  to own the cluster-scoped CRDs would conflict).
- The chart's bundled `gitlab-runner` subchart is disabled
  (`gitlab-runner.install: false`) in favor of the standalone
  `23-gitlab-runner.yaml` Application, so `GITLAB_RUNNER_ENABLED` can be
  toggled independently once you have a token.

Once both are up, verify the Runner is actually executing jobs with
`examples/gitlab-ci-sample.yml` -- push it as `.gitlab-ci.yml` to a new
project in the GitLab UI and confirm the pipeline goes green.

### Kubeflow (ML platform)

The full suite: Pipelines, Notebooks, Katib, Training Operator, KServe,
Dashboard. Two warnings before `make kubeflow`:

- **It's heavy.** Raise `MINIKUBE_CPUS`/`MINIKUBE_MEMORY` well beyond the
  defaults, or disable other components to make room.
- **It converges slowly.** Kubeflow's manifests need several Argo CD sync
  passes on a fresh install — expect minutes, and check
  `kubectl -n argocd get application kubeflow` if it looks stuck.

`update-versions.sh` doesn't track `KUBEFLOW_VERSION` (it's a git tag, not a
chart) — check [kubeflow/manifests releases](https://github.com/kubeflow/manifests/releases)
manually and keep it recent: old tags pin container images that Google has
purged from `gcr.io`, which shows up as `ImagePullBackOff` / "manifest
unknown" errors.

### MetalLB

`make metallb` installs it and auto-configures an address pool from the
minikube subnet. Honest caveat: with the docker driver on macOS the pool IPs
live on Docker's internal network and aren't reachable from your Mac —
`make tunnel` remains the practical access path. MetalLB earns its keep with
the vfkit/qemu drivers or on Linux.

### Deliberately not included

**Falco** (heavy eBPF, can destabilize a VM), **Sealed Secrets** (redundant
with External Secrets Operator), **OpenTelemetry Collector** (Alloy already
covers OTLP). Each can be added as a new `gitops/apps/*.yaml` following the
existing pattern.

## Updating versions

```bash
make update-versions
```

Checks every Helm chart and GitHub release against upstream, rewrites
`versions.env` in place (printing a before/after table), and applies. Argo CD
then rolls each changed component to its new version — untouched components
aren't restarted.

Review the `versions.env` diff before applying to a cluster you care about:
major-version jumps (cert-manager, kube-prometheus-stack, External Secrets)
can carry breaking CRD or values changes.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `make hosts`: "Gateway has no address yet" | Tunnel not running (`make tunnel`), or the envoy-gateway Application isn't Healthy — check `make status` |
| Pods `Pending` on unbound PVCs right after bootstrap | Normal startup race — the storage provisioner binds them within a minute or two |
| Velero pod: `secret "velero-minio-credentials" not found` | MinIO wasn't ready when the secret step ran — `./scripts/05-velero-secret.sh` (or `make apply`) |
| Kubeflow `ImagePullBackOff`, "manifest unknown" | Old `KUBEFLOW_VERSION` pinning purged gcr.io images — bump to a recent manifests tag |
| OLM apply: "conflict ... use --force-conflicts" | Fixed in `scripts/06-olm.sh` (forced server-side apply) — re-run `make apply` |
| A component's Application stuck `Unknown`/`OutOfSync` | `kubectl -n argocd describe application <name> \| tail -15` shows the real error; a hard refresh helps after fixes: `kubectl -n argocd annotate application <name> argocd.argoproj.io/refresh=hard --overwrite` |
| Huge-CRD components (External Secrets) fail to sync | Needs `ServerSideApply=true` in the app's `syncOptions` (already set where known) |

## Teardown

```bash
make clean      # remove all components + Argo CD, keep the VM
make destroy    # everything, including the Minikube VM
```

`cleanup.sh` (what these call) deletes the ApplicationSet first so Argo CD
cascades component deletion cleanly, then removes Argo CD, then the VM. Both
accept `--yes` to skip the confirmation prompt. In a hurry?
`minikube delete -p homelab` nukes everything in one step — the graceful
cascade is a courtesy, not a requirement.
