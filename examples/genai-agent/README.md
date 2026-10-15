# GenAI agent — the worked example

Implements `docs/genai-instrumentation.md` end to end: an agent that answers a
question using two tools, with every span, attribute, and metric written out by
hand rather than produced by an auto-instrumentation package.

Manual instrumentation is the point. When the attributes are explicit you can
see exactly which ones the platform's sampling policies and tenant routing
depend on — the same choice `examples/dotnet-rabbitmq/` made with `messaging.*`.

## Run it without an API key

```bash
eval $(minikube -p homelab docker-env)
docker build -t genai-agent:1.0.0 examples/genai-agent/src
kubectl apply -f examples/genai-agent/k8s.yaml
```

`FAKE_LLM=true` is the default. It synthesises responses and token counts and
never calls the API, so the entire pipeline — spans, tool children, token
metrics, refusals, tenant routing — is exercisable with no key and no spend.
That matters beyond convenience: it makes the platform testable in CI.

For real calls:

```bash
ANTHROPIC_API_KEY=sk-ant-... ./scripts/13-genai-agent-secret.sh
kubectl -n default set env deployment/genai-agent FAKE_LLM=false
```

## What it emits

One trace per question:

```
chat claude-opus-5                        CLIENT
├── execute_tool lookup_service_owner     INTERNAL
└── execute_tool compute_error_budget     INTERNAL   (sometimes)
```

On the parent span:

| Attribute | Notes |
|---|---|
| `gen_ai.system` = `anthropic` | |
| `gen_ai.request.model` / `gen_ai.response.model` | differ when a fallback fires |
| `gen_ai.usage.input_tokens` / `output_tokens` | occasionally >4000, to exercise the cost sampling policy |
| `gen_ai.response.finish_reasons` | `end_turn` or `refusal` |
| `error.type` | on refusal or exception |

Metrics `gen_ai.client.token.usage` and `gen_ai.client.operation.duration` go
to Mimir through the agent tier's `metrics/otlp` pipeline.

The fake mode deliberately produces awkward cases, because a sample that only
ever succeeds tells you nothing about your dashboards:

- ~8% of runs **refuse** → span status ERROR, `finish_reasons: ["refusal"]`
- asking about `billing` hits an **unknown service** → the *tool* span errors
  while the model call succeeds
- some runs return 4200 output tokens → kept by the cost sampling policy even
  at 10% baseline

## Seeing content — and why it is off

Prompt and completion text is not captured by default. Turn it on for a
bounded window:

```bash
make obs-capture ON=true TTL=30m
```

The agent then sets `gen_ai.capture.content = true` on the span **and** attaches
`gen_ai.content.prompt` / `gen_ai.content.completion` events. That attribute is
load-bearing: the gateway's `routing` connector uses it to divert the trace to
the `agents-content` Tempo tenant (7d retention). Without it the prompt text
would land in the 30-day tenant everyone reads.

Content is *not* a Grafana datasource. Grafana OSS has no datasource-level
RBAC, so wiring one would expose prompt text to every Grafana user while
looking access-controlled. Query it directly:

```bash
kubectl -n tracing port-forward svc/tempo-query-frontend 3200:3200
curl -H 'X-Scope-OrgID: agents-content' localhost:3200/api/search
```

Capture switches itself off at the TTL — a CronJob checks every 5 minutes and
fails closed if the expiry is missing.

## Finding it in Grafana

```traceql
{ resource.service.name = "genai-agent" }
{ span.gen_ai.usage.output_tokens > 4000 }        # the expensive ones
{ span.gen_ai.response.finish_reasons[] = "refusal" }
```

Token spend by model, over the last hour:

```promql
sum by (gen_ai_request_model, gen_ai_token_type) (
  rate(gen_ai_client_token_usage_sum[1h])
)
```

RED metrics come from the `spanmetrics` connector in the agent tier, which sits
*in front of* tail sampling — so these count every request, not the sampled
remainder:

```promql
sum(rate(traces_span_metrics_calls_total{service_name="genai-agent"}[5m]))
```

## Local run, without Kubernetes

```bash
python -m venv .venv && .venv/bin/pip install -r src/requirements.txt
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_SERVICE_NAME=genai-agent FAKE_LLM=true \
  .venv/bin/python src/agent.py
```

## Shutdown

Both providers are shut down explicitly in a `finally` block. Spans and metrics
sit in batch buffers, and without that flush a SIGTERM loses everything
accumulated since the last export tick — producing traces whose root span never
arrives. `examples/dotnet-rabbitmq/README.md` documents the same failure in
detail; it is not language-specific.
