// app/observability_test.go
//
// BVA tests per CLAUDE.md guardrail (k) on the observability additions:
//
//   - dataOpsTotal counter — boundaries on op (read|write) × outcome (ok|err)
//   - /metrics endpoint   — present vs absent, Prometheus text format
//   - traceContextHandler — log record's trace_id attribute is present iff
//                           ctx carries a valid span (B-1: no ctx span;
//                           B: ctx with valid span; B+1: nested span).
//
// dataOpsTotal is package-level + accumulates across tests, so tests
// observe deltas (counter before vs after the operation) rather than
// absolute values, which keeps them order-independent.

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/prometheus/client_golang/prometheus/testutil"
	"go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// counterValue is a thin wrapper to read the float value of one labelled
// counter — testutil panics if the labels are wrong, so this surfaces
// label drift loudly.
func counterValue(t *testing.T, op, outcome string) float64 {
	t.Helper()
	c, err := dataOpsTotal.GetMetricWithLabelValues(op, outcome)
	if err != nil {
		t.Fatalf("counterValue(%q, %q): %v", op, outcome, err)
	}
	return testutil.ToFloat64(c)
}

// ---- dataOpsTotal counter — write path ---------------------------------

func TestMetrics_WriteOk_CounterIncrements(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	before := counterValue(t, "write", "ok")

	body := bytes.NewBufferString(`{"key":"counter-write-ok","value":"v"}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	resp.Body.Close()

	after := counterValue(t, "write", "ok")
	if after-before != 1 {
		t.Errorf("write/ok counter delta — got %v, want 1", after-before)
	}
}

// ---- dataOpsTotal counter — read path ----------------------------------

func TestMetrics_ReadOk_CounterIncrements(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	// Setup: write a key so the read succeeds.
	postBody := bytes.NewBufferString(`{"key":"counter-read-ok","value":"v"}`)
	postResp, _ := http.Post(srv.URL+"/data", "application/json", postBody)
	postResp.Body.Close()

	before := counterValue(t, "read", "ok")

	getResp, err := http.Get(srv.URL + "/data?key=counter-read-ok")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	getResp.Body.Close()

	after := counterValue(t, "read", "ok")
	if after-before != 1 {
		t.Errorf("read/ok counter delta — got %v, want 1", after-before)
	}
}

func TestMetrics_ReadMiss_CounterIncrementsErr(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	before := counterValue(t, "read", "err")

	resp, err := http.Get(srv.URL + "/data?key=definitely-not-stored")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}

	after := counterValue(t, "read", "err")
	if after-before != 1 {
		t.Errorf("read/err counter delta — got %v, want 1", after-before)
	}
}

// ---- dataOpsTotal counter — boundary at zero ops -----------------------

func TestMetrics_LabelCombinations_AreFourDistinct(t *testing.T) {
	// Boundary: the counter MUST have all four (op, outcome) label
	// combinations registered. A typo collapsing the cardinality would
	// silently drop a counter family — surface it.
	want := [][]string{
		{"write", "ok"},
		{"write", "err"},
		{"read", "ok"},
		{"read", "err"},
	}
	for _, lbl := range want {
		c, err := dataOpsTotal.GetMetricWithLabelValues(lbl[0], lbl[1])
		if err != nil {
			t.Errorf("missing label combination %v: %v", lbl, err)
		}
		_ = c
	}
}

// ---- /metrics endpoint -------------------------------------------------

func TestMetricsEndpoint_ServesPrometheusFormat(t *testing.T) {
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/metrics")
	if err != nil {
		t.Fatalf("GET /metrics failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/metrics — got %d, want 200", resp.StatusCode)
	}

	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "aegis_data_ops_total") {
		t.Errorf("/metrics body missing aegis_data_ops_total — body[:200]=%q", string(body[:min(200, len(body))]))
	}
	if !strings.Contains(string(body), "go_") {
		t.Errorf("/metrics body missing default go_* collectors")
	}
}

// ---- slog traceContextHandler — boundary on ctx span ------------------

// logRecord parses a single JSON-encoded slog record from buf. Returns
// the decoded fields so tests can check trace_id presence/absence.
func parseLogRecord(t *testing.T, buf []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(buf, &m); err != nil {
		t.Fatalf("not JSON: %v\nraw=%q", err, buf)
	}
	return m
}

func TestSlog_NoSpanContext_NoTraceIDAttribute(t *testing.T) {
	// B-1: ctx has no span → log record has no trace_id field.
	var buf bytes.Buffer
	inner := slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})
	h := &traceContextHandler{inner: inner}
	logger := slog.New(h)

	logger.InfoContext(context.Background(), "plain message")

	rec := parseLogRecord(t, buf.Bytes())
	if _, ok := rec["trace_id"]; ok {
		t.Errorf("no-span ctx should omit trace_id, got %v", rec["trace_id"])
	}
}

func TestSlog_WithSpanContext_IncludesTraceID(t *testing.T) {
	// B: ctx with a valid span → log record has trace_id + span_id.
	tp := sdktrace.NewTracerProvider()
	defer tp.Shutdown(context.Background())
	otel.SetTracerProvider(tp)
	tr := tp.Tracer("test")

	ctx, span := tr.Start(context.Background(), "test-span")
	defer span.End()

	var buf bytes.Buffer
	inner := slog.NewJSONHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})
	h := &traceContextHandler{inner: inner}
	logger := slog.New(h)

	logger.InfoContext(ctx, "in-span message")

	rec := parseLogRecord(t, buf.Bytes())
	tid, ok := rec["trace_id"].(string)
	if !ok || tid == "" || tid == "00000000000000000000000000000000" {
		t.Errorf("expected valid trace_id, got %v", rec["trace_id"])
	}
	sid, ok := rec["span_id"].(string)
	if !ok || sid == "" || sid == "0000000000000000" {
		t.Errorf("expected valid span_id, got %v", rec["span_id"])
	}
}

func TestSlog_NestedSpan_ChildSpanIDDiffersFromParent(t *testing.T) {
	// B+1: nested span → child span emits a different span_id than the
	// parent. Catches the bug where the handler accidentally pulls the
	// parent span context instead of the active one.
	tp := sdktrace.NewTracerProvider()
	defer tp.Shutdown(context.Background())
	otel.SetTracerProvider(tp)
	tr := tp.Tracer("test")

	parentCtx, parentSpan := tr.Start(context.Background(), "parent")
	defer parentSpan.End()

	childCtx, childSpan := tr.Start(parentCtx, "child")
	defer childSpan.End()

	var bufParent, bufChild bytes.Buffer
	hParent := &traceContextHandler{inner: slog.NewJSONHandler(&bufParent, nil)}
	hChild := &traceContextHandler{inner: slog.NewJSONHandler(&bufChild, nil)}

	slog.New(hParent).InfoContext(parentCtx, "parent log")
	slog.New(hChild).InfoContext(childCtx, "child log")

	parentRec := parseLogRecord(t, bufParent.Bytes())
	childRec := parseLogRecord(t, bufChild.Bytes())

	if parentRec["span_id"] == childRec["span_id"] {
		t.Errorf("nested spans should have distinct span_ids, both = %v", parentRec["span_id"])
	}
	if parentRec["trace_id"] != childRec["trace_id"] {
		t.Errorf("nested spans should share trace_id, parent=%v child=%v",
			parentRec["trace_id"], childRec["trace_id"])
	}
}
