// Package dashboard serves an opt-in single-page stats dashboard for godot-mcp.
// It holds one persistent WebSocket connection to the editor addon, polls
// stats.snapshot into a cache, and serves an htmx page (assets embedded) that
// polls HTML fragments. All activity (CLI + serve + any client) is captured
// because the addon's command_router records every call.
package dashboard

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/bynine/godot-mcp-go/internal/protocol"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

//go:embed assets
var assetsFS embed.FS

const pollInterval = 1500 * time.Millisecond

type Call struct {
	Ts     int64  `json:"ts"`
	Method string `json:"method"`
	OK     bool   `json:"ok"`
	Ms     int    `json:"ms"`
	Params string `json:"params"`
}

type Snapshot struct {
	UptimeMs          int64          `json:"uptime_ms"`
	TotalCalls        int            `json:"total_calls"`
	Errors            int            `json:"errors"`
	ActiveConnections int            `json:"active_connections"`
	TotalConnections  int            `json:"total_connections"`
	CommandCount      int            `json:"command_count"`
	Playing           bool           `json:"playing"`
	ByGroup           map[string]int `json:"by_group"`
	ByMethod          map[string]int `json:"by_method"`
	Recent            []Call         `json:"recent"`
}

type server struct {
	resolveAddonPort func() int
	tmpl             *template.Template
	mu               sync.RWMutex
	snap             Snapshot
	connected        bool
	lastErr          string
}

// Run starts the dashboard HTTP server (blocking) on httpPort, polling the addon
// whose port is resolved fresh on each (re)connect via resolveAddonPort.
func Run(httpPort int, resolveAddonPort func() int) error {
	tmpl, err := template.New("frag").Funcs(funcs).ParseFS(assetsFS, "assets/fragments.tmpl")
	if err != nil {
		return err
	}
	staticFS, _ := fs.Sub(assetsFS, "assets")
	s := &server{resolveAddonPort: resolveAddonPort, tmpl: tmpl}

	go s.poll(context.Background())

	mux := http.NewServeMux()
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/fragment/overview", s.handleOverview)
	mux.HandleFunc("/fragment/feed", s.handleFeed)

	addr := fmt.Sprintf("127.0.0.1:%d", httpPort)
	fmt.Fprintf(os.Stderr, "godot-mcp dashboard → http://%s\n", addr)
	return http.ListenAndServe(addr, mux)
}

// --- Addon poller (one persistent connection) -------------------------------

func (s *server) poll(ctx context.Context) {
	for ctx.Err() == nil {
		s.pollSession(ctx)
		select {
		case <-time.After(2 * time.Second): // back off before reconnecting
		case <-ctx.Done():
			return
		}
	}
}

func (s *server) pollSession(ctx context.Context) {
	url := fmt.Sprintf("ws://127.0.0.1:%d", s.resolveAddonPort())
	dctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	conn, _, err := websocket.Dial(dctx, url, nil)
	cancel()
	if err != nil {
		s.setErr("editor not reachable")
		return
	}
	defer conn.Close(websocket.StatusNormalClosure, "")
	conn.SetReadLimit(8 << 20) // 8MB — well above a capped stats snapshot

	id := 0
	for ctx.Err() == nil {
		id++
		cctx, c := context.WithTimeout(ctx, 5*time.Second)
		writeErr := wsjson.Write(cctx, conn, protocol.NewRequest(id, "stats.snapshot", nil))
		var resp protocol.Response
		readErr := writeErr
		if writeErr == nil {
			readErr = wsjson.Read(cctx, conn, &resp)
		}
		c()
		if writeErr != nil || readErr != nil {
			s.setErr("connection lost")
			return
		}
		if resp.Error == nil {
			var snap Snapshot
			if json.Unmarshal(resp.Result, &snap) == nil {
				s.set(snap)
			}
		}
		select {
		case <-time.After(pollInterval):
		case <-ctx.Done():
			return
		}
	}
}

func (s *server) set(snap Snapshot) {
	s.mu.Lock()
	s.snap, s.connected, s.lastErr = snap, true, ""
	s.mu.Unlock()
}

func (s *server) setErr(msg string) {
	s.mu.Lock()
	s.connected, s.lastErr = false, msg
	s.mu.Unlock()
}

func (s *server) read() (Snapshot, bool, string) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snap, s.connected, s.lastErr
}

// --- HTTP handlers ----------------------------------------------------------

func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	b, err := assetsFS.ReadFile("assets/index.html")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(b)
}

type kv struct {
	Key string
	Val int
	Pct int
}

type overviewVM struct {
	Snapshot
	Connected      bool
	LastErr        string
	Uptime         string
	ErrRate        int
	Groups         []kv   // by-group counts, sorted desc, capped to the top 8
	RecentErrors   []Call // latest failed calls, newest first, max 5
	RecentErrCount int    // failed calls within the recent window
	LatestErr      *Call  // newest failed call (drives the banner), nil when none
	Buckets        []int  // 10 per-minute bars as height % (idx 0 oldest .. idx 9 now)
	CadenceEmpty   bool   // no calls in the last 10 min (or offline): render the flat state
}

func (s *server) handleOverview(w http.ResponseWriter, r *http.Request) {
	snap, conn, lerr := s.read()
	vm := overviewVM{
		Snapshot:  snap,
		Connected: conn,
		LastErr:   lerr,
		Uptime:    humanDur(snap.UptimeMs),
		Groups:    topKV(sortedKV(snap.ByGroup), 8),
	}
	if snap.TotalCalls > 0 {
		vm.ErrRate = snap.Errors * 100 / snap.TotalCalls
	}
	vm.RecentErrors, vm.RecentErrCount, vm.LatestErr = recentErrors(snap.Recent, 5)
	vm.Buckets, vm.CadenceEmpty = cadenceBuckets(snap.Recent, time.Now())
	if !conn {
		vm.CadenceEmpty = true // no live cadence to plot when the editor is unreachable
	}
	s.render(w, "overview", vm)
}

type feedRow struct {
	Call
	GapMin int // >0 → render a "gap" separator before this row (minutes since the newer row)
}

type feedVM struct {
	Rows      []feedRow
	Connected bool
	Total     int  // rows in the recent window
	ErrCount  int  // failed rows in the window
	Groups    []kv // top-4 groups within the window (filter chips)
}

func (s *server) handleFeed(w http.ResponseWriter, r *http.Request) {
	snap, conn, _ := s.read()
	s.render(w, "feed", buildFeedVM(snap, conn))
}

// buildFeedVM enriches the newest-first recent window with per-row gap markers
// and computes the filter-chip counts (ALL / ERR / top-4 groups) over the window.
func buildFeedVM(snap Snapshot, conn bool) feedVM {
	vm := feedVM{Connected: conn, Total: len(snap.Recent)}
	counts := make(map[string]int, 8)
	rows := make([]feedRow, 0, len(snap.Recent))
	for i, c := range snap.Recent {
		if !c.OK {
			vm.ErrCount++
		}
		counts[groupOf(c.Method)]++
		row := feedRow{Call: c}
		if i > 0 { // Recent is newest-first; row i-1 is the newer neighbour
			if gap := snap.Recent[i-1].Ts - c.Ts; gap > 5*60*1000 {
				row.GapMin = int(gap / 60000)
			}
		}
		rows = append(rows, row)
	}
	vm.Rows = rows
	vm.Groups = topKV(sortedKV(counts), 4)
	return vm
}

func (s *server) render(w http.ResponseWriter, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := s.tmpl.ExecuteTemplate(w, name, data); err != nil {
		http.Error(w, err.Error(), 500)
	}
}

func sortedKV(m map[string]int) []kv {
	out := make([]kv, 0, len(m))
	max := 0
	for k, v := range m {
		out = append(out, kv{Key: k, Val: v})
		if v > max {
			max = v
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Val != out[j].Val {
			return out[i].Val > out[j].Val
		}
		return out[i].Key < out[j].Key
	})
	if max > 0 {
		for i := range out {
			out[i].Pct = out[i].Val * 100 / max
		}
	}
	return out
}

func topKV(in []kv, n int) []kv {
	if len(in) > n {
		return in[:n]
	}
	return in
}

// recentErrors walks the newest-first window and returns up to limit failed
// calls (newest first), the total failed count, and the newest failure (banner).
func recentErrors(recent []Call, limit int) (list []Call, count int, latest *Call) {
	for i := range recent {
		if recent[i].OK {
			continue
		}
		count++
		if latest == nil {
			c := recent[i]
			latest = &c
		}
		if len(list) < limit {
			list = append(list, recent[i])
		}
	}
	return
}

// cadenceBuckets bins recent-call timestamps into 10 one-minute buckets over the
// last 10 minutes and scales each to a 0-100 height percentage of the busiest
// bucket. Index 0 is the oldest minute, index 9 the current one. empty is true
// when no call lands in the window, so the chart renders its flat "none" state.
func cadenceBuckets(recent []Call, now time.Time) (pcts []int, empty bool) {
	counts := make([]int, 10)
	nowMs := now.UnixMilli()
	for _, c := range recent {
		age := nowMs - c.Ts
		if age < 0 {
			age = 0
		}
		mins := int(age / 60000)
		if mins > 9 {
			continue
		}
		counts[9-mins]++
	}
	peak := 0
	for _, v := range counts {
		if v > peak {
			peak = v
		}
	}
	if peak == 0 {
		return make([]int, 10), true
	}
	out := make([]int, 10)
	for i, v := range counts {
		out[i] = v * 100 / peak
	}
	return out, false
}

// groupOf returns the command group (the segment before the first dot).
func groupOf(method string) string {
	if i := strings.IndexByte(method, '.'); i >= 0 {
		return method[:i]
	}
	return method
}

var funcs = template.FuncMap{
	"timeAgo": func(ts int64) string {
		d := time.Since(time.UnixMilli(ts))
		switch {
		case d < time.Second:
			return "just now"
		case d < time.Minute:
			return fmt.Sprintf("%ds ago", int(d.Seconds()))
		case d < time.Hour:
			return fmt.Sprintf("%dm ago", int(d.Minutes()))
		default:
			return fmt.Sprintf("%dh ago", int(d.Hours()))
		}
	},
	// clock renders a millisecond Unix timestamp as HH:MM:SS (local time).
	"clock": func(ts int64) string {
		return time.UnixMilli(ts).Format("15:04:05")
	},
	// dur formats a millisecond duration as "12ms" or "3.6s".
	"dur": func(ms int) string {
		if ms < 1000 {
			return fmt.Sprintf("%dms", ms)
		}
		return fmt.Sprintf("%.1fs", float64(ms)/1000)
	},
	// trunc clips s to n runes, appending an ellipsis when it overflows.
	"trunc": func(n int, s string) string {
		r := []rune(s)
		if len(r) <= n {
			return s
		}
		return string(r[:n]) + "…"
	},
	"group": groupOf,
}

func humanDur(ms int64) string {
	d := time.Duration(ms) * time.Millisecond
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm %ds", int(d.Minutes()), int(d.Seconds())%60)
	default:
		return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
	}
}
