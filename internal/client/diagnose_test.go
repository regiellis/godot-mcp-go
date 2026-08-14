package client

import "testing"

func TestClassify(t *testing.T) {
	disc := &Discovery{Port: 9081, PID: 4242, StartedUnix: 1000}

	// classify reports the port it was handed. Diagnose resolves the port once
	// (flag > env > discovery > default) before probing, so the probed port and the
	// reported port never diverge. Passing 9080 alongside a disc on 9081 models a
	// flag/env-pinned port: the verdict must name 9080, the port actually probed.
	cases := []struct {
		name      string
		disc      *Discovery
		reachable bool
		alive     bool
		want      Verdict
		wantPort  int
	}{
		{"running with file", disc, true, true, VerdictRunning, 9080},
		{"running without file", nil, true, false, VerdictRunning, 9080},
		{"closed: no file, unreachable", nil, false, false, VerdictClosed, 9080},
		{"starting: file, alive, unreachable", disc, false, true, VerdictStarting, 9080},
		{"crashed: file, dead, unreachable", disc, false, false, VerdictCrashed, 9080},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := classify(c.disc, 9080, c.reachable, c.alive)
			if got.Verdict != c.want {
				t.Errorf("verdict = %q, want %q", got.Verdict, c.want)
			}
			if got.Reachable != c.reachable {
				t.Errorf("reachable = %v, want %v", got.Reachable, c.reachable)
			}
			if got.Port != c.wantPort {
				t.Errorf("port = %d, want %d", got.Port, c.wantPort)
			}
		})
	}
}

func TestMismatchVerdict(t *testing.T) {
	// An editor answered, serving another project. This project therefore has
	// none, and the verdict has to say so: "starting" would tell the agent to wait
	// for an editor that is never coming, while the same result's action says to
	// open one. A live pid is not evidence of an editor for THIS project.
	disc := &Discovery{Port: 9081, PID: 4242, StartedUnix: 1000}
	cases := []struct {
		name  string
		disc  *Discovery
		alive bool
		want  Verdict
	}{
		{"no discovery file", nil, false, VerdictClosed},
		{"file, pid alive", disc, true, VerdictClosed},
		{"file, pid gone", disc, false, VerdictCrashed},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := mismatchVerdict(c.disc, 9080, c.alive)
			if got.Verdict != c.want {
				t.Errorf("verdict = %q, want %q", got.Verdict, c.want)
			}
			if got.Reachable {
				t.Error("reachable = true; nothing is serving this project")
			}
			if got.Port != 9080 {
				t.Errorf("port = %d, want 9080", got.Port)
			}
			if c.disc != nil && got.PID != c.disc.PID {
				t.Errorf("pid = %d, want %d from the discovery file", got.PID, c.disc.PID)
			}
		})
	}
}
