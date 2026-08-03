@tool
extends RefCounted

## Native GDScript style linter — the rule set from the official style guide, with
## no external binary.
##
## Everything works off the source text rather than a loaded Script, for two
## reasons: the symbol table carries no line numbers (and a finding without a line
## is not actionable), and source scanning still reports on a file that does not
## compile, which is when style feedback is often most useful.
##
## The scan is comment- and string-aware. Every source rule reads the `code` view,
## where comment text is gone and string *contents* are blanked to spaces with the
## quotes and column positions intact — so `a == a` inside a string never trips
## comparison-with-itself, and a `#` in a string never truncates a line. Rules that
## genuinely need string contents (duplicated-load) read the `text` view instead.
##
## Where a rule cannot be decided confidently from source alone, it stays quiet.
## A linter that cries wolf on correct code teaches agents to ignore it.

const SEVERITY := {
	"class-name": "error",
	"function-name": "error",
	"function-argument-name": "error",
	"signal-name": "error",
	"variable-name": "error",
	"constant-name": "error",
	"enum-name": "error",
	"enum-member-name": "error",
	"loop-variable-name": "error",
	"comparison-with-itself": "warning",
	"duplicated-load": "warning",
	"max-line-length": "warning",
	"no-else-return": "warning",
	"private-access": "warning",
	"standalone-expression": "warning",
	"unnecessary-pass": "warning",
	"unused-argument": "warning",
}

## Statement keywords that open or continue a block, used to tell a bare
## expression from ordinary control flow.
const _STATEMENT_KEYWORDS := [
	"if", "elif", "else", "for", "while", "match", "return", "pass", "break",
	"continue", "func", "class", "class_name", "extends", "var", "const", "enum",
	"signal", "static", "await", "assert", "breakpoint", "yield", "emit_signal",
	"@export", "@onready", "@tool", "@icon", "@rpc", "@warning_ignore",
]

## Only `return` counts as the terminator that makes a following `else`/`elif`
## redundant. `break`/`continue` end a loop iteration rather than the function, and
## treating them the same flagged an `elif` whose sibling branch broke only
## conditionally, from inside a nested `if`.


static func rule_names() -> Array:
	var names := SEVERITY.keys()
	names.sort()
	return names


# --- Scanning ---------------------------------------------------------------

## Split `source` into parallel views plus per-line ignore directives.
##
## Returns {code, text, ignores}: `code` has comments removed and string contents
## blanked (quotes kept, so columns still line up), `text` has comments removed
## with strings intact, and `ignores` maps a 0-based line index to the set of rule
## names suppressed there.
static func _scan(source: String) -> Dictionary:
	var raw := source.split("\n")
	var code := PackedStringArray()
	var text := PackedStringArray()
	var ignores := {}

	var multiline_quote := ""  # non-empty while inside a """ or ''' block

	for index in range(raw.size()):
		var line: String = raw[index]
		var code_line := ""
		var text_line := ""
		var comment := ""
		var quote := ""  # non-empty while inside a single-line string
		var i := 0

		while i < line.length():
			var ch := line[i]
			var triple := line.substr(i, 3)

			if not multiline_quote.is_empty():
				if triple == multiline_quote:
					code_line += "   "
					text_line += triple
					multiline_quote = ""
					i += 3
					continue
				code_line += " "
				text_line += ch
				i += 1
				continue

			if quote.is_empty() and (triple == '"""' or triple == "'''"):
				multiline_quote = triple
				code_line += "   "
				text_line += triple
				i += 3
				continue

			if not quote.is_empty():
				# Keep the escape pair together so a \" does not close the string.
				if ch == "\\" and i + 1 < line.length():
					code_line += "  "
					text_line += line.substr(i, 2)
					i += 2
					continue
				if ch == quote:
					quote = ""
					code_line += ch
					text_line += ch
					i += 1
					continue
				code_line += " "
				text_line += ch
				i += 1
				continue

			if ch == "#":
				comment = line.substr(i + 1)
				break

			if ch == '"' or ch == "'":
				quote = ch
				code_line += ch
				text_line += ch
				i += 1
				continue

			code_line += ch
			text_line += ch
			i += 1

		code.append(code_line)
		text.append(text_line)

		var directive := _parse_ignore(comment)
		if not directive.is_empty():
			var target: int = index + 1 if directive["next_line"] else index
			var existing: Array = ignores.get(target, [])
			existing.append_array(directive["rules"])
			ignores[target] = existing

	return {"code": code, "text": text, "ignores": ignores, "raw": raw}


## Read a `gdlint-ignore` / `gdlint-ignore-next-line` directive out of comment
## text. An empty rule list means "suppress everything on that line".
static func _parse_ignore(comment: String) -> Dictionary:
	var trimmed := comment.strip_edges()
	var next_line := false
	var rest := ""
	if trimmed.begins_with("gdlint-ignore-next-line"):
		next_line = true
		rest = trimmed.substr("gdlint-ignore-next-line".length())
	elif trimmed.begins_with("gdlint-ignore"):
		rest = trimmed.substr("gdlint-ignore".length())
	else:
		return {}
	var rules: Array = []
	for part in rest.split(",", false):
		var name := part.strip_edges()
		if not name.is_empty():
			rules.append(name)
	return {"next_line": next_line, "rules": rules}


# --- Naming helpers ---------------------------------------------------------

static func _is_snake_case(name: String) -> bool:
	return _matches(name, "^_*[a-z0-9]+(_[a-z0-9]+)*_*$")


static func _is_constant_case(name: String) -> bool:
	return _matches(name, "^_*[A-Z0-9]+(_[A-Z0-9]+)*_*$")


static func _is_pascal_case(name: String) -> bool:
	return _matches(name, "^_*[A-Z][A-Za-z0-9]*$")


static func _matches(text: String, pattern: String) -> bool:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(text) != null


static func _search(pattern: String, text: String) -> RegExMatch:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search(text)


## Typed on purpose: an untyped Array yields Variant elements, and `var x := m.get_string(1)`
## on a Variant is a parse error rather than a runtime surprise.
static func _search_all(pattern: String, text: String) -> Array[RegExMatch]:
	var re := RegEx.new()
	re.compile(pattern)
	return re.search_all(text)


static func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# --- Entry point ------------------------------------------------------------

## Lint `source`. `opts` accepts max_line_length (int) and disable (Array of rule
## names). Returns an Array of {line, rule, severity, message}, sorted by line.
static func lint(source: String, opts: Dictionary = {}) -> Array:
	var max_line_length := int(opts.get("max_line_length", 100))
	var disabled: Array = opts.get("disable", [])
	var scan := _scan(source)
	var code: PackedStringArray = scan["code"]
	var text: PackedStringArray = scan["text"]
	var ignores: Dictionary = scan["ignores"]
	var raw: PackedStringArray = scan["raw"]

	var findings: Array = []
	_check_names(code, findings)
	_check_enums(code, findings)
	_check_line_length(raw, max_line_length, findings)
	_check_duplicated_load(text, findings)
	_check_comparison_with_itself(code, findings)
	_check_unnecessary_pass(code, findings)
	_check_no_else_return(code, findings)
	_check_standalone_expression(code, findings)
	_check_private_access(code, findings)
	_check_unused_arguments(code, findings)

	var kept: Array = []
	for f in findings:
		if f["rule"] in disabled:
			continue
		# An ignore directive with no rule names suppresses everything on the line.
		var key := int(f["line"]) - 1
		if ignores.has(key):
			var suppressed: Array = ignores[key]
			if suppressed.is_empty() or f["rule"] in suppressed:
				continue
		kept.append(f)

	kept.sort_custom(func(a, b): return int(a["line"]) < int(b["line"]))
	return kept


static func _add(findings: Array, line_index: int, rule: String, message: String) -> void:
	findings.append({
		"line": line_index + 1,
		"rule": rule,
		"severity": SEVERITY.get(rule, "warning"),
		"message": message,
	})


# --- Rules: declarations ----------------------------------------------------

static func _check_names(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		var line := code[i]
		var stripped := line.strip_edges()
		if stripped.is_empty():
			continue

		var m := _search("^class_name\\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
		if m != null and not _is_pascal_case(m.get_string(1)):
			_add(findings, i, "class-name",
				"Class name '%s' should be in PascalCase format" % m.get_string(1))

		m = _search("^(?:static\\s+)?func\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\(", stripped)
		if m != null:
			if not _is_snake_case(m.get_string(1)):
				_add(findings, i, "function-name",
					"Function name '%s' should be in snake_case or _private_snake_case format"
					% m.get_string(1))
			for arg in _function_args(code, i):
				if not _is_snake_case(arg):
					_add(findings, i, "function-argument-name",
						"Function argument '%s' should be in snake_case or _private_snake_case format"
						% arg)

		m = _search("^signal\\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
		if m != null and not _is_snake_case(m.get_string(1)):
			_add(findings, i, "signal-name",
				"Signal name '%s' should be in snake_case format" % m.get_string(1))

		# Skip annotations (@export, @onready) before looking for `var`.
		var without_annotations := _search("^(?:@[A-Za-z_]\\w*(?:\\([^)]*\\))?\\s+)*(.*)$", stripped)
		var body := without_annotations.get_string(1) if without_annotations != null else stripped
		m = _search("^(?:static\\s+)?var\\s+([A-Za-z_][A-Za-z0-9_]*)", body)
		if m != null and not _is_snake_case(m.get_string(1)):
			_add(findings, i, "variable-name",
				"Variable name '%s' should be in snake_case or _private_snake_case format"
				% m.get_string(1))

		# A const bound to preload()/load() may legitimately be either case: it is a
		# type when it holds a script (`const NodeUtils := preload(...)`, called as
		# NodeUtils.foo()) and an asset when it holds a scene or texture
		# (`const PLAYER_SCENE := preload(...)`). Both are idiomatic, so accept both
		# and flag only a name that is neither.
		m = _search("^const\\s+([A-Za-z_][A-Za-z0-9_]*)", body)
		if m != null:
			var const_name := m.get_string(1)
			var is_preload := _search("=\\s*(?:pre)?load\\s*\\(", body) != null
			var ok := _is_constant_case(const_name)
			if is_preload:
				ok = ok or _is_pascal_case(const_name)
			if not ok:
				var expected := "CONSTANT_CASE or PascalCase" if is_preload else "CONSTANT_CASE"
				_add(findings, i, "constant-name",
					"Constant name '%s' should be in %s format" % [const_name, expected])

		m = _search("^enum\\s+([A-Za-z_][A-Za-z0-9_]*)", stripped)
		if m != null and not _is_pascal_case(m.get_string(1)):
			_add(findings, i, "enum-name",
				"Enum name '%s' should be in PascalCase format" % m.get_string(1))

		m = _search("^for\\s+([A-Za-z_][A-Za-z0-9_]*)\\s+in\\b", stripped)
		if m != null and not _is_snake_case(m.get_string(1)):
			_add(findings, i, "loop-variable-name",
				"Loop variable '%s' should be in snake_case or _private_snake_case format"
				% m.get_string(1))


## Enum members, which may span lines: `enum Mode { A, B }` or a braced block.
static func _check_enums(code: PackedStringArray, findings: Array) -> void:
	var i := 0
	while i < code.size():
		var stripped := code[i].strip_edges()
		if not (stripped.begins_with("enum ") or stripped.begins_with("enum{")):
			i += 1
			continue
		var open := stripped.find("{")
		if open == -1:
			i += 1
			continue

		var body := stripped.substr(open + 1)
		var start := i
		while body.find("}") == -1 and i + 1 < code.size():
			i += 1
			body += "\n" + code[i]
		body = body.substr(0, body.find("}")) if body.find("}") != -1 else body

		for entry in body.split(",", false):
			var name_part := entry.split("=")[0].strip_edges().strip_edges(true, true)
			name_part = name_part.replace("\n", "").replace("\t", "").strip_edges()
			if name_part.is_empty():
				continue
			if not _is_constant_case(name_part):
				_add(findings, start, "enum-member-name",
					"Enum element name '%s' should be in CONSTANT_CASE format" % name_part)
		i += 1


## Argument names from a `func` signature, joined across continuation lines and
## split at paren depth 0 so a default like `Vector2(1, 2)` stays one argument.
static func _function_args(code: PackedStringArray, start: int) -> Array[String]:
	var joined := ""
	var depth := 0
	var started := false
	for i in range(start, code.size()):
		for ch in code[i]:
			if ch == "(":
				depth += 1
				started = true
				if depth == 1:
					continue
			elif ch == ")":
				depth -= 1
				if depth == 0:
					started = false
					break
			if depth >= 1:
				joined += ch
		if started == false and depth == 0 and i >= start:
			break

	var args: Array[String] = []
	var current := ""
	depth = 0
	for ch in joined:
		if ch in ["(", "[", "{"]:
			depth += 1
		elif ch in [")", "]", "}"]:
			depth -= 1
		if ch == "," and depth == 0:
			args.append(current)
			current = ""
			continue
		current += ch
	args.append(current)

	var names: Array[String] = []
	for arg in args:
		var name := arg.split(":")[0].split("=")[0].strip_edges()
		if name.is_empty():
			continue
		if _matches(name, "^[A-Za-z_][A-Za-z0-9_]*$"):
			names.append(name)
	return names


# --- Rules: line and expression level ---------------------------------------

static func _check_line_length(raw: PackedStringArray, limit: int, findings: Array) -> void:
	if limit <= 0:
		return
	for i in range(raw.size()):
		var length := raw[i].length()
		if length > limit:
			_add(findings, i, "max-line-length",
				"Line is too long. Found %d characters, maximum allowed is %d" % [length, limit])


static func _check_duplicated_load(text: PackedStringArray, findings: Array) -> void:
	var seen := {}
	var occurrences: Array[Dictionary] = []
	for i in range(text.size()):
		for m in _search_all("(?:pre)?load\\(\\s*(\"[^\"]*\"|'[^']*')\\s*\\)", text[i]):
			var target := m.get_string(1)
			seen[target] = int(seen.get(target, 0)) + 1
			occurrences.append({"line": i, "target": target})
	for entry in occurrences:
		if int(seen[entry["target"]]) > 1:
			_add(findings, int(entry["line"]), "duplicated-load",
				"Duplicated load of '%s'. Consider extracting to a constant." % entry["target"])


static func _check_comparison_with_itself(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		var m := _search(
			"([A-Za-z_][A-Za-z0-9_.]*)\\s*(==|!=|<=|>=|<|>)\\s*([A-Za-z_][A-Za-z0-9_.]*)",
			code[i]
		)
		if m == null:
			continue
		if m.get_string(1) == m.get_string(3):
			_add(findings, i, "comparison-with-itself",
				"Redundant comparison '%s %s %s' - comparing expression with itself"
				% [m.get_string(1), m.get_string(2), m.get_string(3)])


## `pass` alongside other statements in the same block. `pass` alone in a block is
## required, so only a block with real content is reported.
static func _check_unnecessary_pass(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		if code[i].strip_edges() != "pass":
			continue
		var indent := _indent_of(code[i])
		var has_sibling := false

		for j in range(i - 1, -1, -1):
			var line := code[j]
			if line.strip_edges().is_empty():
				continue
			var other := _indent_of(line)
			if other < indent:
				break
			if other == indent:
				has_sibling = true
				break
		if not has_sibling:
			for j in range(i + 1, code.size()):
				var line := code[j]
				if line.strip_edges().is_empty():
					continue
				var other := _indent_of(line)
				if other < indent:
					break
				if other == indent:
					has_sibling = true
					break
		if has_sibling:
			_add(findings, i, "unnecessary-pass",
				"Unnecessary 'pass' statement when other statements are present")


## `else` or `elif` after a branch that already returns. Both are redundant: if the
## branch above cannot fall through, the `else` adds nothing and the `elif` may as
## well be a plain `if`. They get distinct messages because the fix differs.
static func _check_no_else_return(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		var stripped := code[i].strip_edges()
		var is_else := stripped.begins_with("else:")
		var is_elif := stripped.begins_with("elif ") or stripped.begins_with("elif(")
		if not (is_else or is_elif):
			continue
		var last := _last_statement_of_branch(code, i)
		if last.is_empty():
			continue
		if not (last == "return" or last.begins_with("return ")):
			continue
		var message := (
			"Unnecessary 'else' after 'if'/'elif' blocks that end with 'return'"
			if is_else
			else "Unnecessary 'elif' after 'if' block that ends with 'return'. Use 'if' instead"
		)
		_add(findings, i, "no-else-return", message)


## First line of the last top-level statement in the branch body above `at`.
##
## Two things make the naive "previous non-blank line" wrong. A `return success({`
## spanning eight lines ends on `})`, which hides the return; and a `break` nested
## inside a deeper `if` is not the branch's own last statement, so treating it as
## one flags an `elif` that is genuinely needed. Statements are therefore split at
## the body's base indent with bracket depth back at zero.
static func _last_statement_of_branch(code: PackedStringArray, at: int) -> String:
	var indent := _indent_of(code[at])

	var body: Array[int] = []
	for j in range(at - 1, -1, -1):
		if code[j].strip_edges().is_empty():
			continue
		if _indent_of(code[j]) <= indent:
			break
		body.push_front(j)
	if body.is_empty():
		return ""

	var base := _indent_of(code[body[0]])
	var depth := 0
	var last_start := -1
	for j in body:
		if depth == 0 and _indent_of(code[j]) == base:
			last_start = j
		for ch in code[j]:
			if ch in ["(", "[", "{"]:
				depth += 1
			elif ch in [")", "]", "}"]:
				depth = max(0, depth - 1)
	if last_start == -1:
		return ""
	return code[last_start].strip_edges()


## A statement whose value is discarded. Deliberately narrow: only a pure
## arithmetic or comparison expression with no call, assignment, or keyword, so
## ordinary code is never flagged.
static func _check_standalone_expression(code: PackedStringArray, findings: Array) -> void:
	var depth := 0  # running bracket depth, so continuation lines are never judged
	for i in range(code.size()):
		var stripped := code[i].strip_edges()
		var open_at_line_start := depth
		for ch in stripped:
			if ch in ["(", "[", "{"]:
				depth += 1
			elif ch in [")", "]", "}"]:
				depth = max(0, depth - 1)

		if open_at_line_start > 0:
			continue
		if stripped.is_empty() or stripped.ends_with(":") or stripped.ends_with(","):
			continue
		# A line continued from the one above, by backslash or a trailing operator.
		if i > 0:
			var previous := code[i - 1].strip_edges()
			if previous.ends_with("\\") or _search("[\\+\\-\\*/%=<>,]$", previous) != null:
				continue
		if stripped.contains("(") or stripped.contains("=") or stripped.contains("["):
			continue
		if stripped.begins_with("@") or stripped.begins_with("."):
			continue
		var first := stripped.split(" ")[0].split(".")[0]
		if first in _STATEMENT_KEYWORDS:
			continue
		# Must actually combine terms, or it is a bare identifier we cannot judge.
		if _search("[\\+\\-\\*/%]|==|!=|<=|>=|<|>", stripped) == null:
			continue
		if _search("^[A-Za-z0-9_\\.\\s\\+\\-\\*/%<>=!]+$", stripped) == null:
			continue
		_add(findings, i, "standalone-expression",
			"Standalone expression '%s' is not assigned or used, the line may have no effect"
			% stripped)


static func _check_private_access(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		for m in _search_all("([A-Za-z_][A-Za-z0-9_]*)\\.(_[A-Za-z0-9_]+)", code[i]):
			var receiver := m.get_string(1)
			if receiver in ["self", "super"]:
				continue
			_add(findings, i, "private-access",
				"Access to private member '%s' of '%s' from outside its own script"
				% [m.get_string(2), receiver])


## An argument never mentioned in its function body. Args already prefixed with
## '_' are the documented way to say "intentionally unused" and are skipped.
static func _check_unused_arguments(code: PackedStringArray, findings: Array) -> void:
	for i in range(code.size()):
		var stripped := code[i].strip_edges()
		if _search("^(?:static\\s+)?func\\s+[A-Za-z_][A-Za-z0-9_]*\\s*\\(", stripped) == null:
			continue
		var args := _function_args(code, i)
		if args.is_empty():
			continue

		var indent := _indent_of(code[i])
		var body := ""
		for j in range(i + 1, code.size()):
			var line := code[j]
			if line.strip_edges().is_empty():
				continue
			if _indent_of(line) <= indent:
				break
			body += "\n" + line

		for arg in args:
			if arg.begins_with("_"):
				continue
			if _search("\\b%s\\b" % arg, body) == null:
				_add(findings, i, "unused-argument",
					"Function argument '%s' is unused. Consider removing it or prefixing with '_'"
					% arg)
