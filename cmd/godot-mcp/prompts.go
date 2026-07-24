package main

import (
	"encoding/json"
	"strings"
)

// mcpPrompt is a static MCP prompt: a named, reusable instruction block distilled
// from the godot-mcp agent skill. Unlike typed tools (built from the addon's live
// param docs), prompts carry embedded text and are served regardless of editor
// availability — the binary is distributed standalone, so no runtime file reads.
type mcpPrompt struct {
	name        string
	description string
	arguments   []promptArg
	// render builds the prompt's user-message text from the (optional) arguments.
	// Most prompts ignore args and return a constant block; spatial-placement
	// weaves in an optional `target`.
	render func(args map[string]string) string
}

type promptArg struct {
	name        string
	description string
	required    bool
}

// prompts is the static registry served by prompts/list and prompts/get, mirroring
// the `resources` registry. Order is the list order surfaced to clients.
var prompts = []mcpPrompt{
	{
		name:        "discover-then-drive",
		description: "The core godot-mcp playbook: ground on the live 4.7 engine API before acting, and follow the durable editor rules.",
		render:      func(map[string]string) string { return discoverThenDrivePrompt },
	},
	{
		name:        "spatial-placement",
		description: "Place 3D objects the right way: anchor, read real world bounds back, seat with a raycast, and verify numerically.",
		arguments: []promptArg{
			{name: "target", description: "node path or description of what is being placed", required: false},
		},
		render: func(args map[string]string) string {
			text := spatialPlacementPrompt
			if t := strings.TrimSpace(args["target"]); t != "" {
				text += "\n\nApply this to: " + t
			}
			return text
		},
	},
	{
		name:        "launch-recovery",
		description: "Recover an unreachable Godot editor from its discovery verdict (running/starting/crashed/closed) without relaunching blindly.",
		render:      func(map[string]string) string { return launchRecoveryPrompt },
	},
	{
		name:        "bug-hunt",
		description: "Treat a live-editor session as a bug-hunt: root-cause surprising results as tool bugs and verify behavior by reading state back.",
		render:      func(map[string]string) string { return bugHuntPrompt },
	},
}

// promptDescriptors is the prompts/list payload: name + description, plus an
// arguments array only when a prompt takes arguments.
func promptDescriptors() []map[string]any {
	out := make([]map[string]any, 0, len(prompts))
	for _, p := range prompts {
		d := map[string]any{"name": p.name, "description": p.description}
		if len(p.arguments) > 0 {
			args := make([]map[string]any, 0, len(p.arguments))
			for _, a := range p.arguments {
				args = append(args, map[string]any{
					"name": a.name, "description": a.description, "required": a.required,
				})
			}
			d["arguments"] = args
		}
		out = append(out, d)
	}
	return out
}

// promptsGet replies to prompts/get: it renders the named prompt (weaving in any
// arguments) into a single user text message. An unknown name is an invalid-params
// error (-32602), matching the resources/read unknown-URI shape.
func (s *mcpServer) promptsGet(msg rpcMsg) {
	var p struct {
		Name      string            `json:"name"`
		Arguments map[string]string `json:"arguments"`
	}
	if err := json.Unmarshal(msg.Params, &p); err != nil {
		s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "invalid params: " + err.Error()})
		return
	}
	for _, pr := range prompts {
		if pr.name == p.Name {
			s.reply(msg.ID, map[string]any{
				"description": pr.description,
				"messages": []map[string]any{{
					"role":    "user",
					"content": map[string]any{"type": "text", "text": pr.render(p.Arguments)},
				}},
			}, nil)
			return
		}
	}
	s.reply(msg.ID, nil, &rpcErr{Code: -32602, Message: "unknown prompt: " + p.Name})
}

// The four prompt bodies below are distilled from skills/godot-mcp/SKILL.md and the
// root context doc — tight, self-contained instruction blocks, not verbatim dumps.

const discoverThenDrivePrompt = "Drive a running Godot editor (4.7+) through the godot-mcp addon with the discover-then-drive loop. " +
	"Your training may predate the running engine, so never guess whether a class, property, or method exists — confirm it against the live build first " +
	"with engine.search {query} and engine.class_info {class} (class_info defaults to a class's OWN members, where version-new API lives). " +
	"engine.commands lists this server's own methods with param docs. The live engine is ground truth; when memory and it disagree, it wins.\n\n" +
	"Act the Godot way. Prefer inspector properties over code: set visual state (color, transform, positions) with node.set so it stays editable in the inspector, " +
	"not from GDScript. Compose from nodes and small per-thing scenes instead of one monolith script. Decouple with signals (node.connect), " +
	"not polling or get_node(\"../../\") chains.\n\n" +
	"Respect the durable rules. Never edit project.godot directly — use project.set_setting. Run editor.reload after script.create or a major script.edit " +
	"so Godot picks up the change. Prefer input.action over raw input.key when an InputMap action exists. Save with scene.save after significant edits. " +
	"Editor mutations are undoable; reads are safe."

const spatialPlacementPrompt = "Place 3D objects with the anchor / read-back / verify discipline — you cannot perceive 3D reliably from one screenshot, and absolute-coordinate math drifts. " +
	"Never position dependent objects with parallel absolute coordinates: deriving every part from the same constants leaves nothing anchored to what actually landed, " +
	"so a small error floats or sinks a piece and one camera angle hides it.\n\n" +
	"1. Anchor to realized geometry. Place a piece, read its REAL world bounds back with spatial.bounds (AABB center/size/min/max), and derive the next piece from those numbers — floor to bounds to wall to bounds to fixture.\n" +
	"2. Mind local vs global. node.set position is LOCAL to the parent; to anchor across the tree write global_position. spatial.align / place_on / distribute already do this.\n" +
	"3. Seat on surfaces with a downward raycast (spatial.raycast, or spatial.place_on) instead of computing heights. The edit-time ray hits CSG use_collision and real colliders; in the running game raycast via runtime.eval.\n" +
	"4. Face with spatial.look_at (engine math), never hand-computed Euler — hand-rolled angles run about 20 degrees off.\n" +
	"5. Verify numerically, not by one screenshot. spatial.relate / spatial.lint after a placement (center_delta.x = 0, gap.y = 0 means touching, not sunk). If you genuinely need eyes, teleport the camera to several vantages — one frame hides a centimeter-scale error.\n\n" +
	"Godot is +Y up, -Z forward, right-handed, meters."

const launchRecoveryPrompt = "Recover an unreachable Godot editor from its discovery verdict, not by relaunching blindly. When a command fails because the editor isn't reachable, " +
	"run the godot-mcp status (or doctor) preflight first — it reads the addon's discovery file and returns a verdict:\n\n" +
	"- running — the editor is reachable. NEVER launch another; a second instance stacks and breaks port discovery.\n" +
	"- starting — the process is alive but still booting. WAIT a few seconds and retry; do NOT launch.\n" +
	"- crashed — a stale discovery file remains but the process is gone. Tell the user it crashed; you may relaunch exactly one editor.\n" +
	"- closed — no discovery file (clean exit or never started). You may launch exactly one editor if the task needs it.\n\n" +
	"Launch with `godot --path <project> --editor`. Relaunch AT MOST ONCE; if it is still unreachable after one attempt, stop and report — do not loop launches. " +
	"After a launch, status reading running or starting is your guard against opening a second."

const bugHuntPrompt = "Treat a live-editor session as a bug-hunt, not a demo. When a command returns something surprising — a wrong number, an unexpected error, a \"that's weird\" — " +
	"STOP and root-cause it before continuing. Suspect the tool surface (this addon's commands and base_command helpers) first, not the engine: " +
	"past sessions caught real bugs this way (a node.set plural-params regression, a wrong \"no edit-time physics\" claim).\n\n" +
	"Confirm behavior against ground truth rather than the success envelope. A command returning sent:true or ok is not proof it worked — read the affected state back: " +
	"node.get / runtime.get the property, scene.tree for structure, engine.class_info to confirm a property exists, a screenshot for visuals. Input is fire-and-forget; verify effects, don't assume them.\n\n" +
	"When you reproduce a surprise, fix the root cause in the tool and, where practical, turn the reproduction into a kept check. Re-run the live sweep after any change to " +
	"command registration or the base_command helpers, where tool bugs cluster."
