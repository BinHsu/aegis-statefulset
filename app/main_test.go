// app/main_test.go
//
// Boundary-value tests for the POC mock app, per CLAUDE.md guardrail (k):
// every input domain with a meaningful boundary B is exercised at B-1, B,
// and B+1. The mock's input boundaries are:
//
//   - Key length  (empty = 0 chars vs single char vs 128-char max vs 129)
//   - Key safety  (valid path element vs traversal / separator / leading dot)
//   - Value size  (empty body vs single byte vs large value)
//   - HTTP method (POST/GET supported, others 405)
//   - Endpoint    (/data vs /healthz vs unknown)
//   - Round-trip  (state survives between POST and GET)
//
// Run:
//   cd app && go test -v ./...

package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// helper — build a fresh handler over a temp data directory so each test
// has an isolated filesystem.
func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	tempDir := t.TempDir()
	return httptest.NewServer(routes(tempDir))
}

// ---- POST /data — key boundaries -----------------------------------------

func TestPost_KeyEmpty_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{"key":"","value":"v"}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("empty key — got %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

func TestPost_KeySingleChar_Returns204(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{"key":"k","value":"v"}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("1-char key — got %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
}

func TestPost_KeyMaxLength_Returns204(t *testing.T) {
	// 128 chars — the maximum keyPattern admits (boundary B). B-1 and B+1
	// are covered at the unit level by TestValidKey; this is the B point
	// exercised end-to-end through the handler.
	srv := newTestServer(t)
	defer srv.Close()

	maxKey := strings.Repeat("k", 128)
	body := bytes.NewBufferString(`{"key":"` + maxKey + `","value":"v"}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("128-char key — got %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
}

func TestPost_KeyTooLong_Returns400(t *testing.T) {
	// 129 chars — one past the keyPattern maximum (boundary B+1).
	srv := newTestServer(t)
	defer srv.Close()

	tooLong := strings.Repeat("k", 129)
	body := bytes.NewBufferString(`{"key":"` + tooLong + `","value":"v"}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("129-char key — got %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

// ---- POST /data — value boundaries ---------------------------------------

func TestPost_ValueEmpty_Returns204(t *testing.T) {
	// Empty value is valid — represents an existence flag rather than data.
	srv := newTestServer(t)
	defer srv.Close()

	body := bytes.NewBufferString(`{"key":"k","value":""}`)
	resp, err := http.Post(srv.URL+"/data", "application/json", body)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("empty value — got %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
}

func TestPost_ValueLarge_Returns204(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	largeValue := strings.Repeat("x", 1024*64) // 64 KB — comfortably below default Go server limits
	payload, _ := json.Marshal(map[string]string{"key": "big", "value": largeValue})
	resp, err := http.Post(srv.URL+"/data", "application/json", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("64KB value — got %d, want %d", resp.StatusCode, http.StatusNoContent)
	}
}

// ---- POST /data — malformed input ----------------------------------------

func TestPost_InvalidJSON_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Post(srv.URL+"/data", "application/json", bytes.NewBufferString("not json"))
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("invalid JSON — got %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

// ---- GET /data — key parameter boundaries --------------------------------

func TestGet_KeyParamMissing_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/data") // no ?key=
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("missing ?key — got %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

func TestGet_KeyParamEmpty_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/data?key=")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("?key= empty — got %d, want %d", resp.StatusCode, http.StatusBadRequest)
	}
}

func TestGet_KeyMissing_Returns404(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/data?key=does-not-exist")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("non-existent key — got %d, want %d", resp.StatusCode, http.StatusNotFound)
	}
}

// ---- POST → GET round-trip -----------------------------------------------

func TestRoundTrip_PostThenGet_ReturnsValue(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	postBody := bytes.NewBufferString(`{"key":"k","value":"v"}`)
	postResp, err := http.Post(srv.URL+"/data", "application/json", postBody)
	if err != nil {
		t.Fatalf("POST failed: %v", err)
	}
	postResp.Body.Close()
	if postResp.StatusCode != http.StatusNoContent {
		t.Fatalf("POST setup — got %d, want %d", postResp.StatusCode, http.StatusNoContent)
	}

	getResp, err := http.Get(srv.URL + "/data?key=k")
	if err != nil {
		t.Fatalf("GET failed: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Fatalf("GET — got %d, want %d", getResp.StatusCode, http.StatusOK)
	}

	buf := make([]byte, 1024)
	n, _ := getResp.Body.Read(buf)
	got := string(buf[:n])
	if got != "v" {
		t.Errorf("round-trip value — got %q, want %q", got, "v")
	}
}

// ---- HTTP method boundaries ----------------------------------------------

func TestMethod_PUT_Returns405(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodPut, srv.URL+"/data", bytes.NewBufferString(`{}`))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("PUT failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("PUT — got %d, want %d", resp.StatusCode, http.StatusMethodNotAllowed)
	}
}

func TestMethod_DELETE_Returns405(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodDelete, srv.URL+"/data", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("DELETE failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("DELETE — got %d, want %d", resp.StatusCode, http.StatusMethodNotAllowed)
	}
}

// ---- /healthz ------------------------------------------------------------

func TestHealthz_Returns200(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/healthz — got %d, want %d", resp.StatusCode, http.StatusOK)
	}
}

func TestReady_Returns200(t *testing.T) {
	// The helm chart's startup + readiness probes target /ready; the pod
	// never becomes Ready if this endpoint is missing.
	srv := newTestServer(t)
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/ready")
	if err != nil {
		t.Fatalf("GET /ready failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("/ready — got %d, want %d", resp.StatusCode, http.StatusOK)
	}
}

// ---- Path-traversal hardening (CodeQL go/path-injection) ----------------
//
// The key from the HTTP request is validated against keyPattern before it
// reaches filepath.Join — a key containing "..", a path separator, or a
// leading dot is rejected with 400 instead of escaping the data directory.
// TestValidKey gives the unit-level boundary coverage; the two tests below
// are the end-to-end POST/GET assertions through the handler.

// traversalKeys are keys that must never reach the filesystem — "/" makes
// a multi-component path, ".." / leading-dot are the traversal primitives.
var traversalKeys = []string{"../etc/passwd", "../../secret", "a/b", "..", ".", ".hidden"}

func TestPost_KeyPathTraversal_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	for _, key := range traversalKeys {
		payload, _ := json.Marshal(map[string]string{"key": key, "value": "v"})
		resp, err := http.Post(srv.URL+"/data", "application/json", bytes.NewReader(payload))
		if err != nil {
			t.Fatalf("POST %q failed: %v", key, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("traversal key %q — got %d, want %d", key, resp.StatusCode, http.StatusBadRequest)
		}
	}
}

func TestGet_KeyPathTraversal_Returns400(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()

	for _, key := range traversalKeys {
		resp, err := http.Get(srv.URL + "/data?key=" + url.QueryEscape(key))
		if err != nil {
			t.Fatalf("GET %q failed: %v", key, err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("traversal key %q — got %d, want %d", key, resp.StatusCode, http.StatusBadRequest)
		}
	}
}

// ---- validKey — unit boundary coverage ----------------------------------
//
// keyPattern admits 1..128 characters, alphanumeric-led, drawn from
// [A-Za-z0-9._-]. The length boundary is exercised at min (1) and max
// (128), each with its ±1 neighbour, per CLAUDE.md guardrail (k).

func TestValidKey(t *testing.T) {
	cases := []struct {
		name string
		key  string
		want bool
	}{
		{"empty — len 0, below min", "", false},
		{"single char — len 1, min", "k", true},
		{"len 2 — min+1", "ab", true},
		{"len 127 — max-1", strings.Repeat("k", 127), true},
		{"len 128 — max", strings.Repeat("k", 128), true},
		{"len 129 — max+1", strings.Repeat("k", 129), false},
		{"dot-dot", "..", false},
		{"single dot", ".", false},
		{"leading dot", ".hidden", false},
		{"forward slash", "a/b", false},
		{"backslash", `a\b`, false},
		{"traversal", "../../etc/passwd", false},
		{"dots in the middle — safe", "a..b", true},
		{"dashes, underscores, dots — safe", "my_key-1.v2", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := validKey(tc.key); got != tc.want {
				t.Errorf("validKey(%q) = %v, want %v", tc.key, got, tc.want)
			}
		})
	}
}
