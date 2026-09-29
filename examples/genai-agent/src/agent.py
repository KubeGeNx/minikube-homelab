"""Worked example of the GenAI instrumentation contract (docs/genai-instrumentation.md).

An "ops assistant" agent: Claude answers a question using two local tools, and
every step is instrumented by hand rather than by an auto-instrumentation
package. That is deliberate, and it mirrors the choice the .NET sample in
examples/dotnet-rabbitmq/ made with the messaging.* attributes -- when the
attributes are written out explicitly you can see exactly which ones the
sampling policies and tenant routing depend on.

Two modes, emitting the SAME telemetry shape:

  FAKE_LLM=true   (default) synthesises a response, including a tool call and
                  plausible token counts. No API key, no spend, no network.
                  This is what makes the pipeline exercisable in CI and dev.
  FAKE_LLM=false  real calls via the Anthropic SDK's tool runner.
"""

import os
import random
import time

from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "genai-agent")
MODEL = os.getenv("MODEL", "claude-opus-5")
FAKE_LLM = os.getenv("FAKE_LLM", "true").lower() == "true"
INTERVAL_S = float(os.getenv("REQUEST_INTERVAL_S", "15"))

# The standard GenAI opt-in, supplied by the observability-levels ConfigMap.
# Read at call time, not import time: the pod is restarted when it changes, but
# reading late costs nothing and avoids a stale-module surprise in tests.
def content_capture_enabled() -> bool:
    return os.getenv("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "false").lower() == "true"


# --------------------------------------------------------------------------
# OpenTelemetry wiring
# --------------------------------------------------------------------------
resource = Resource.create({"service.name": SERVICE_NAME})

_tracer_provider = TracerProvider(resource=resource)
_tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(_tracer_provider)

_meter_provider = MeterProvider(
    resource=resource,
    metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter())],
)
metrics.set_meter_provider(_meter_provider)

tracer = trace.get_tracer(SERVICE_NAME)
meter = metrics.get_meter(SERVICE_NAME)

# Names and units from the GenAI semantic conventions. Mimir turns these into
# gen_ai_client_token_usage_* and gen_ai_client_operation_duration_seconds_*.
token_usage = meter.create_histogram(
    "gen_ai.client.token.usage", unit="{token}", description="Tokens used per model call"
)
operation_duration = meter.create_histogram(
    "gen_ai.client.operation.duration", unit="s", description="Model call duration"
)


# --------------------------------------------------------------------------
# Tools. Pure Python on purpose -- no Kubernetes API, no RBAC, nothing to
# provision. The point is the SPAN SHAPE, not the tool's cleverness.
# --------------------------------------------------------------------------
_OWNERS = {
    "checkout": "payments-team",
    "search": "discovery-team",
    "orderflow": "platform-team",
}


def _lookup_service_owner(service: str) -> str:
    """Body of the lookup tool, wrapped in a span by both modes."""
    with tracer.start_as_current_span("execute_tool lookup_service_owner", kind=SpanKind.INTERNAL) as span:
        span.set_attribute("gen_ai.operation.name", "execute_tool")
        span.set_attribute("gen_ai.tool.name", "lookup_service_owner")
        # Real work would go here; the sleep stands in for it so the span has a
        # duration worth looking at in a waterfall.
        time.sleep(random.uniform(0.02, 0.12))
        owner = _OWNERS.get(service.lower())
        if owner is None:
            span.set_attribute("error.type", "UnknownService")
            span.set_status(Status(StatusCode.ERROR, f"unknown service {service}"))
            return f"No owner registered for '{service}'."
        return f"{service} is owned by {owner}."


def _compute_error_budget(slo_percent: float, actual_percent: float) -> str:
    """Body of the error-budget tool."""
    with tracer.start_as_current_span("execute_tool compute_error_budget", kind=SpanKind.INTERNAL) as span:
        span.set_attribute("gen_ai.operation.name", "execute_tool")
        span.set_attribute("gen_ai.tool.name", "compute_error_budget")
        time.sleep(random.uniform(0.02, 0.08))
        allowed = 100.0 - slo_percent
        consumed = 100.0 - actual_percent
        if allowed <= 0:
            span.set_attribute("error.type", "InvalidSLO")
            span.set_status(Status(StatusCode.ERROR, "SLO must be below 100%"))
            return "An SLO of 100% leaves no error budget."
        pct = (consumed / allowed) * 100.0
        span.set_attribute("error_budget.consumed_percent", round(pct, 2))
        return f"{pct:.1f}% of the error budget is consumed."


# --------------------------------------------------------------------------
# Shared telemetry helper -- both modes go through this so the fake path
# cannot drift from the real one.
# --------------------------------------------------------------------------
def _record_model_call(span, *, prompt, completion, input_tokens, output_tokens,
                       finish_reason, response_model, started_at, error_type=None):
    span.set_attribute("gen_ai.system", "anthropic")
    span.set_attribute("gen_ai.operation.name", "chat")
    span.set_attribute("gen_ai.request.model", MODEL)
    span.set_attribute("gen_ai.response.model", response_model or MODEL)
    span.set_attribute("gen_ai.usage.input_tokens", input_tokens)
    # Tail sampling keeps any trace where this exceeds 4000 -- expensive calls
    # are the ones worth being able to read back.
    span.set_attribute("gen_ai.usage.output_tokens", output_tokens)
    span.set_attribute("gen_ai.response.finish_reasons", [finish_reason])

    if content_capture_enabled():
        # BOTH of these are required by the contract. The attribute is what the
        # gateway's routing connector matches on to divert this trace into the
        # short-retention `agents-content` tenant; without it the prompt text
        # would land in the 30-day tenant everyone reads.
        span.set_attribute("gen_ai.capture.content", True)
        span.add_event("gen_ai.content.prompt", {"gen_ai.prompt": prompt})
        span.add_event("gen_ai.content.completion", {"gen_ai.completion": completion})

    attrs = {
        "gen_ai.system": "anthropic",
        "gen_ai.request.model": MODEL,
        "gen_ai.operation.name": "chat",
    }
    token_usage.record(input_tokens, {**attrs, "gen_ai.token.type": "input"})
    token_usage.record(output_tokens, {**attrs, "gen_ai.token.type": "output"})

    duration_attrs = dict(attrs)
    if error_type:
        span.set_attribute("error.type", error_type)
        span.set_status(Status(StatusCode.ERROR, error_type))
        duration_attrs["error.type"] = error_type
    operation_duration.record(time.monotonic() - started_at, duration_attrs)


# --------------------------------------------------------------------------
# Fake mode
# --------------------------------------------------------------------------
_QUESTIONS = [
    ("Who owns the checkout service?", "checkout"),
    ("Who owns orderflow?", "orderflow"),
    ("Who owns the search service?", "search"),
    ("Who owns billing?", "billing"),  # deliberately unknown -> tool error path
]


def run_fake_once():
    question, service = random.choice(_QUESTIONS)
    started = time.monotonic()
    with tracer.start_as_current_span(f"chat {MODEL}", kind=SpanKind.CLIENT) as span:
        # Roughly 1 in 12 runs refuses, so the refusal path is exercised often
        # enough to appear on a dashboard but rarely enough to look realistic.
        refused = random.random() < 0.08
        if refused:
            _record_model_call(
                span, prompt=question, completion="", input_tokens=random.randint(400, 900),
                output_tokens=0, finish_reason="refusal", response_model=MODEL,
                started_at=started, error_type="refusal",
            )
            return

        tool_answer = _lookup_service_owner(service)
        if random.random() < 0.4:
            tool_answer += " " + _compute_error_budget(99.9, random.uniform(99.5, 100.0))

        completion = f"{tool_answer} (synthesised: FAKE_LLM=true)"
        _record_model_call(
            span, prompt=question, completion=completion,
            input_tokens=random.randint(600, 1400),
            # Occasionally large, to exercise the >4000 tail-sampling policy.
            output_tokens=random.choice([120, 240, 380, 4200]),
            finish_reason="end_turn", response_model=MODEL, started_at=started,
        )


# --------------------------------------------------------------------------
# Real mode
# --------------------------------------------------------------------------
def run_real_once():
    import anthropic
    from anthropic import beta_tool

    client = anthropic.Anthropic()

    @beta_tool
    def lookup_service_owner(service: str) -> str:
        """Look up which team owns a service.

        Args:
            service: The service name, e.g. checkout.
        """
        return _lookup_service_owner(service)

    @beta_tool
    def compute_error_budget(slo_percent: float, actual_percent: float) -> str:
        """Compute how much of an error budget has been consumed.

        Args:
            slo_percent: The availability target, e.g. 99.9.
            actual_percent: Measured availability, e.g. 99.95.
        """
        return _compute_error_budget(slo_percent, actual_percent)

    question, _ = random.choice(_QUESTIONS)
    started = time.monotonic()

    with tracer.start_as_current_span(f"chat {MODEL}", kind=SpanKind.CLIENT) as span:
        try:
            runner = client.beta.messages.tool_runner(
                model=MODEL,
                max_tokens=16000,
                # Adaptive thinking is the only on-mode on current models;
                # budget_tokens is rejected with a 400.
                thinking={"type": "adaptive"},
                # A refusal on Opus 5 arrives as HTTP 200 with
                # stop_reason="refusal". Server-side fallbacks route it to
                # another model instead of returning nothing useful.
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                tools=[lookup_service_owner, compute_error_budget],
                messages=[{"role": "user", "content": question}],
            )

            final = None
            in_tokens = out_tokens = 0
            for message in runner:
                final = message
                # The runner yields one message per iteration; usage is
                # per-message, so accumulate rather than reading only the last.
                in_tokens += message.usage.input_tokens
                out_tokens += message.usage.output_tokens

            if final is None:
                raise RuntimeError("tool runner produced no messages")

            # Check stop_reason BEFORE reading content -- on a refusal the
            # content block is not the answer.
            if final.stop_reason == "refusal":
                _record_model_call(
                    span, prompt=question, completion="", input_tokens=in_tokens,
                    output_tokens=out_tokens, finish_reason="refusal",
                    response_model=final.model, started_at=started, error_type="refusal",
                )
                return

            completion = "".join(
                block.text for block in final.content if getattr(block, "type", None) == "text"
            )
            _record_model_call(
                span, prompt=question, completion=completion, input_tokens=in_tokens,
                output_tokens=out_tokens, finish_reason=final.stop_reason or "end_turn",
                response_model=final.model, started_at=started,
            )
        except Exception as exc:  # noqa: BLE001 -- recorded, then re-raised to the loop
            _record_model_call(
                span, prompt=question, completion="", input_tokens=0, output_tokens=0,
                finish_reason="error", response_model=MODEL, started_at=started,
                error_type=type(exc).__name__,
            )
            span.record_exception(exc)
            raise


def main():
    mode = "FAKE" if FAKE_LLM else "REAL"
    print(f"{SERVICE_NAME}: mode={mode} model={MODEL} interval={INTERVAL_S}s", flush=True)
    print(f"  content capture: {content_capture_enabled()}", flush=True)
    try:
        while True:
            try:
                run_fake_once() if FAKE_LLM else run_real_once()
            except Exception as exc:  # noqa: BLE001
                # Keep the loop alive; the failure is already on a span.
                print(f"  call failed: {type(exc).__name__}: {exc}", flush=True)
            time.sleep(INTERVAL_S)
    except KeyboardInterrupt:
        pass
    finally:
        # Spans and metrics sit in batch buffers. Without an explicit flush a
        # SIGTERM loses whatever accumulated since the last export tick -- the
        # same failure the .NET sample documents at length in its README.
        print("shutting down, flushing telemetry...", flush=True)
        _tracer_provider.shutdown()
        _meter_provider.shutdown()


if __name__ == "__main__":
    main()
