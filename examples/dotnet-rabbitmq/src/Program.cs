// OrderFlow -- a two-role .NET sample showing OpenTelemetry traces crossing
// a RabbitMQ queue, and giving KEDA a queue to scale the consumer on.
//
// One binary, two roles selected by the ROLE env var:
//   ROLE=producer   publishes an "order" message every PUBLISH_INTERVAL_MS
//   ROLE=consumer   consumes orders, simulating WORK_MS of work each
//
// The interesting part is trace context propagation. A producer span and the
// consumer span that handles the same message belong to ONE trace, even
// though the two processes never talk directly and may not even overlap in
// time. That works because the producer injects the W3C `traceparent` into
// the AMQP message headers and the consumer extracts it and uses it as the
// parent of its own span. Nothing does this for us: RabbitMQ is not HTTP, so
// there is no automatic header plumbing -- it's the Inject/Extract pair
// below, which is exactly what an auto-instrumentation library would do.
using System.Diagnostics;
using System.Text;
using OpenTelemetry;
using OpenTelemetry.Context.Propagation;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

var role     = Env("ROLE", "producer").ToLowerInvariant();
var queue    = Env("QUEUE", "orders");
var host     = Env("RABBITMQ_HOST", "rabbitmq.rabbitmq.svc");
var user     = Env("RABBITMQ_USER", "homelab");
var pass     = Env("RABBITMQ_PASS", "HomelabRabbit123!");
var otlp     = Env("OTEL_EXPORTER_OTLP_ENDPOINT",
                   "http://otel-collector-opentelemetry-collector.otel.svc:4317");
var service  = Env("OTEL_SERVICE_NAME", $"orderflow-{role}");
var interval = int.Parse(Env("PUBLISH_INTERVAL_MS", "250"));
var workMs   = int.Parse(Env("WORK_MS", "400"));

// One ActivitySource for the app; its name is what we register with the
// tracer provider below via AddSource.
const string SourceName = "OrderFlow";
using var source = new ActivitySource(SourceName);

using var tracer = Sdk.CreateTracerProviderBuilder()
    .AddSource(SourceName)
    .SetResourceBuilder(ResourceBuilder.CreateDefault()
        .AddService(serviceName: service, serviceVersion: "1.0.0")
        .AddAttributes(new Dictionary<string, object>
        {
            ["deployment.environment"] = "homelab",
            ["messaging.system"]       = "rabbitmq",
        }))
    .AddOtlpExporter(o =>
    {
        o.Endpoint = new Uri(otlp);
        o.Protocol = OpenTelemetry.Exporter.OtlpExportProtocol.Grpc;
    })
    .Build();

// W3C traceparent/tracestate. Set explicitly rather than relying on the
// default so the wire format is obvious in this sample.
var propagator = new TraceContextPropagator();

Console.WriteLine($"[{role}] queue={queue} host={host} otlp={otlp} service={service}");

var factory = new ConnectionFactory
{
    HostName = host,
    UserName = user,
    Password = pass,
};

// RabbitMQ may still be starting when we are; retry rather than crash-loop.
IConnection connection = await ConnectWithRetryAsync(factory);
await using var conn = connection;
await using var channel = await conn.CreateChannelAsync();

await channel.QueueDeclareAsync(queue: queue, durable: true, exclusive: false,
                                autoDelete: false, arguments: null);

using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; shutdown.Cancel(); };

if (role == "producer")
    await RunProducerAsync(shutdown.Token);
else
    await RunConsumerAsync(shutdown.Token);

// ---------------------------------------------------------------- producer

async Task RunProducerAsync(CancellationToken ct)
{
    var n = 0;
    while (!ct.IsCancellationRequested)
    {
        var orderId = $"order-{Interlocked.Increment(ref n):D6}";

        // Producer span. ActivityKind.Producer is what marks it as the
        // send side of a messaging hop in Tempo/Grafana's waterfall.
        using var activity = source.StartActivity("orders publish", ActivityKind.Producer);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", queue);
        activity?.SetTag("messaging.operation", "publish");
        activity?.SetTag("order.id", orderId);

        var headers = new Dictionary<string, object?>();
        if (activity is not null)
        {
            // Inject the current span's context into the AMQP headers. This
            // is the hop that makes producer and consumer one trace.
            propagator.Inject(
                new PropagationContext(activity.Context, Baggage.Current),
                headers,
                static (carrier, key, value) => carrier[key] = Encoding.UTF8.GetBytes(value));
        }

        var props = new BasicProperties
        {
            Persistent = true,
            Headers = headers!,
            ContentType = "application/json",
        };

        var body = Encoding.UTF8.GetBytes(
            $"{{\"orderId\":\"{orderId}\",\"ts\":\"{DateTimeOffset.UtcNow:O}\"}}");

        await channel.BasicPublishAsync(exchange: "", routingKey: queue,
                                        mandatory: false, basicProperties: props,
                                        body: body, cancellationToken: ct);

        Console.WriteLine($"[producer] sent {orderId} traceId={activity?.TraceId}");
        try { await Task.Delay(interval, ct); } catch (OperationCanceledException) { break; }
    }
}

// ---------------------------------------------------------------- consumer

async Task RunConsumerAsync(CancellationToken ct)
{
    // Only hand this consumer one unacked message at a time. Without it a
    // single consumer grabs the whole queue, queue depth drops to zero, and
    // KEDA sees nothing to scale on.
    await channel.BasicQosAsync(prefetchSize: 0, prefetchCount: 1, global: false);

    var consumer = new AsyncEventingBasicConsumer(channel);
    consumer.ReceivedAsync += async (_, ea) =>
    {
        // Pull the traceparent back out of the headers and make it the
        // parent of the consumer span.
        var parent = propagator.Extract(default, ea.BasicProperties.Headers,
            static (carrier, key) =>
            {
                if (carrier is not null && carrier.TryGetValue(key, out var v) && v is byte[] b)
                    return new[] { Encoding.UTF8.GetString(b) };
                return Array.Empty<string>();
            });

        using var activity = source.StartActivity(
            "orders process", ActivityKind.Consumer, parent.ActivityContext);

        var json = Encoding.UTF8.GetString(ea.Body.ToArray());
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", queue);
        activity?.SetTag("messaging.operation", "process");
        activity?.SetTag("messaging.message.body.size", ea.Body.Length);

        try
        {
            // A child span, so the waterfall shows work nested under the
            // consume rather than one flat span.
            using (var work = source.StartActivity("validate order", ActivityKind.Internal))
            {
                work?.SetTag("order.payload", json);
                await Task.Delay(workMs, ct);
            }

            await channel.BasicAckAsync(ea.DeliveryTag, multiple: false, cancellationToken: ct);
            activity?.SetStatus(ActivityStatusCode.Ok);
            Console.WriteLine($"[consumer] processed {json} traceId={activity?.TraceId}");
        }
        catch (Exception ex)
        {
            // Record the failure on the span, then requeue.
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.AddException(ex);
            await channel.BasicNackAsync(ea.DeliveryTag, multiple: false,
                                         requeue: true, cancellationToken: ct);
        }
    };

    await channel.BasicConsumeAsync(queue: queue, autoAck: false, consumer: consumer);
    Console.WriteLine("[consumer] waiting for messages");
    try { await Task.Delay(Timeout.Infinite, ct); } catch (OperationCanceledException) { }
}

// ----------------------------------------------------------------- helpers

async Task<IConnection> ConnectWithRetryAsync(ConnectionFactory f)
{
    for (var attempt = 1; ; attempt++)
    {
        try { return await f.CreateConnectionAsync(); }
        catch (Exception ex) when (attempt < 30)
        {
            Console.WriteLine($"[{role}] rabbitmq not ready (attempt {attempt}): {ex.Message}");
            await Task.Delay(TimeSpan.FromSeconds(2));
        }
    }
}

static string Env(string key, string fallback) =>
    Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;
