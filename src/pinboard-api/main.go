// Pinboard API — the tiny service that threads through the whole course.
//
// It is deliberately small and dependency-light so that students never have to
// read Go to follow the labs. Everything is configured through environment
// variables (12-factor style):
//
//	PORT             listen port                         (default 8080)
//	DATABASE_URL     postgres://user:pass@host:5432/db   (empty → in-memory store)
//	APP_VERSION      shown in /api/info and the banner   (default "dev")
//	APP_THEME        emerald | amber | rose | sky        (default "emerald")
//	APP_GREETING     text shown by the web UI header     (default "Welcome to Pinboard")
//	LOG_FORMAT       text | json                         (default text)
//	SHUTDOWN_GRACE   graceful shutdown timeout           (default 10s)
//	FAIL_READY_AFTER seconds after start when /readyz starts failing (0 = never)
//	CRASH_ON_START   "true" → exit(1) immediately (rollback demos)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ---------- store -----------------------------------------------------------

type Note struct {
	ID        int64     `json:"id"`
	Text      string    `json:"text"`
	Author    string    `json:"author,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
}

type Store interface {
	Name() string
	Ping(ctx context.Context) error
	List(ctx context.Context) ([]Note, error)
	Add(ctx context.Context, text, author string) (Note, error)
	Delete(ctx context.Context, id int64) error
	Close()
}

// memoryStore is used when DATABASE_URL is empty. Data lives and dies with the
// process — exactly the point we want to make in the storage sessions.
type memoryStore struct {
	mu    sync.Mutex
	next  int64
	notes []Note
}

func newMemoryStore() *memoryStore                { return &memoryStore{next: 1} }
func (m *memoryStore) Name() string               { return "memory" }
func (m *memoryStore) Ping(context.Context) error { return nil }
func (m *memoryStore) Close()                     {}
func (m *memoryStore) List(context.Context) ([]Note, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Note, len(m.notes))
	copy(out, m.notes)
	return out, nil
}
func (m *memoryStore) Add(_ context.Context, text, author string) (Note, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	n := Note{ID: m.next, Text: text, Author: author, CreatedAt: time.Now().UTC()}
	m.next++
	m.notes = append([]Note{n}, m.notes...)
	return n, nil
}
func (m *memoryStore) Delete(_ context.Context, id int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i, n := range m.notes {
		if n.ID == id {
			m.notes = append(m.notes[:i], m.notes[i+1:]...)
			return nil
		}
	}
	return errNotFound
}

var errNotFound = errors.New("not found")

// defaultVersion can be overridden at build time:
//
//	go build -ldflags="-X main.defaultVersion=1.0"
//
// APP_VERSION at runtime still wins.
var defaultVersion = "dev"

// pgStore is used when DATABASE_URL is set.
type pgStore struct{ pool *pgxpool.Pool }

func newPGStore(ctx context.Context, url string) (*pgStore, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, err
	}
	// Retry the first connection: in Compose/Kubernetes the DB may still be starting.
	var lastErr error
	for i := 0; i < 30; i++ {
		if lastErr = pool.Ping(ctx); lastErr == nil {
			break
		}
		slog.Warn("database not ready, retrying", "attempt", i+1, "err", lastErr)
		time.Sleep(2 * time.Second)
	}
	if lastErr != nil {
		return nil, lastErr
	}
	_, err = pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS notes (
		id BIGSERIAL PRIMARY KEY,
		text TEXT NOT NULL,
		author TEXT NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT now())`)
	if err != nil {
		return nil, err
	}
	return &pgStore{pool: pool}, nil
}
func (p *pgStore) Name() string                   { return "postgres" }
func (p *pgStore) Ping(ctx context.Context) error { return p.pool.Ping(ctx) }
func (p *pgStore) Close()                         { p.pool.Close() }
func (p *pgStore) List(ctx context.Context) ([]Note, error) {
	rows, err := p.pool.Query(ctx, `SELECT id, text, author, created_at FROM notes ORDER BY id DESC LIMIT 200`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	notes := []Note{}
	for rows.Next() {
		var n Note
		if err := rows.Scan(&n.ID, &n.Text, &n.Author, &n.CreatedAt); err != nil {
			return nil, err
		}
		notes = append(notes, n)
	}
	return notes, rows.Err()
}
func (p *pgStore) Add(ctx context.Context, text, author string) (Note, error) {
	var n Note
	err := p.pool.QueryRow(ctx,
		`INSERT INTO notes (text, author) VALUES ($1, $2) RETURNING id, text, author, created_at`,
		text, author).Scan(&n.ID, &n.Text, &n.Author, &n.CreatedAt)
	return n, err
}
func (p *pgStore) Delete(ctx context.Context, id int64) error {
	tag, err := p.pool.Exec(ctx, `DELETE FROM notes WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	return nil
}

// ---------- app -------------------------------------------------------------

type app struct {
	store     Store
	version   string
	theme     string
	greeting  string
	hostname  string
	started   time.Time
	failAfter time.Duration
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", a.banner)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", a.ready)
	mux.HandleFunc("GET /api/info", a.info)
	mux.HandleFunc("GET /api/notes", a.listNotes)
	mux.HandleFunc("POST /api/notes", a.addNote)
	mux.HandleFunc("DELETE /api/notes/{id}", a.deleteNote)
	mux.HandleFunc("GET /api/burn", a.burn)
	return logging(mux)
}

func (a *app) banner(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte("Pinboard API " + a.version + " on " + a.hostname + " (store: " + a.store.Name() + ")\n"))
}

func (a *app) ready(w http.ResponseWriter, r *http.Request) {
	if a.failAfter > 0 && time.Since(a.started) > a.failAfter {
		http.Error(w, "not ready: FAIL_READY_AFTER elapsed", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := a.store.Ping(ctx); err != nil {
		http.Error(w, "not ready: "+err.Error(), http.StatusServiceUnavailable)
		return
	}
	w.Write([]byte("ready\n"))
}

func (a *app) info(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{
		"app":      "pinboard-api",
		"version":  a.version,
		"hostname": a.hostname,
		"store":    a.store.Name(),
		"theme":    a.theme,
		"greeting": a.greeting,
		"uptime":   time.Since(a.started).Round(time.Second).String(),
	})
}

func (a *app) listNotes(w http.ResponseWriter, r *http.Request) {
	notes, err := a.store.List(r.Context())
	if err != nil {
		slog.Error("list notes", "err", err)
		writeJSON(w, 503, map[string]string{"error": "store unavailable"})
		return
	}
	writeJSON(w, 200, notes)
}

func (a *app) addNote(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Text   string `json:"text"`
		Author string `json:"author"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&in); err != nil || strings.TrimSpace(in.Text) == "" {
		writeJSON(w, 400, map[string]string{"error": "body must be JSON with a non-empty \"text\""})
		return
	}
	if in.Author == "" {
		in.Author = "anonymous"
	}
	n, err := a.store.Add(r.Context(), strings.TrimSpace(in.Text), in.Author)
	if err != nil {
		slog.Error("add note", "err", err)
		writeJSON(w, 503, map[string]string{"error": "store unavailable"})
		return
	}
	writeJSON(w, 201, n)
}

func (a *app) deleteNote(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeJSON(w, 400, map[string]string{"error": "invalid id"})
		return
	}
	switch err := a.store.Delete(r.Context(), id); {
	case errors.Is(err, errNotFound):
		writeJSON(w, 404, map[string]string{"error": "not found"})
	case err != nil:
		writeJSON(w, 503, map[string]string{"error": "store unavailable"})
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// burn keeps one CPU busy for ?ms= milliseconds (default 200, max 5000).
// Used by the HPA lab: a load generator calls it in a loop.
func (a *app) burn(w http.ResponseWriter, r *http.Request) {
	ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
	if ms <= 0 {
		ms = 200
	}
	if ms > 5000 {
		ms = 5000
	}
	deadline := time.Now().Add(time.Duration(ms) * time.Millisecond)
	x := 0.0001
	for time.Now().Before(deadline) {
		x = x*1.0000001 + 0.0000001
	}
	writeJSON(w, 200, map[string]any{"burnedMs": ms, "hostname": a.hostname})
}

func logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(rw, r)
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			return // keep probe noise out of the logs
		}
		slog.Info("request", "method", r.Method, "path", r.URL.Path, "status", rw.status,
			"duration", time.Since(start).Round(time.Microsecond).String())
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (s *statusWriter) WriteHeader(code int) { s.status = code; s.ResponseWriter.WriteHeader(code) }

// ---------- main ------------------------------------------------------------

func main() {
	if env("LOG_FORMAT", "text") == "json" {
		slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	} else {
		slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, nil)))
	}

	if env("CRASH_ON_START", "false") == "true" {
		slog.Error("CRASH_ON_START is set — exiting with status 1 (this is on purpose)")
		os.Exit(1)
	}

	hostname, _ := os.Hostname()
	a := &app{
		version:  env("APP_VERSION", defaultVersion),
		theme:    env("APP_THEME", "emerald"),
		greeting: env("APP_GREETING", "Welcome to Pinboard"),
		hostname: hostname,
		started:  time.Now(),
	}
	if s := env("FAIL_READY_AFTER", ""); s != "" {
		secs, _ := strconv.Atoi(s)
		a.failAfter = time.Duration(secs) * time.Second
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if url := os.Getenv("DATABASE_URL"); url != "" {
		st, err := newPGStore(ctx, url)
		if err != nil {
			slog.Error("cannot connect to database", "err", err)
			os.Exit(1)
		}
		a.store = st
	} else {
		a.store = newMemoryStore()
		slog.Warn("DATABASE_URL not set — using in-memory store, notes will be lost on restart")
	}
	defer a.store.Close()

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		slog.Info("pinboard-api starting", "version", a.version, "theme", a.theme,
			"store", a.store.Name(), "addr", srv.Addr, "hostname", hostname)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server error", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done() // SIGTERM / SIGINT received
	grace, err := time.ParseDuration(env("SHUTDOWN_GRACE", "10s"))
	if err != nil {
		grace = 10 * time.Second
	}
	slog.Info("signal received, shutting down gracefully", "grace", grace.String())
	shutdownCtx, cancel := context.WithTimeout(context.Background(), grace)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("forced shutdown", "err", err)
	}
	slog.Info("bye")
}
