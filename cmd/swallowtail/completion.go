package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/bynine/godot-mcp-go/internal/client"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

var localCompletionFlags = map[string][]string{
	"automate":       {"--file", "--project", "--port", "--timeout", "--dry-run", "--continue-on-error"},
	"create":         {"--enable", "--force", "--install", "--name", "--path"},
	"install":        {"--enable", "--force", "--from", "--project", "--skill", "--skill-from"},
	"migrate":        {"--project", "--apply", "--rollback", "--from"},
	"install-assets": {"--dest", "--force", "--from", "--list", "--pack", "--project"},
	"configure":      {"--config-dir", "--force", "--global", "--name", "--print", "--project"},
	"serve":          {"--port", "--project", "--timeout", "--typed"},
	"launch":         {"--godot", "--headless", "--json", "--project", "--timeout", "--wait"},
	"run":            {"--benchmark-file", "--debug-avoidance", "--debug-collisions", "--debug-navigation", "--debug-paths", "--disable-vsync", "--extra", "--fixed-fps", "--godot", "--gpu-profile", "--headless", "--json", "--max-fps", "--print-fps", "--project", "--resolution", "--time-scale", "--timeout", "--verbose", "--wait", "--windowed", "--write-movie"},
	"check":          {"--godot", "--jobs", "--json", "--project", "--timeout"},
	"test":           {"--godot", "--json", "--project", "--timeout"},
	"import":         {"--godot", "--json", "--project", "--timeout"},
	"export":         {"--debug", "--godot", "--json", "--out", "--pack", "--patch", "--patches", "--preset", "--project", "--timeout"},
	"upgrade":        {},
	"status":         {"--all", "--port", "--project"},
	"doctor":         {"--json", "--project"},
	"dashboard":      {"--addon-port", "--port", "--project"},
	"help":           {}, "version": {}, "completion": {},
}

var upgradeCompletionFlags = map[string][]string{
	"preflight": {"--godot", "--json", "--old-godot", "--project"},
	"baseline":  {"--frames", "--json", "--old-godot", "--project", "--scenario", "--timeout"},
	"open":      {"--godot", "--json", "--project", "--timeout"},
	"fix":       {"--category", "--dry-run", "--godot", "--json", "--project", "--scenario", "--timeout"},
	"verify":    {"--frames", "--godot", "--json", "--project", "--scenario", "--threshold", "--timeout"},
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func runCompletion(args []string) int {
	if len(args) != 1 || (args[0] != "bash" && args[0] != "powershell") {
		fmt.Fprintln(os.Stderr, "Usage: swallowtail completion bash|powershell\nSource the generated script in your shell profile.")
		return 2
	}
	if args[0] == "bash" {
		fmt.Print(bashCompletion)
	} else {
		fmt.Print(powerShellCompletion)
	}
	return 0
}

// Candidates are data, never shell code. Bound connection latency and filter
// addon-supplied identifiers before emitting them to the shell.
func runComplete(words []string) int {
	port := 0
	if f := flag.Lookup("port"); f != nil {
		port, _ = strconv.Atoi(f.Value.String())
	}
	for len(words) > 0 && strings.HasPrefix(words[0], "--") {
		key, value, eq := strings.Cut(words[0], "=")
		if key != "--port" && key != "--format" && key != "--timeout" && key != "--errors" && key != "--project" && key != "--params-file" {
			break
		}
		words = words[1:]
		if !eq {
			if len(words) == 0 {
				return 0
			}
			value = words[0]
			words = words[1:]
		}
		if key == "--port" {
			port, _ = strconv.Atoi(value)
		}
		if key == "--project" {
			root, e := resolveCLIProject(value)
			if e != nil {
				return 0
			}
			cliProjectRoot = root
		}
	}
	cwd := cliWorkingDirectory()
	resolved, err := client.ResolvePort(port, cwd)
	var c cliCatalog
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 700*time.Millisecond)
		defer cancel()
		var loadErr error
		c, _, loadErr = loadCLICatalog(ctx, resolved, port != 0 || client.Env("SWALLOWTAIL_PORT") != "")
		if loadErr != nil {
			c = cliCatalog{}
		}
	}
	for _, candidate := range completionCandidates(words, c) {
		fmt.Println(candidate)
	}
	return 0
}

var safeCompletion = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

func completionCandidates(words []string, c cliCatalog) []string {
	prefix := ""
	if len(words) > 0 {
		prefix = strings.ReplaceAll(words[len(words)-1], "_", "-")
	}
	var all []string
	groups := groupMethods(c.Methods)
	if len(words) <= 1 {
		all = append(all, sortedKeys(localCompletionFlags)...)
		all = append(all, sortedKeys(groups)...)
		all = append(all, "--port", "--format", "--timeout", "--errors", "--help", "--version", "--project", "--params-file")
	} else {
		group := strings.ReplaceAll(words[0], "-", "_")
		if group == "help" && len(words) == 2 {
			all = append(all, sortedKeys(groups)...)
			all = append(all, "all")
		} else if group == "upgrade" {
			if len(words) == 2 {
				all = append(all, sortedKeys(upgradeCompletionFlags)...)
			} else {
				all = append(all, upgradeCompletionFlags[words[1]]...)
			}
			all = append(all, "--help")
		} else if group == "completion" {
			all = []string{"bash", "powershell"}
		} else if len(words) == 2 {
			all = append(all, groups[group]...)
			all = append(all, localCompletionFlags[group]...)
			all = append(all, "--help")
		} else {
			method := group + "." + strings.ReplaceAll(words[1], "-", "_")
			if d, ok := c.Docs[method]; ok {
				for _, p := range d.Params {
					all = append(all, "--"+p.Name)
				}
			} else {
				all = append(all, localCompletionFlags[group]...)
			}
			all = append(all, "--help")
		}
	}
	set := map[string]bool{}
	for _, item := range all {
		item = strings.ReplaceAll(item, "_", "-")
		if safeCompletion.MatchString(item) && strings.HasPrefix(item, prefix) {
			set[item] = true
		}
	}
	return sortedKeys(set)
}

const bashCompletion = `_godot_mcp_complete() {
  local IFS=$'\n'
  mapfile -t COMPREPLY < <(swallowtail __complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
}
complete -F _godot_mcp_complete swallowtail swallowtail.exe godot-mcp godot-mcp.exe
`

const powerShellCompletion = `Register-ArgumentCompleter -Native -CommandName swallowtail,swallowtail.exe,godot-mcp,godot-mcp.exe -ScriptBlock {
  param($wordToComplete, $commandAst, $cursorPosition)
  $words = @($commandAst.CommandElements | Select-Object -Skip 1 | Where-Object { $_.Extent.StartOffset -lt $cursorPosition } | ForEach-Object {
    if ($_ -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $_.Value } else { $_.Extent.Text }
  })
  if ([string]::IsNullOrEmpty($wordToComplete)) { $words += '' }
  & swallowtail __complete @words 2>$null | ForEach-Object {
    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
  }
}
`
