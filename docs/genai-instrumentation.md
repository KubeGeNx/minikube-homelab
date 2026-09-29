# GenAI instrumentation contract

Every agent service on this platform emits the same span names, attributes, and
metrics. That is what lets one dashboard, one alert rule, and one sampling
policy work across all of them without per-service special-casing.

This is a contract, not a suggestion: the tail-sampling policies in
`gitops/apps/27-otel-gateway.yaml` and the tenant routing that protects
prompt content both key off specific fields below. Get those wrong and your
service's traces are either sampled away or routed into the wrong tenant.

## Where to send telemetry

```
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-agent-opentelemetry-collector.otel.svc:4317
OTEL_SERVICE_NAME=<your-service>
```

The agent DaemonSet, never the gateway. The Service has
`internalTrafficPolicy: Local`, so that name resolves to the collector on your
own node — which is the only place `k8sattributes` can identify your pod from
the connection's source IP.

Also mount the verbosity knobs, and label the workload so a level change
actually reaches it:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    # On the DEPLOYMENT, not just the pod template. The restart in
    # scripts/12-observability-level.sh is a `kubectl rollout restart
    # deployment -l ...`, which matches Deployment labels only. Put it solely
    # under spec.template and the toggle will report success while your
    # workload keeps its old settings.
    observability.lab.local/managed: "true"
spec:
  template:
    metadata:
      labels:
        observability.lab.local/managed: "true"   # useful for pod-level selection
    spec:
      containers:
        - envFrom:
            - configMapRef:
                name: observability-levels
                optional: true
```

## Spans

| Operation | Span name | Kind |
|---|---|---|
| Model call | `chat {gen_ai.request.model}` | CLIENT |
| Tool execution | `execute_tool {tool name}` | INTERNAL |

Tool spans are children of the model-call span that requested them. That
parent/child shape is what makes an agent run readable as one trace.

### Required attributes — model-call spans

| Attribute | Example | Why it matters here |
|---|---|---|
| `gen_ai.system` | `anthropic` | Provider dimension on every metric |
| `gen_ai.operation.name` | `chat` | Distinguishes chat from embeddings |
| `gen_ai.request.model` | `claude-opus-5` | Cost attribution |
| `gen_ai.response.model` | `claude-opus-5` | May differ from request on fallback |
| `gen_ai.usage.input_tokens` | `1843` | Cost |
| `gen_ai.usage.output_tokens` | `512` | **Tail sampling keeps traces over 4000** |
| `gen_ai.response.finish_reasons` | `["end_turn"]` | `refusal` is a real outcome — see below |
| `error.type` | `RateLimitError` | Set on failure; drives the error policy |

### Required attributes — tool spans

| Attribute | Example |
|---|---|
| `gen_ai.operation.name` | `execute_tool` |
| `gen_ai.tool.name` | `lookup_service_owner` |
| `error.type` | set only on failure |

### Span status

Set span status to ERROR on exceptions **and** on `stop_reason == "refusal"`.
The gateway's first sampling policy keeps every trace whose status is ERROR, so
a refusal that is recorded as OK becomes invisible at 10% baseline sampling.

## Metrics

Two histograms, matching the GenAI semantic conventions:

| Metric | Unit | Attributes |
|---|---|---|
| `gen_ai.client.token.usage` | `{token}` | `gen_ai.system`, `gen_ai.request.model`, `gen_ai.operation.name`, `gen_ai.token.type` = `input`\|`output` |
| `gen_ai.client.operation.duration` | `s` | `gen_ai.system`, `gen_ai.request.model`, `gen_ai.operation.name`, `error.type` |

These reach Mimir through the agent tier's `metrics/otlp` pipeline. They are
**not** the same as `traces_span_metrics_*`, which the `spanmetrics` connector
derives from spans — token counts have to come from the SDK because only the
application sees the usage block.

Note on querying: OTLP resource attributes fold into `target_info`, except
`service.name`/`service.namespace` which become `job`. So filter by `job=`;
filtering by pod or node needs a `target_info` join.

## Prompt and completion content

Content is **off by default** and controlled centrally. Read the standard env
var — do not invent your own flag:

```python
capture = os.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "false") == "true"
```

When it is true, do **both** of these:

1. Attach the text as span **events** named `gen_ai.content.prompt` and
   `gen_ai.content.completion`.
2. Set the span attribute **`gen_ai.capture.content = true`**.

That second one is not decoration. The gateway's `routing` connector uses it to
send content-bearing traces to the `agents-content` Tempo tenant, which has 7d
retention and is not wired into Grafana. OTTL cannot inspect a span's events
from the span context, so this attribute is the only signal the collector has.

**Omit it and prompt text lands in the 30-day tenant everyone reads.**

Content is additionally scrubbed by the `redaction` processor in the agent tier
before it leaves the node, but redaction is a backstop for secrets — it is not
a substitute for routing.

Turning capture on is time-boxed and audited:

```bash
make obs-capture ON=true TTL=30m
```

## Handling refusals

Claude Opus 5 can decline with HTTP 200 and `stop_reason: "refusal"`. Check
`stop_reason` before reading `content`, record it as a span error, and set
`gen_ai.response.finish_reasons` to `["refusal"]`. `response.stop_details`
carries the category.

Server-side fallbacks are recommended on Opus 5 so a refusal routes to another
model rather than failing the request:

```python
betas=["server-side-fallback-2026-07-01"], fallbacks="default"
```

## Worked example

`examples/genai-agent/` implements all of the above, including a `FAKE_LLM=true`
mode that emits the identical telemetry shape with no API key and no spend —
useful for exercising the pipeline in CI or dev.
