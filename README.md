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
| `make apply ENV=prod` | Same, against a different environment overlay (default `dev`) |
| `make render ENV=dev` | Regenerate the checked-in plan, collector configs, and ApplicationSet |
| `make update-versions` | Pin every component to its latest release, then apply |
| `make tunnel` | `minikube tunnel` for this cluster's profile (keep it running) |
| `make hosts` | Print the `/etc/hosts` line for the `*.lab.local` URLs |
| `make gateway` | Re-apply the TLS Gateway + HTTPRoutes |
| `make status` | Applications + pods overview |
| `make clean` | Remove all components but keep the VM |
| `make destroy` | Delete everything including the VM |
| `make help` | Full target list |

### Installing a single component

Every component has its own target. In dev, it enables the base flag; with
`ENV=staging` or `ENV=prod`, it enables the component unless that environment
explicitly disables it. The platform plan resolves declared
dependencies and shows their provenance. If a required dependency is explicitly
disabled, planning stops and names the dependency chain; enable it deliberately
before applying:

```bash
make velero     # plan includes SeaweedFS when enabled
make alloy      # plan includes its metrics and log backends
make kagent     # AI agent framework -- needs an API key first, see below
make agentgateway  # agentic-traffic gateway (LLM/MCP/A2A + HTTP), see below
make airflow    # workflow orchestration (DAGs), see below
make gitlab     # GitLab CE -- heavy! read the GitLab notes first
make kubeflow   # heavy! read the Kubeflow notes first
```

Install metadata and dependencies live in `config/platform-catalog.yaml`.

### Uninstalling a component

Set its flag to `false` in `components.env`, then `make apply`. Argo CD
deletes the component and everything it created (cascading via finalizer):

```bash
sed -i '' 's/^VELERO_ENABLED=.*/VELERO_ENABLED=false/' components.env
make apply
```

## What's installed

See the [complete platform architecture](docs/architecture.md) for the full
component catalogue, enabled/optional status, configuration ownership, ingress
routes, and observability data paths.

| Area | Components | Default |
|---|---|---|
| Core | Minikube, CoreDNS, Metrics Server | on |
| GitOps | Argo CD (owns everything below) | on |
| Networking | Gateway API, Envoy Gateway (shared TLS Gateway), cert-manager (self-signed CA) | on |
| Networking | MetalLB (`make metallb`) | off |
| Secrets | External Secrets Operator | off |
| Policy | Kyverno (`make kyverno`), ClusterPolicy admission control | off |
| Storage | SeaweedFS (S3-compatible object storage — backs Mimir, Loki, Tempo and Velero when enabled), hostPath StorageClass, VolumeSnapshot CRDs | on |
| Observability | Grafana, Alertmanager, Prometheus (scrape + remote-write only), kube-state-metrics, node-exporter, Alloy (infra collector) | on |
| Observability | **Mimir** (metrics), **Loki 3** (logs), **Tempo distributed** (traces) — all on SeaweedFS object storage | on |
| Observability | OpenTelemetry Collector — agent DaemonSet + gateway StatefulSet (`make otel-collector`) | on |
| Messaging | RabbitMQ (`make rabbitmq`), backs the `examples/dotnet-rabbitmq/` sample | on |
| Backup | Velero (backs up to SeaweedFS) | off |
| AI agents | kagent (`make kagent`, needs LLM API key) | off |
| Observability | OpenTelemetry eBPF Instrumentation (`make obi`) — zero-code HTTP/gRPC spans, no SDK required | on |
| AI gateway | agentgateway (`make agentgateway`) | off |
| Autoscaling | KEDA (`make keda`), event-driven ScaledObject/ScaledJob autoscaling | on |
| Autoscaling | VPA (`make vpa`), right-sizes pod CPU/memory requests | on |
| Source control & CI | GitLab CE (`make gitlab`, very heavy) + GitLab Runner (`make gitlab-runner`) | off |
| Workflow orchestration | Apache Airflow (`make airflow`) | off |
| Operators | OLM / OperatorHub (`make olm`) | on |
| ML platform | Kubeflow full suite (`make kubeflow`, very heavy) | off |

“On” describes the checked-in root `components.env` and the generated dev
plan. Environment overlays can change it; use that environment's
`gitops/rendered/<env>/platform-plan.json` to see its resolved set. The
catalogue is the inventory of supported components, not a claim that every
manifest is installed. For the complete inventory and wiring, see the
[architecture guide](docs/architecture.md).

How the observability pieces fit together. Two collectors, different jobs:

**Alloy** is the cluster collector for infrastructure telemetry: pod logs →
Loki, `prometheus.io/scrape`-annotated pods → Mimir. It no longer accepts
traces — that was a second door into Tempo that bypassed enrichment,
redaction, and sampling.

**The OpenTelemetry Collector** is the front door for *application* telemetry,
and runs as two tiers because those tiers cannot be collapsed:

- **`otel-agent`** (DaemonSet) is where apps send OTLP. The chart sets
  `internalTrafficPolicy: Local` on a DaemonSet's Service, so one DNS name —
  `otel-agent-opentelemetry-collector.otel.svc:4317` — always reaches the agent
  on the pod's own node. It enriches with Kubernetes metadata (which only works
  here: one hop later the connection's source IP is the agent's, not the
  workload's), redacts secrets before anything leaves the node, and derives RED
  metrics from **100% of spans**.
- **`otel-gateway`** (StatefulSet) tail-samples — keeping every error, slow,
  expensive, or deep-loop trace and sampling the boring remainder — and is the
  only egress to Tempo. Agents reach it over mTLS, routing by trace ID so all
  spans of a trace land on one gateway pod, which is what makes a tail-sampling
  decision coherent.

Span metrics are derived in the agent, *in front of* the sampler, on purpose:
behind it they would count the surviving fraction and silently understate every
rate in Grafana.

**Storage** is object storage, not PVCs. Mimir, Loki 3, and Tempo distributed
all keep their blocks in SeaweedFS, each with its own bucket. The current
SeaweedFS chart configuration uses a shared S3 credential; bucket names
separate data, but do not provide per-component credential isolation.
Retention becomes a policy setting rather than a disk-size accident, and the
read path scales horizontally.

**eBPF instrumentation.** `make obi` enables OpenTelemetry eBPF Instrumentation as a
DaemonSet, giving HTTP/gRPC spans and RED metrics for pods nobody instrumented
— no code change, no redeploy. It runs unprivileged (capabilities dropped to
the seven eBPF actually needs, read-only rootfs) but still requires `hostPID`
and `hostNetwork`, which is why it is opt-in and its namespace is
PSA-privileged. It is enabled in the checked-in dev and staging plans, and
disabled in prod until the security trade-off is reviewed there. It emits no
`gen_ai.*` attributes and no token counts, so it
complements the SDK instrumentation rather than replacing it.

Prometheus is still there but its role narrowed: it scrapes ServiceMonitors and
remote-writes to Mimir, keeping only 6h locally. Query anything historical from
the Mimir datasource, which is Grafana's default.

Tempo and Loki run multi-tenant (`X-Scope-OrgID`), with `agents` for normal
telemetry at 30d and `agents-content` reserved for prompt/completion records at
7d. Grafana's datasources pin the tenant, so the content tenant can later be put
behind an RBAC role without touching anything else.

Mimir, Loki, and Tempo are pre-wired as Grafana datasources — nothing to
configure by hand.

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
| https://seaweedfs.lab.local | S3 API in `gitops/apps/12-seaweedfs.yaml` |
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

Four files control everything; each answers one question:

| File | Question it answers | Example |
|---|---|---|
| `components.env` | Is this component installed? | `SEAWEEDFS_ENABLED=true` |
| `versions.env` | Which version? | `CERT_MANAGER_VERSION=v1.15.3` |
| `gitops/apps/<component>.yaml` | Which chart, with what config? | Helm `values:` block |
| `environments/<env>/` | What differs in *this* environment? | `replicaCount: 1` |

The first three are the base. `environments/<env>/` layers on top of them:
`components.env` and `versions.env` there override the base key by key, and
`values/<component>.yaml` is deep-merged over the app file's Helm values. An
environment therefore lists only what actually differs — a prod overlay that
pins two chart versions is two lines, not a copy of the whole file. See
`environments/README.md` for the merge rules.

`ENV` selects the overlay and defaults to `dev`:

```bash
make apply              # dev — the minikube profile
make apply ENV=prod     # same architecture, production sizing
```

One environment per cluster. `dev` is a *scaled-down profile of the same
architecture*, not a simpler one — if something only works in dev, that's a bug
in the overlay.

After editing source configuration, run `make render ENV=<env>` and review the
generated diff, then run `make apply ENV=<env>`. Apply verifies the checked-in
plan and generated files before making any cluster changes. The typed catalogue
in `config/platform-catalog.yaml` defines install handlers, dependencies, and
routes; `gitops/rendered/<env>/platform-plan.json` records requested and
dependency-enabled entries with provenance. `config/telemetry-policy.yaml`
checks collector ordering and tenant routing, and the generated tier configs
are included in the ApplicationSet values. The ApplicationSet contains one
entry per planned Helm install. From there Argo CD
does the real work: it diffs the new list against the cluster and creates,
upgrades, or deletes child `Application`s to match. No bash script ever
decides to delete your resources; the ApplicationSet's list *is* the desired
state and Argo CD reconciles to it.

If checked-in output is stale, apply stops before cluster mutation and tells
you to regenerate it. Unchanged inputs produce byte-identical output, so only
components whose flag, version, or values changed get reconciled.

A few things live outside the ApplicationSet because they don't fit the
uniform Helm template:

- **Foundational CRDs** (Gateway API, VolumeSnapshot) — installed first by
  script, since other components need them at admission time.
- **OLM** — official release manifests, handled by `scripts/06-olm.sh`.
- **Kubeflow** — a git+kustomize bundle, handled as a standalone Application
  (`gitops/special/16-kubeflow.yaml`).
- **Glue secrets** — Velero↔SeaweedFS credentials (`scripts/05-velero-secret.sh`)
  and the kagent API key (`scripts/09-kagent-secret.sh`).

All of these are still driven by the same `components.env` flags and run
automatically inside `make apply`.

## Adding a component

Add a component through the catalogue-driven plan so rendering, dependency
validation, and Argo CD all agree about its desired state. For a regular Helm
component:

1. **Add its Helm Application manifest** in `gitops/apps/`, following an
   existing file. Set `metadata.name`, chart repository/name/version
   placeholder, destination namespace, sync policy, and a sync wave. Keep
   production-shaped values in the manifest; put environment-specific sizing
   or settings in `environments/<env>/values/<component>.yaml`.
2. **Register it in `config/platform-catalog.yaml`** under `components` with
   its flag name, `adapter: helm`, manifest path, wave, and every required
   dependency. Dependencies are resolved transitively; explicitly disabled
   dependencies cause planning to fail before cluster changes.
3. **Add the flag and version** to root `components.env` and `versions.env`.
   Use `environments/<env>/components.env` or `versions.env` only when a
   particular environment intentionally differs. Keep credentials out of
   checked-in files; add or document a secret-provisioning handler when the
   component needs one. Add the flag to an environment overlay when that
   environment must explicitly enable or disable the new component.
4. **Add a route only when needed.** Create its HTTPRoute in
   `gitops/platform/routes/` and register the route file and controlling flag
   under `routes` in the catalogue. Add its hostname to the `make hosts`
   output in `Makefile` if users should access it through the shared Gateway.
5. **Add a per-component Make target.** Add the component to `HELM_COMPONENTS`
   in `Makefile`; the existing generic target enables the flag and applies the
   resolved plan. For a grouped feature with multiple Applications sharing one
   flag, add its user-facing name and flag mapping in
   `scripts/enable-component.sh` (as with `otel-collector`).
6. **Render every checked-in environment and review the diff:**

   ```bash
   for env in dev staging prod; do make render ENV="$env"; done
   git diff -- gitops/rendered
   ```

   The planner validates manifest shape, flags, dependencies, versions, and
   environment overlays. Add a telemetry invariant to
   `config/telemetry-policy.yaml` and its validator in
   `scripts/build-applicationset.py` when the new component changes a
   cross-tier telemetry guarantee.
7. **Check generated output, then install in dev:**

   ```bash
   for env in dev staging prod; do make preflight ENV="$env"; done
   make <component>
   make status
   ```

   `make <component>` installs the component and its declared dependencies.
   Review Argo CD health and workload readiness before promoting the same
   rendered plan to staging and prod.

For a non-Helm module, choose an adapter already supported by the planner:
`script` (register its handler and make it consume the resolved plan) or
`argocd-git` (provide a Git source manifest and namespace). Wire its install,
uninstall, secrets, and readiness behavior into `scripts/04-apply-apps.sh` as
needed; special handlers do not get the generic Helm ApplicationSet entry.
Update the architecture guide's catalogue and diagram, then follow the same
render, preflight, install, and review steps. Avoid adding a fourth adapter
without extending plan validation and apply handling deliberately.

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

### Airflow (workflow orchestration)

[airflow.apache.org](https://airflow.apache.org) -- author DAGs in Python,
schedule and monitor them from a web UI. One Argo CD Application
(`apache-airflow/airflow` chart) installs it into the `airflow` namespace
using `LocalExecutor` on the chart's bundled Postgres (Redis/Celery workers
disabled) -- a single scheduler process runs tasks directly, which keeps
the pod count reasonable for a homelab. `KubernetesExecutor` (each task run
as its own Pod) is the natural next step if you outgrow that -- change
`executor:` in `gitops/apps/24-airflow.yaml`.

```bash
make airflow
```

Not on the shared `*.lab.local` Gateway (same as kagent/agentgateway/KEDA/
VPA) -- reach the UI with:

```bash
kubectl -n airflow port-forward svc/airflow-api-server 8080:8080
```

then open http://localhost:8080 (`admin` / `admin`, the chart's default).

Try it with `examples/airflow-dag-sample.yaml` -- a ConfigMap holding one
minimal DAG, mounted into the DAG processor by a volume already wired in
`gitops/apps/24-airflow.yaml` (optional, so the base install doesn't need
it to come up clean). Applying it is enough for the DAG to appear -- no
values change, no restart, no git-sync/external repo required.

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

**Falco** (heavy eBPF, can destabilize a VM) and **Sealed Secrets** (redundant
with External Secrets Operator). Each can be added as a new
`gitops/apps/*.yaml` following the existing pattern.

(The OpenTelemetry Collector used to be listed here. It is installed now — see
**What's installed** above.)

### AI agent observability

`examples/genai-agent/` is the worked example for `docs/genai-instrumentation.md`
— the contract every agent service on this platform implements so that one
dashboard, one alert rule, and one sampling policy work across all of them.

It runs in `FAKE_LLM=true` mode by default, synthesising responses and token
counts, so the whole pipeline is exercisable with no API key and no spend.

Prompt and completion capture is off by default and time-boxed when on:

```bash
make obs-capture ON=true TTL=30m   # auto-reverts; a CronJob enforces the TTL
make obs-level LEVEL=debug         # 100% tail sampling + debug logs
make obs-status
```

Captured content is routed to a separate short-retention Tempo tenant
(`agents-content`, 7d) rather than the 30-day tenant everyone reads, and is
deliberately not exposed as a Grafana datasource — Grafana OSS has no
datasource-level RBAC.

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
| Velero pod: `secret "velero-seaweedfs-credentials" not found` | SeaweedFS wasn't ready when the secret step ran — `./scripts/05-velero-secret.sh` (or `make apply`) |
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
