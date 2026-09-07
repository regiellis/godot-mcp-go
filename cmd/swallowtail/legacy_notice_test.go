package main

import "testing"

func TestLegacyNoticeProtectsStructuredOutput(t *testing.T) {
	t.Setenv("SWALLOWTAIL_FORMAT", "")
	t.Setenv("GODOT_MCP_FORMAT", "")
	for _, args := range [][]string{{"serve"}, {"completion", "bash"}, {"__complete"}, {"--errors", "json", "scene", "tre"}, {"--errors=json"}, {"--format", "ndjson"}, {"--format=json"}, {"--json"}} {
		if legacyNoticeAllowed(args) {
			t.Errorf("notice would contaminate %q", args)
		}
	}
	if !legacyNoticeAllowed([]string{"project", "info"}) {
		t.Fatal("interactive command should explain deprecation")
	}
	t.Setenv("SWALLOWTAIL_FORMAT", "json")
	if legacyNoticeAllowed([]string{"project", "info"}) {
		t.Fatal("environment-selected structured output must suppress notice")
	}
}
