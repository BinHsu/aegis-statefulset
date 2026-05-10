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
//   POST /data     {"key": "...", "value": "..."}   -> 204 / 4xx
//   GET  /data?key=...                              -> body / 404
//   GET  /healthz                                   -> 200 ok
//
// Storage: one file per key under <dataDir>/<key>. PV is mounted at /data.
//
// Graceful shutdown (per ADR-02 § Graceful shutdown):
//   On SIGTERM the server stops accepting new connections, drains in-flight
//   requests, fsyncs the data directory, then exits. The K8s
//   `terminationGracePeriodSeconds` (60s default) bounds the drain window;
//   inside it the app does http.Server.Shutdown(ctx) with a 30s deadline,
//   which is conservative for the POC's filesystem ops and headroom for
//   a real LevelDB Close() in production.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

const defaultDataDir = "/data"

// routes builds the HTTP mux. Exposed for tests; main() wires it to the
// default ServeMux on :8080.
func routes(dataDir string) *http.ServeMux {
	mux := http.NewServeMux()

	mux.HandleFunc("/data", func(w http.ResponseWriter, r *http.Request) {
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
			if err := os.WriteFile(filepath.Join(dataDir, body.Key), []byte(body.Value), 0o644); err != nil {
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
			data, err := os.ReadFile(filepath.Join(dataDir, key))
			if err != nil {
				http.NotFound(w, r)
				return
			}
			_, _ = io.WriteString(w, string(data))

		default:
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		}
	})

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	return mux
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
	if err := os.MkdirAll(defaultDataDir, 0o755); err != nil {
		log.Fatalf("Failed to create data directory: %v", err)
	}

	srv := &http.Server{
		Addr:    ":8080",
		Handler: routes(defaultDataDir),
	}

	go func() {
		log.Println("Starting aegis-stateful-mock on :8080")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server error: %v", err)
		}
	}()

	// Block until SIGTERM (K8s) or SIGINT (Ctrl-C) arrives.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	sig := <-stop
	log.Printf("received %v — draining", sig)

	// 30s drain budget — well inside the K8s terminationGracePeriodSeconds
	// (60s default per the StatefulSet template), leaving 30s headroom for
	// fsync + a real LevelDB Close() in production.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown error: %v", err)
	}

	if err := fsyncDir(defaultDataDir); err != nil {
		log.Printf("fsync /data error: %v", err)
	}

	log.Println("clean shutdown complete")
}
