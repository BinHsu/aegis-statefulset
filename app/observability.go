// app/observability.go
//
// Telemetry bootstrap for the POC mock — per ADR-06 § 2-4.
//
//   - Traces:  OTLP/HTTP exporter to OTEL_EXPORTER_OTLP_ENDPOINT (default
//              the in-cluster Alloy at alloy.monitoring.svc.cluster.local:4318).
//              Auto-instrumentation supplied by otelhttp on the HTTP server;
//              manual spans wrap the file ops inside the handler (see main.go).
//   - Metrics: process + Go runtime counters via the default Prometheus
//              registry, plus an app-level counter for data ops broken down
//              by op (read/write) and outcome (ok/err). Exposed on :9090.
//   - Logs:    structured JSON via log/slog, with trace_id / span_id pulled
//              from the request context and added as attributes — closes the
//              log line → trace pivot the 90-second debug workflow needs.
//
// Designed to be safe with no OTLP backend configured: a tracing setup
// failure logs a warning and falls back to a no-op tracer, so the app stays
// up. Same for metrics — /metrics serves whatever's registered.

package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
)

const serviceName = "aegis-stateful-mock"

// dataOpsTotal is the app-level counter wired into the /data handler.
// op = read | write, outcome = ok | err.
var dataOpsTotal = promauto.NewCounterVec(
	prometheus.CounterOpts{
		Name: "aegis_data_ops_total",
		Help: "Count of /data operations broken down by op (read|write) and outcome (ok|err).",
	},
	[]string{"op", "outcome"},
)

// tracer is the package-level tracer. Resolves via the global TracerProvider:
// no-op until setupTracing wires the SDK in main().
func tracer() trace.Tracer {
	return otel.Tracer(serviceName)
}

// setupTracing wires the OTLP/HTTP trace exporter to OTEL_EXPORTER_OTLP_ENDPOINT.
// Returns a shutdown function the caller must call on SIGTERM to flush
// in-flight spans (the 90-second debug workflow relies on no-dropped-spans
// during graceful shutdown).
func setupTracing(ctx context.Context) (shutdown func(context.Context) error, err error) {
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(versionFromEnv()),
		),
		resource.WithFromEnv(),     // picks up OTEL_RESOURCE_ATTRIBUTES (k8s pod name etc.)
		resource.WithProcess(),     // pid, runtime
		resource.WithHost(),        // hostname
		resource.WithTelemetrySDK(), // SDK identity
	)
	if err != nil {
		return nil, err
	}

	exp, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(res),
		// Head-sampling is intentionally permissive (AlwaysSample) at the
		// app SDK layer; tail-sampling per ADR-06 § 4 happens in Alloy /
		// the OTel Collector downstream, which has the cross-span visibility
		// the app SDK lacks.
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown, nil
}

// versionFromEnv reads the build version from $APP_VERSION (set by the
// helm chart from values.yaml), fallback to "dev".
func versionFromEnv() string {
	if v := os.Getenv("APP_VERSION"); v != "" {
		return v
	}
	return "dev"
}

// traceContextHandler wraps an slog.Handler and decorates every record
// with trace_id + span_id pulled from the context (per ADR-06 § 3 — every
// log line must be pivot-able to its originating trace via trace_id).
type traceContextHandler struct {
	inner slog.Handler
}

func (h *traceContextHandler) Enabled(ctx context.Context, lvl slog.Level) bool {
	return h.inner.Enabled(ctx, lvl)
}

func (h *traceContextHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.inner.Handle(ctx, r)
}

func (h *traceContextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &traceContextHandler{inner: h.inner.WithAttrs(attrs)}
}

func (h *traceContextHandler) WithGroup(name string) slog.Handler {
	return &traceContextHandler{inner: h.inner.WithGroup(name)}
}

// newLogger returns the package-level slog logger — JSON to stdout (Alloy
// tails it via loki.source.kubernetes), with trace context injected.
func newLogger() *slog.Logger {
	base := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	return slog.New(&traceContextHandler{inner: base})
}
