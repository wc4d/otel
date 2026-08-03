import json
import logging
import os
import time
from typing import Any

from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "otel-lambda-demo")
OTLP_ENDPOINT = os.getenv("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT") or (
    os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318").rstrip("/")
    + "/v1/metrics"
)

resource = Resource.create(
    {
        "service.name": SERVICE_NAME,
        "service.namespace": os.getenv("OTEL_SERVICE_NAMESPACE", "lambda-demo"),
        "deployment.environment.name": os.getenv("DEPLOYMENT_ENVIRONMENT", "demo"),
    }
)
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=OTLP_ENDPOINT),
    export_interval_millis=int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", "1000")),
    export_timeout_millis=int(os.getenv("OTEL_METRIC_EXPORT_TIMEOUT", "5000")),
)
meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)
meter = metrics.get_meter("otel.lambda.demo", "1.0.0")

request_counter = meter.create_counter(
    "demo.requests",
    unit="{request}",
    description="Number of demo API requests",
)
sample_counter = meter.create_counter(
    "demo.samples",
    unit="{sample}",
    description="Number of requested sample metric points",
)
latency_histogram = meter.create_histogram(
    "demo.handler.duration",
    unit="ms",
    description="Demo handler execution duration",
)


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    started = time.perf_counter()
    query = event.get("queryStringParameters") or {}

    try:
        count = int(query.get("count", "3"))
    except (TypeError, ValueError):
        return _response(400, {"message": "count must be an integer from 1 to 100"})

    if count < 1 or count > 100:
        return _response(400, {"message": "count must be an integer from 1 to 100"})

    route = event.get("rawPath", "/metrics")
    attributes = {"route": route, "function": SERVICE_NAME}
    request_counter.add(1, attributes)
    sample_counter.add(count, attributes)
    latency_histogram.record((time.perf_counter() - started) * 1000, attributes)

    # Push the SDK buffer to the collector before Lambda freezes the runtime.
    flushed = meter_provider.force_flush(
        timeout_millis=int(os.getenv("OTEL_METRIC_EXPORT_TIMEOUT", "5000"))
    )
    LOGGER.info("Emitted %s samples to %s; flushed=%s", count, OTLP_ENDPOINT, flushed)

    return _response(
        200,
        {
            "message": "Sample OpenTelemetry metrics emitted",
            "sampleCount": count,
            "collectorEndpoint": OTLP_ENDPOINT,
            "flushed": flushed,
            "requestId": getattr(context, "aws_request_id", "local"),
        },
    )

