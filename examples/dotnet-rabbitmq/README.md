# OrderFlow — .NET + RabbitMQ + OpenTelemetry + KEDA

A producer and a consumer, written in .NET, talking over a RabbitMQ queue.
It demonstrates two things that are awkward to show separately:

1. **Traces that survive a queue.** The producer's span and the consumer's
   span for the same message end up in **one trace** in Grafana Tempo, even
   though the two processes never talk directly.
2. **Event-driven autoscaling.** KEDA scales the consumer on RabbitMQ queue
   depth, including the backlog the producer deliberately creates.

## Prerequisites

```bash
make rabbitmq otel-collector      # pulls in kube-prometheus-stack + tempo
```

`keda` must be enabled too (it is by default in `components.env`).

## Build the image

This cluster has no registry, so the image has to live in the node's own
Docker daemon:

```bash
eval $(minikube -p homelab docker-env)
docker build -t orderflow:1.0.0 examples/dotnet-rabbitmq/src
```

`imagePullPolicy: IfNotPresent` in `k8s.yaml` is what makes that work —
`Always` would send the kubelet looking for a registry that isn't there.

## Run it

```bash
kubectl apply -f examples/dotnet-rabbitmq/k8s.yaml
kubectl get pods -l app.kubernetes.io/part-of=orderflow -w
```

## How the trace crosses the queue

RabbitMQ is not HTTP, so nothing propagates trace context for free. The
producer injects the W3C `traceparent` into the AMQP message headers, and
the consumer extracts it and uses it as its span's parent:

```
producer                                   consumer
  StartActivity("orders publish")
    ActivityKind.Producer
      │
      └─ propagator.Inject(...)  ──►  AMQP header: traceparent
                                            │
                                            └─►  propagator.Extract(...)
                                                   StartActivity("orders process",
                                                     ActivityKind.Consumer,
                                                     parent.ActivityContext)
                                                       └─ "validate order"
```

The result in Tempo is a single trace, `orders publish` → `orders process`
→ `validate order`, spanning both services. Drop the Inject/Extract pair and
you get two disconnected single-span traces instead — which is what most
"my queue traces are broken" reports turn out to be.

## Where the spans go

```
app ──OTLP/gRPC──► otel-collector-opentelemetry-collector.otel.svc:4317
                     └─ memory_limiter → k8s_attributes → batch
                          └──► tempo.tracing.svc:4317
```

The gateway's `k8s_attributes` processor decorates every span with pod,
namespace, node and deployment names before forwarding, so you can filter by
Kubernetes metadata in Tempo without the app knowing anything about it.

View them in Grafana → **Explore** → **Tempo** → **TraceQL**:

```traceql
{ resource.service.name = "orderflow-producer" }
{ resource.service.name = "orderflow-consumer" }
{ name = "orders process" && duration > 500ms }
{ resource.k8s.namespace.name = "default" }
```

## How the autoscaling works

The producer publishes every `PUBLISH_INTERVAL_MS` (250ms) and the consumer
takes `WORK_MS` (400ms) per message, so **one consumer cannot keep up by
design** — the queue grows and KEDA reacts:

```yaml
mode: QueueLength
value: "5"            # target ~5 ready messages per replica
minReplicaCount: 0    # scale to zero when the queue drains
maxReplicaCount: 10
```

`minReplicaCount: 0` is deliberate: KEDA ignores `pollingInterval` and
`cooldownPeriod` unless the floor is zero (it warns about exactly that on
apply), because above zero the HPA does the polling. To watch it scale to
zero, stop the producer and let the backlog drain:

```bash
kubectl scale deploy/orderflow-producer --replicas=0
```

A 50-deep queue therefore asks for 10 replicas. Watch it:

```bash
kubectl get scaledobject,hpa -n default -w
kubectl get pods -l app=orderflow-consumer -w
```

`BasicQosAsync(prefetchCount: 1)` in the consumer matters here: without it a
single consumer prefetches the entire queue, RabbitMQ reports ~0 *ready*
messages, and KEDA sees nothing to scale on even while work is piling up.

To force a bigger backlog, scale the producer up:

```bash
kubectl scale deploy/orderflow-producer --replicas=5
```

## Sampling (`OTEL_TRACES_SAMPLER`)

Nothing is set, so the SDK default applies: **`parentbased_always_on` — 100%
of traces are kept**. Both env vars are read by the OpenTelemetry .NET SDK
directly, so changing sampling needs no code change and no rebuild — set
them on the container and restart.

| `OTEL_TRACES_SAMPLER` | `_ARG` | Behaviour |
|---|---|---|
| `always_on` | — | Keep every span. Ignores the parent's decision entirely. |
| `always_off` | — | Drop every span. Useful to prove overhead is gone, little else. |
| `traceidratio` | `0.0`–`1.0` | Keep a deterministic fraction, hashed from the trace ID. **Ignores the parent.** |
| `parentbased_always_on` | — | **Default.** Follow the parent's decision; if there is no parent, keep. |
| `parentbased_always_off` | — | Follow the parent; if there is no parent, drop. |
| `parentbased_traceidratio` | `0.0`–`1.0` | Follow the parent; if there is no parent, apply the ratio. |

### Examples

Keep 10% of traces, whole (recommended shape for this app):

```yaml
- name: OTEL_TRACES_SAMPLER
  value: parentbased_traceidratio
- name: OTEL_TRACES_SAMPLER_ARG
  value: "0.1"
```

Keep everything (explicitly, rather than relying on the default):

```yaml
- name: OTEL_TRACES_SAMPLER
  value: parentbased_always_on
```

Turn tracing off without removing the SDK:

```yaml
- name: OTEL_TRACES_SAMPLER
  value: always_off
```

Or from the CLI, no manifest edit:

```bash
kubectl set env deploy/orderflow-producer deploy/orderflow-consumer \
  OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.1
```

### Why `parentbased_*` matters across a queue

Set the **same** sampler on producer and consumer, and prefer the
`parentbased_*` variants. With bare `traceidratio` each service decides
independently off the trace ID — which mostly agrees, but the two services
are separate processes and any drift gives you producer spans whose consumer
half is missing. That looks exactly like the propagation bug this sample
exists to demonstrate.

The flip side, worth knowing before you debug it: under `parentbased_*` the
consumer **honours an upstream "not sampled" decision**. A message published
with `traceparent: 00-<trace>-<span>-00` (flags `00` = not sampled) is
processed normally, but the consumer records *nothing at all* — no span, not
even a root. The work happens; the telemetry does not exist. If spans vanish
for messages from another team's service, check their sampler before
suspecting yours.

A message with **no** `traceparent` behaves differently again: there is no
parent decision to follow, so the consumer starts a **new root trace**. The
spans are captured, just not linked to whoever published. You will see
2-span traces rooted at `orderflow-consumer` rather than the usual 3-span
traces rooted at `orderflow-producer`:

```traceql
{ name = "orders process" }        # then look for traces with no "orders publish"
```

## Inspecting RabbitMQ directly

```bash
kubectl -n rabbitmq exec -it rabbitmq-0 -- rabbitmqctl list_queues name messages messages_ready
kubectl -n rabbitmq port-forward svc/rabbitmq 15672:15672   # management UI, homelab / HomelabRabbit123!
```

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `ROLE` | `producer` | `producer` or `consumer` |
| `QUEUE` | `orders` | queue name |
| `RABBITMQ_HOST` | `rabbitmq.rabbitmq.svc` | broker host |
| `RABBITMQ_USER` / `RABBITMQ_PASS` | `homelab` / … | credentials |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | otel gateway `:4317` | where spans go |
| `OTEL_SERVICE_NAME` | `orderflow-<role>` | `service.name` on spans |
| `PUBLISH_INTERVAL_MS` | `250` | producer send interval |
| `WORK_MS` | `400` | simulated work per message |

## Clean up

```bash
kubectl delete -f examples/dotnet-rabbitmq/k8s.yaml
```
