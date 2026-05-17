// app/main.go
//
// POC placeholder for the customer's LevelDB-backed application.
// A trivial key-value HTTP service writing to the /data filesystem.
//
// Why this exists:
//   The take-home submission deliberately swaps the real application for the
//   smallest mock that exercises the same operational shape — a stateful pod
//   that owns a PV, writes to disk, and survives node loss only when the PV
//   is preserved. That is enough to demonstrate the platform behaviours
//   under chaos (subnet delete, AZ rotation, region cutover) without
//   shipping a half-built LevelDB implementation that would distract from
//   the architectural review.
//
// Endpoints:
//   POST /data      {"key": "...", "value": "..."}   -> 204 / 4xx     (:8080)
//   GET  /data?key=...                               -> body / 404    (:8080)
//   GET  /healthz                                    -> 200 ok        (:8080)
//   GET  /metrics                                    -> Prometheus    (:9090)
//
// Storage: one file per key under <dataDir>/<key>. PV is mounted at /data.
//
// Observability (ADR-06):
//   - Traces  → OTLP/HTTP to OTEL_EXPORTER_OTLP_ENDPOINT (Alloy in-cluster).
//               otelhttp auto-instruments /data; manual spans wrap each
//               file op so a slow disk shows up at the file-ops span, not
//               just the HTTP root span.
//   - Metrics → /metrics on :9090. Go runtime + process collectors + an
//               app-level aegis_data_ops_total counter (op × outcome).
//   - Logs    → JSON via slog; trace_id + span_id auto-injected so the
//               90-second debug workflow can pivot from log → trace.
//
// Graceful shutdown (per ADR-02 § Graceful shutdown):
//   On SIGTERM the server stops accepting new connections, drains in-flight
//   requests, flushes pending spans via OTel TracerProvider.Shutdown, fsyncs
//   the data directory, then exits. K8s `terminationGracePeriodSeconds`
//   (60s default) bounds the drain window; inside it the app does
//   http.Server.Shutdown(ctx) with a 30s deadline, which is conservative
//   for the POC's filesystem ops and headroom for a real LevelDB Close() in
//   production.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

const defaultDataDir = "/data"

// errInvalidKey is returned by writeKey/readKey when the key would not be
// a safe single filesystem path element. The handler maps it to 400.
var errInvalidKey = errors.New("invalid key")

// keyPattern admits exactly one safe path element: an alphanumeric first
// character followed by up to 127 alphanumerics / dot / dash / underscore.
// It rejects the empty string, "." and ".." (the leading character must be
// alphanumeric), and anything containing a path separator. That closes the
// traversal vector where a request key like "../../etc/passwd" would escape
// the data directory — CodeQL go/path-injection. A real LevelDB app keys on
// opaque byte strings and has no such surface; this mock writes one file
// per key, so it must validate the key before touching the filesystem.
var keyPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// validKey reports whether key is a safe single path element (see
// keyPattern). It is the path-traversal barrier for writeKey/readKey.
func validKey(key string) bool {
	return keyPattern.MatchString(key)
}

// routes builds the HTTP mux. Exposed for tests; main() wraps it in otelhttp
// before binding to :8080 so each request has a root span before reaching
// the handler. Manual spans inside the handler wrap the storage ops per
// ADR-06 § 4 ("manual spans wrap LevelDB operations").
func routes(dataDir string) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/data", func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()

		switch r.Method {
		case http.MethodPost:
			var body struct{ Key, Value string }
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, "Invalid JSON", http.StatusBadRequest)
				return
			}
			if body.Key == "" {
				http.Error(w, "Missing key", http.StatusBadRequest)
				return
			}
			if err := writeKey(ctx, dataDir, body.Key, body.Value); err != nil {
				if errors.Is(err, errInvalidKey) {
					http.Error(w, "Invalid key", http.StatusBadRequest)
					return
				}
				http.Error(w, "Write failed", http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusNoContent)

		case http.MethodGet:
			key := r.URL.Query().Get("key")
			if key == "" {
				http.Error(w, "Missing key parameter", http.StatusBadRequest)
				return
			}
			data, err := readKey(ctx, dataDir, key)
			if err != nil {
				if errors.Is(err, errInvalidKey) {
					http.Error(w, "Invalid key", http.StatusBadRequest)
					return
				}
				http.NotFound(w, r)
				return
			}
			_, _ = io.WriteString(w, string(data))

		default:
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	})

	// /healthz — liveness: the process is up and serving.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	// /ready — readiness: the pod can take traffic. The helm chart's
	// startup + readiness probes target this path. For the POC mock,
	// readiness == liveness (no warm-up state); a real LevelDB-backed
	// app would gate this on MemTable rebuild completion.
	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})

	return mux
}

// writeKey persists value at <dataDir>/<key>. Manual span captures op
// duration + key length + outcome — these are the attributes the on-call
// engineer queries when LDB write latency spikes.
func writeKey(ctx context.Context, dataDir, key, value string) error {
	_, span := tracer().Start(ctx, "fileops.write", trace.WithAttributes(
		attribute.String("op", "write"),
		attribute.Int("key.length", len(key)),
		attribute.Int("value.length", len(value)),
	))
	defer span.End()

	// Path-traversal barrier — reject any key that is not a safe single
	// path element before it reaches filepath.Join (CodeQL go/path-injection).
	if !validKey(key) {
		span.SetStatus(codes.Error, "invalid key")
		dataOpsTotal.WithLabelValues("write", "err").Inc()
		return errInvalidKey
	}

	if err := os.WriteFile(filepath.Join(dataDir, key), []byte(value), 0o644); err != nil {
		span.SetStatus(codes.Error, "write failed")
		span.RecordError(err)
		dataOpsTotal.WithLabelValues("write", "err").Inc()
		return err
	}
	dataOpsTotal.WithLabelValues("write", "ok").Inc()
	return nil
}

// readKey loads <dataDir>/<key>. Manual span mirrors writeKey for the read
// side of the workload.
func readKey(ctx context.Context, dataDir, key string) ([]byte, error) {
	_, span := tracer().Start(ctx, "fileops.read", trace.WithAttributes(
		attribute.String("op", "read"),
		attribute.Int("key.length", len(key)),
	))
	defer span.End()

	// Path-traversal barrier — see writeKey.
	if !validKey(key) {
		span.SetStatus(codes.Error, "invalid key")
		dataOpsTotal.WithLabelValues("read", "err").Inc()
		return nil, errInvalidKey
	}

	data, err := os.ReadFile(filepath.Join(dataDir, key))
	if err != nil {
		span.SetStatus(codes.Error, "read failed")
		span.RecordError(err)
		dataOpsTotal.WithLabelValues("read", "err").Inc()
		return nil, err
	}
	span.SetAttributes(attribute.Int("bytes.read", len(data)))
	dataOpsTotal.WithLabelValues("read", "ok").Inc()
	return data, nil
}

// fsyncDir flushes pending writes for the data directory itself (file
// renames, new file creations) — a real LevelDB would also Close() its
// instance here to flush MemTable + WAL + release file lock.
func fsyncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func main() {
	logger := newLogger()

	ctx := context.Background()
	shutdownTracing, err := setupTracing(ctx)
	if err != nil {
		// Tracing setup failure is non-fatal — fall back to the no-op tracer
		// so the app stays up; the operator sees the warning in Loki and
		// can fix the OTLP endpoint without a pod restart loop.
		logger.WarnContext(ctx, "tracing setup failed; continuing with no-op tracer", "err", err)
		shutdownTracing = func(context.Context) error { return nil }
	}

	if err := os.MkdirAll(defaultDataDir, 0o755); err != nil {
		logger.ErrorContext(ctx, "failed to create data directory", "err", err)
		os.Exit(1)
	}

	// API server on :8080 — wrapped in otelhttp for HTTP root span +
	// W3C traceparent propagation per ADR-06 § 2.
	apiSrv := &http.Server{
		Addr: ":8080",
		Handler: otelhttp.NewHandler(routes(defaultDataDir), "http.server",
			otelhttp.WithServerName(serviceName),
		),
	}

	// Metrics server on :9090 — separate listener so /metrics survives
	// even if the API server is wedged (the symptom the dashboard most
	// needs to surface).
	metricsMux := http.NewServeMux()
	metricsMux.Handle("/metrics", promhttp.Handler())
	metricsSrv := &http.Server{Addr: ":9090", Handler: metricsMux}

	go func() {
		logger.InfoContext(ctx, "starting api server", "addr", apiSrv.Addr)
		if err := apiSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.ErrorContext(ctx, "api server error", "err", err)
			os.Exit(1)
		}
	}()

	go func() {
		logger.InfoContext(ctx, "starting metrics server", "addr", metricsSrv.Addr)
		if err := metricsSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.ErrorContext(ctx, "metrics server error", "err", err)
		}
	}()

	// Block until SIGTERM (K8s) or SIGINT (Ctrl-C) arrives.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	sig := <-stop
	logger.InfoContext(ctx, "received signal — draining", "signal", sig.String())

	// 30s drain budget — well inside the K8s terminationGracePeriodSeconds
	// (60s default per the StatefulSet template), leaving 30s headroom for
	// fsync + span flush + a real LevelDB Close() in production.
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := apiSrv.Shutdown(shutdownCtx); err != nil {
		logger.ErrorContext(shutdownCtx, "api graceful shutdown error", "err", err)
	}
	if err := metricsSrv.Shutdown(shutdownCtx); err != nil {
		logger.ErrorContext(shutdownCtx, "metrics graceful shutdown error", "err", err)
	}
	if err := shutdownTracing(shutdownCtx); err != nil {
		logger.ErrorContext(shutdownCtx, "tracing shutdown error", "err", err)
	}
	if err := fsyncDir(defaultDataDir); err != nil {
		logger.ErrorContext(shutdownCtx, "fsync /data error", "err", err)
	}

	logger.InfoContext(ctx, "clean shutdown complete")
}
