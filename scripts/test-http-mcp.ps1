#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Conformance + functional sweep for the addon's in-editor streamable-HTTP MCP
  endpoint (mcp_http_server.gd, POST /mcp).

.DESCRIPTION
  The editor must already be running with the plugin enabled — this script never
  launches Godot. It resolves the bound port from the project's discovery file
  (<project>/.godot/godot-mcp.json, key http_port) unless -Port is given.

  Two client layers, on purpose:
    * raw TcpClient for HTTP framing (411/413/405/404/keep-alive/pipelining), which
      a high-level client papers over;
    * System.Net.Http.HttpClient for the MCP-level tests, because that is what a
      real MCP client uses.

  Exit code 0 = every test passed, 1 = at least one failed.

.EXAMPLE
  pwsh -File scripts/test-http-mcp.ps1
  pwsh -File scripts/test-http-mcp.ps1 -Port 9101 -Verbose
#>
[CmdletBinding()]
param(
    [string]$Project = (Join-Path $PSScriptRoot '..' 'project'),
    [int]$Port = 0,
    # Per-request read budget. engine.commands with docs is a few hundred KB and
    # runs on the editor's main thread, so keep this generous.
    [int]$TimeoutMs = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$HOST_ADDR = '127.0.0.1'
$MCP_PATH = '/mcp'
$LATEST_PROTOCOL = '2025-06-18'

# --- port resolution --------------------------------------------------------

if ($Port -eq 0) {
    $discovery = Join-Path $Project '.godot/godot-mcp.json'
    if (-not (Test-Path $discovery)) {
        Write-Host "No discovery file at $discovery — is the editor running with the plugin enabled?" -ForegroundColor Red
        exit 2
    }
    $d = Get-Content $discovery -Raw | ConvertFrom-Json
    $Port = [int]$d.http_port
    if ($Port -eq 0) {
        Write-Host "Discovery reports http_port 0 — the MCP HTTP endpoint is disabled (godot_mcp/network/mcp_http)." -ForegroundColor Red
        exit 2
    }
    Write-Host "Editor: pid $($d.pid), Godot $($d.godot_version), project $($d.project_path)" -ForegroundColor DarkGray
}
$BASE = "http://${HOST_ADDR}:${Port}${MCP_PATH}"
Write-Host "Target: $BASE`n" -ForegroundColor Cyan

# --- raw HTTP ---------------------------------------------------------------

# Send a byte-exact request over a fresh (or supplied) connection and parse one
# response. Returns @{Code; Reason; Headers; Body; Closed; TimedOut}.
function Send-Raw {
    param(
        [string]$Raw,
        [System.Net.Sockets.TcpClient]$Client,   # supply to reuse a connection
        [switch]$NoRead,
        [int]$ReadTimeoutMs = $TimeoutMs
    )
    $own = $null -eq $Client
    if ($own) {
        $Client = [System.Net.Sockets.TcpClient]::new()
        $Client.NoDelay = $true
        $Client.Connect($HOST_ADDR, $Port)
    }
    $stream = $Client.GetStream()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Raw)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    if ($NoRead) { return @{ Client = $Client } }
    try { return Read-HttpResponse -Stream $stream -TimeoutMs $ReadTimeoutMs }
    finally { if ($own) { $Client.Close() } }
}

# Incremental HTTP/1.1 response reader: stops at the end of ONE response so a
# keep-alive connection can be read again (never waits out the timeout). The body
# is cut at Content-Length and anything past it is handed back through -Pending
# (a @{Bytes=[byte[]]} carrier), which is what makes pipelined reads work.
function Read-HttpResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$TimeoutMs = 30000,
        [hashtable]$Pending
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ms = [System.IO.MemoryStream]::new()
    if ($Pending -and $Pending.Bytes -and $Pending.Bytes.Length -gt 0) {
        $ms.Write($Pending.Bytes, 0, $Pending.Bytes.Length)
        $Pending.Bytes = [byte[]]::new(0)
    }
    $chunk = [byte[]]::new(65536)
    $headerEnd = -1
    $scanFrom = 0
    $contentLength = -1
    $closed = $false
    $code = 0; $reason = ''; $headers = @{}

    while ($true) {
        if ($headerEnd -lt 0 -and $ms.Length -ge 4) {
            $arr = $ms.GetBuffer()
            $len = [int]$ms.Length
            for ($i = $scanFrom; $i -le $len - 4; $i++) {
                if ($arr[$i] -eq 13 -and $arr[$i + 1] -eq 10 -and $arr[$i + 2] -eq 13 -and $arr[$i + 3] -eq 10) {
                    $headerEnd = $i + 4
                    break
                }
            }
            if ($headerEnd -lt 0) { $scanFrom = [Math]::Max(0, $len - 3) }
            else {
                $text = [System.Text.Encoding]::UTF8.GetString($arr, 0, $headerEnd - 4)
                $lines = $text -split "`r`n"
                $sl = $lines[0] -split ' ', 3
                if ($sl.Count -ge 2) { $code = [int]$sl[1] }
                if ($sl.Count -ge 3) { $reason = $sl[2] }
                foreach ($line in $lines | Select-Object -Skip 1) {
                    $ci = $line.IndexOf(':')
                    if ($ci -gt 0) { $headers[$line.Substring(0, $ci).Trim().ToLower()] = $line.Substring($ci + 1).Trim() }
                }
                if ($headers.ContainsKey('content-length')) { $contentLength = [int]$headers['content-length'] }
            }
        }

        if ($headerEnd -ge 0) {
            $have = [int]$ms.Length - $headerEnd
            if ($contentLength -le 0 -or $have -ge $contentLength) { break }
        }
        if ($sw.ElapsedMilliseconds -gt $TimeoutMs) { break }

        if ($Stream.DataAvailable) {
            $n = $Stream.Read($chunk, 0, $chunk.Length)
            if ($n -le 0) { $closed = $true; break }
            $ms.Write($chunk, 0, $n)
        }
        else {
            Start-Sleep -Milliseconds 5
        }
    }

    $body = ''
    if ($headerEnd -ge 0 -and $ms.Length -gt $headerEnd) {
        $available = [int]$ms.Length - $headerEnd
        $take = if ($contentLength -ge 0) { [Math]::Min($contentLength, $available) } else { $available }
        $body = [System.Text.Encoding]::UTF8.GetString($ms.GetBuffer(), $headerEnd, $take)
        # Bytes past this response belong to the next one on a pipelined connection.
        $extra = $available - $take
        if ($extra -gt 0 -and $Pending) {
            $leftover = [byte[]]::new($extra)
            [Array]::Copy($ms.GetBuffer(), $headerEnd + $take, $leftover, 0, $extra)
            $Pending.Bytes = $leftover
        }
    }
    return @{
        Code = $code; Reason = $reason; Headers = $headers; Body = $body
        Closed = $closed; TimedOut = ($sw.ElapsedMilliseconds -gt $TimeoutMs -and $headerEnd -lt 0)
    }
}

function New-RawPost {
    param([string]$Json, [hashtable]$ExtraHeaders = @{}, [string]$Path = $MCP_PATH, [switch]$Close)
    $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $h = "POST $Path HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`nContent-Type: application/json`r`nAccept: application/json, text/event-stream`r`nContent-Length: $($body.Length)`r`n"
    foreach ($k in $ExtraHeaders.Keys) { $h += "${k}: $($ExtraHeaders[$k])`r`n" }
    if ($Close) { $h += "Connection: close`r`n" }
    return $h + "`r`n" + $Json
}

# --- MCP-level client (what a real MCP client looks like) -------------------

$httpHandler = [System.Net.Http.HttpClientHandler]::new()
$http = [System.Net.Http.HttpClient]::new($httpHandler)
$http.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)

function Invoke-Rpc {
    param([string]$Method, $Params = @{}, $Id = 1, [hashtable]$ExtraHeaders = @{})
    $payload = @{ jsonrpc = '2.0'; id = $Id; method = $Method; params = $Params } | ConvertTo-Json -Depth 12 -Compress
    $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $BASE)
    $req.Content = $content
    $req.Headers.Add('Accept', 'application/json, text/event-stream')
    foreach ($k in $ExtraHeaders.Keys) { $req.Headers.TryAddWithoutValidation($k, $ExtraHeaders[$k]) | Out-Null }
    $resp = $http.SendAsync($req).GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $obj = $null
    if ($text) { try { $obj = $text | ConvertFrom-Json } catch { $obj = $null } }
    return @{ Status = [int]$resp.StatusCode; Text = $text; Json = $obj; Response = $resp }
}

# Call a tool and return the parsed JSON the addon put in content[0].text.
function Invoke-Tool {
    param([string]$Name, [hashtable]$Arguments = @{}, $Id = 1)
    $r = Invoke-Rpc 'tools/call' @{ name = $Name; arguments = $Arguments } $Id
    $payload = $null
    if ($r.Json -and $r.Json.result -and $r.Json.result.content) {
        try { $payload = $r.Json.result.content[0].text | ConvertFrom-Json } catch { $payload = $null }
    }
    return @{ Raw = $r; IsError = [bool]($r.Json.result.isError); Payload = $payload }
}

# --- harness ----------------------------------------------------------------

$script:Results = [System.Collections.Generic.List[object]]::new()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $detail = ''
    try { $detail = & $Body } catch { $detail = "threw: $($_.Exception.Message)" }
    if ($detail -isnot [string]) { $detail = '' }
    $ok = [string]::IsNullOrWhiteSpace($detail)
    $script:Results.Add([pscustomobject]@{ Name = $Name; Pass = $ok; Detail = $detail })
    if ($ok) { Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Name`n        $detail" -ForegroundColor Red }
}

function Section([string]$Title) { Write-Host "`n$Title" -ForegroundColor Yellow }

# ===========================================================================
Section 'MCP handshake'

Test-Case 'initialize echoes a supported protocolVersion' {
    $r = Invoke-Rpc 'initialize' @{ protocolVersion = $LATEST_PROTOCOL; capabilities = @{}; clientInfo = @{ name = 'conformance'; version = '1' } }
    if ($r.Status -ne 200) { return "status $($r.Status)" }
    if ($r.Json.result.protocolVersion -ne $LATEST_PROTOCOL) { return "got protocolVersion '$($r.Json.result.protocolVersion)'" }
    if (-not $r.Json.result.serverInfo.name) { return 'no serverInfo.name' }
    if (-not $r.Json.result.capabilities.tools) { return 'no tools capability' }
    if (-not $r.Json.result.instructions) { return 'no instructions steer' }
    ''
}

Test-Case 'initialize accepts the older 2025-03-26 revision' {
    $r = Invoke-Rpc 'initialize' @{ protocolVersion = '2025-03-26' }
    if ($r.Json.result.protocolVersion -ne '2025-03-26') { return "got '$($r.Json.result.protocolVersion)'" }
    ''
}

Test-Case 'initialize falls back to latest on an unknown revision' {
    $r = Invoke-Rpc 'initialize' @{ protocolVersion = '1999-01-01' }
    if ($r.Json.result.protocolVersion -ne $LATEST_PROTOCOL) { return "got '$($r.Json.result.protocolVersion)'" }
    ''
}

Test-Case 'notifications/initialized is accepted with 202 and no body' {
    $raw = New-RawPost '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    $r = Send-Raw $raw
    if ($r.Code -ne 202) { return "status $($r.Code)" }
    if ($r.Body.Trim()) { return "expected empty body, got '$($r.Body)'" }
    ''
}

Test-Case 'ping returns an empty result' {
    $r = Invoke-Rpc 'ping'
    if ($null -eq $r.Json.result) { return "no result: $($r.Text)" }
    ''
}

Test-Case 'integer ids echo back as integers, string ids as strings' {
    $a = Invoke-Rpc 'ping' @{} 7
    if ($a.Text -notmatch '"id":7[,}]') { return "integer id not echoed faithfully: $($a.Text)" }
    $b = Invoke-Rpc 'ping' @{} 'abc'
    if ($b.Json.id -ne 'abc') { return "string id became '$($b.Json.id)'" }
    ''
}

# ===========================================================================
Section 'Tool surface'

$script:ToolList = $null

Test-Case 'tools/list puts godot_run first and returns typed tools' {
    $r = Invoke-Rpc 'tools/list'
    if ($r.Status -ne 200) { return "status $($r.Status)" }
    $tools = $r.Json.result.tools
    if (-not $tools) { return 'no tools' }
    $script:ToolList = $tools
    if ($tools[0].name -ne 'godot_run') { return "first tool is '$($tools[0].name)'" }
    if ($tools.Count -lt 2) { return "only $($tools.Count) tool(s) — typed tools missing" }
    ''
}

Test-Case 'every tool name is MCP-legal (^[a-zA-Z0-9_-]{1,64}$)' {
    if (-not $script:ToolList) { return 'no tool list' }
    $bad = $script:ToolList | Where-Object { $_.name -notmatch '^[a-zA-Z0-9_-]{1,64}$' }
    if ($bad) { return "illegal names: $(($bad | Select-Object -First 5 | ForEach-Object { $_.name }) -join ', ')" }
    ''
}

Test-Case 'tool names are unique' {
    if (-not $script:ToolList) { return 'no tool list' }
    $dupes = $script:ToolList | Group-Object name | Where-Object Count -gt 1
    if ($dupes) { return "duplicated: $(($dupes | ForEach-Object { $_.Name }) -join ', ')" }
    ''
}

Test-Case 'every tool carries an object inputSchema' {
    if (-not $script:ToolList) { return 'no tool list' }
    $bad = $script:ToolList | Where-Object { $_.inputSchema.type -ne 'object' }
    if ($bad) { return "$($bad.Count) tool(s) without an object schema, e.g. $($bad[0].name)" }
    ''
}

Test-Case 'a documented tool has real properties and a description' {
    if (-not $script:ToolList) { return 'no tool list' }
    $t = $script:ToolList | Where-Object name -eq 'node_add' | Select-Object -First 1
    if (-not $t) { return 'node_add tool missing' }
    if (-not $t.description) { return 'no description' }
    $props = $t.inputSchema.properties.PSObject.Properties.Name
    foreach ($need in 'type', 'name', 'parent_path') {
        if ($props -notcontains $need) { return "schema lacks '$need' (has: $($props -join ', '))" }
    }
    if ($t.inputSchema.required -notcontains 'type') { return "'type' not marked required" }
    ''
}

# ===========================================================================
Section 'Dispatch through the shared router'

Test-Case 'godot_run reaches a command by dotted name' {
    $t = Invoke-Tool 'godot_run' @{ method = 'engine.version' }
    if ($t.IsError) { return "isError: $($t.Raw.Text)" }
    if ($t.Payload.version.major -ne 4) { return "unexpected payload: $($t.Raw.Text.Substring(0, [Math]::Min(200, $t.Raw.Text.Length)))" }
    ''
}

Test-Case 'a typed tool dispatches the same command' {
    $t = Invoke-Tool 'engine_version'
    if ($t.IsError) { return "isError: $($t.Raw.Text)" }
    if ($t.Payload.version.major -ne 4) { return 'no version payload' }
    ''
}

Test-Case 'a large result survives the read loop (engine.commands, ~300KB)' {
    $t = Invoke-Tool 'godot_run' @{ method = 'engine.commands'; params = @{ docs = $true } }
    if ($t.IsError) { return "isError: $($t.Raw.Text)" }
    if ($t.Payload.count -lt 100) { return "only $($t.Payload.count) commands reported" }
    if ($t.Raw.Text.Length -lt 100000) { return "payload suspiciously small: $($t.Raw.Text.Length) bytes" }
    ''
}

Test-Case 'a command error becomes isError with the addon error code' {
    $t = Invoke-Tool 'godot_run' @{ method = 'node.get'; params = @{ node_path = 'NoSuchNode__conformance' } }
    if (-not $t.IsError) { return "expected isError, got: $($t.Raw.Text)" }
    if ($t.Payload.code -ge 0) { return "no negative error code in payload: $($t.Raw.Text)" }
    ''
}

Test-Case 'an unknown method reports -32601 through the tool result' {
    $t = Invoke-Tool 'godot_run' @{ method = 'nope.nothing' }
    if (-not $t.IsError) { return 'expected isError' }
    if ($t.Payload.code -ne -32601) { return "code $($t.Payload.code)" }
    ''
}

Test-Case 'godot_run without a method is a tool error, not a crash' {
    $t = Invoke-Tool 'godot_run' @{}
    if (-not $t.IsError) { return 'expected isError' }
    ''
}

Test-Case 'an unknown tool name is a JSON-RPC -32602' {
    $r = Invoke-Rpc 'tools/call' @{ name = 'no_such_tool'; arguments = @{} }
    if ($r.Json.error.code -ne -32602) { return "got $($r.Text)" }
    ''
}

Test-Case 'an unknown JSON-RPC method is -32601' {
    $r = Invoke-Rpc 'resources/list'
    if ($r.Json.error.code -ne -32601) { return "got $($r.Text)" }
    ''
}

Test-Case 'concurrent tool calls all answer with their own id' {
    $tasks = @()
    $ids = 101..108
    foreach ($id in $ids) {
        $payload = @{ jsonrpc = '2.0'; id = $id; method = 'tools/call'; params = @{ name = 'engine_version'; arguments = @{} } } | ConvertTo-Json -Depth 8 -Compress
        $content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, 'application/json')
        $tasks += $http.PostAsync($BASE, $content)
    }
    [System.Threading.Tasks.Task]::WaitAll($tasks)
    $seen = @()
    foreach ($t in $tasks) {
        $resp = $t.GetAwaiter().GetResult()
        if ([int]$resp.StatusCode -ne 200) { return "status $([int]$resp.StatusCode)" }
        $j = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $seen += [int]$j.id
    }
    $missing = $ids | Where-Object { $seen -notcontains $_ }
    if ($missing) { return "ids missing from responses: $($missing -join ', ')" }
    ''
}

# ===========================================================================
Section 'HTTP framing'

Test-Case 'malformed JSON is -32700 with a null id' {
    $r = Send-Raw (New-RawPost '{not json')
    if ($r.Code -ne 200) { return "status $($r.Code)" }
    $j = $r.Body | ConvertFrom-Json
    if ($j.error.code -ne -32700) { return "code $($j.error.code)" }
    ''
}

Test-Case 'GET /mcp is 405 with an Allow header' {
    $raw = "GET $MCP_PATH HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`n`r`n"
    $r = Send-Raw $raw
    if ($r.Code -ne 405) { return "status $($r.Code)" }
    if (-not $r.Headers['allow']) { return 'no Allow header' }
    ''
}

Test-Case 'an unknown path is 404' {
    $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":1,"method":"ping"}' @{} '/nope')
    if ($r.Code -ne 404) { return "status $($r.Code)" }
    ''
}

Test-Case 'OPTIONS preflight is 204 with CORS method/header allowances' {
    $raw = "OPTIONS $MCP_PATH HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`nOrigin: http://localhost:5173`r`nAccess-Control-Request-Method: POST`r`n`r`n"
    $r = Send-Raw $raw
    if ($r.Code -ne 204) { return "status $($r.Code)" }
    if ($r.Headers['access-control-allow-methods'] -notmatch 'POST') { return 'preflight does not allow POST' }
    if ($r.Headers.ContainsKey('content-length')) { return '204 must not carry Content-Length' }
    ''
}

Test-Case 'a POST without Content-Length is 411' {
    $raw = "POST $MCP_PATH HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`nContent-Type: application/json`r`n`r`n"
    $r = Send-Raw $raw
    if ($r.Code -ne 411) { return "status $($r.Code)" }
    ''
}

Test-Case 'an oversized Content-Length is 413 without reading the body' {
    $raw = "POST $MCP_PATH HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`nContent-Type: application/json`r`nContent-Length: 33554432`r`n`r`n{"
    $r = Send-Raw $raw
    if ($r.Code -ne 413) { return "status $($r.Code)" }
    ''
}

Test-Case 'keep-alive serves two requests on one connection' {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $client.Connect($HOST_ADDR, $Port)
    try {
        $r1 = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":11,"method":"ping"}') -Client $client
        if ($r1.Code -ne 200) { return "first status $($r1.Code)" }
        $r2 = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":12,"method":"ping"}') -Client $client
        if ($r2.Code -ne 200) { return "second status $($r2.Code)" }
        if (($r2.Body | ConvertFrom-Json).id -ne 12) { return "second response id mismatch: $($r2.Body)" }
    }
    finally { $client.Close() }
    ''
}

Test-Case 'two pipelined requests are answered in order, one at a time' {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $client.Connect($HOST_ADDR, $Port)
    try {
        $both = (New-RawPost '{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"engine_version","arguments":{}}}') +
                (New-RawPost '{"jsonrpc":"2.0","id":22,"method":"ping"}')
        $stream = $client.GetStream()
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($both)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $pending = @{ Bytes = [byte[]]::new(0) }
        $a = Read-HttpResponse -Stream $stream -TimeoutMs $TimeoutMs -Pending $pending
        $b = Read-HttpResponse -Stream $stream -TimeoutMs $TimeoutMs -Pending $pending
        if (($a.Body | ConvertFrom-Json).id -ne 21) { return "first id: $(($a.Body | ConvertFrom-Json).id)" }
        if (($b.Body | ConvertFrom-Json).id -ne 22) { return "second id: $(($b.Body | ConvertFrom-Json).id)" }
    }
    finally { $client.Close() }
    ''
}

Test-Case 'Connection: close is honoured' {
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $client.Connect($HOST_ADDR, $Port)
    try {
        $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":31,"method":"ping"}' @{} $MCP_PATH -Close) -Client $client
        if ($r.Code -ne 200) { return "status $($r.Code)" }
        if ($r.Headers['connection'] -ne 'close') { return "Connection header: '$($r.Headers['connection'])'" }
        # The peer must go away: a further read returns 0 bytes rather than hanging.
        $stream = $client.GetStream()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $gone = $false
        while ($sw.ElapsedMilliseconds -lt 3000) {
            if ($stream.DataAvailable) { if ($stream.Read([byte[]]::new(64), 0, 64) -le 0) { $gone = $true; break } }
            elseif (-not $client.Connected) { $gone = $true; break }
            else { Start-Sleep -Milliseconds 25 }
            # Poll the socket directly: Connected lags until a read/write happens.
            if ($client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and -not $stream.DataAvailable) { $gone = $true; break }
        }
        if (-not $gone) { return 'server kept the connection open after Connection: close' }
    }
    finally { $client.Close() }
    ''
}

# ===========================================================================
Section 'Browser-origin defence (MCP spec: servers MUST validate Origin)'

Test-Case 'a cross-site Origin is rejected' {
    $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":41,"method":"ping"}' @{ Origin = 'http://evil.example' })
    if ($r.Code -ne 403) {
        return "status $($r.Code) — a web page could drive the editor (ACAO: '$($r.Headers['access-control-allow-origin'])')"
    }
    ''
}

Test-Case 'a rejected origin gets no permissive CORS header' {
    $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":42,"method":"ping"}' @{ Origin = 'https://evil.example' })
    $acao = $r.Headers['access-control-allow-origin']
    if ($acao -eq '*') { return "wildcard CORS lets any page read the response" }
    if ($acao -and $acao -match 'evil') { return "echoed the hostile origin back: $acao" }
    ''
}

Test-Case 'a cross-site preflight is not granted' {
    $raw = "OPTIONS $MCP_PATH HTTP/1.1`r`nHost: ${HOST_ADDR}:${Port}`r`nOrigin: http://evil.example`r`nAccess-Control-Request-Method: POST`r`n`r`n"
    $r = Send-Raw $raw
    if ($r.Code -eq 204 -and $r.Headers['access-control-allow-origin'] -eq '*') {
        return 'preflight granted to any origin with a wildcard ACAO'
    }
    ''
}

Test-Case 'a localhost origin (a local dev tool) still works' {
    $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":43,"method":"ping"}' @{ Origin = "http://localhost:5173" })
    if ($r.Code -ne 200) { return "status $($r.Code) — localhost tooling must keep working" }
    ''
}

Test-Case 'no Origin header (a native MCP client) still works' {
    $r = Send-Raw (New-RawPost '{"jsonrpc":"2.0","id":44,"method":"ping"}')
    if ($r.Code -ne 200) { return "status $($r.Code) — native clients send no Origin" }
    ''
}

# ===========================================================================
$http.Dispose()

$passed = @($script:Results | Where-Object Pass).Count
$failed = @($script:Results | Where-Object { -not $_.Pass }).Count
Write-Host ("`n{0}/{1} passed" -f $passed, $script:Results.Count) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
if ($failed) {
    Write-Host "`nFailures:" -ForegroundColor Red
    $script:Results | Where-Object { -not $_.Pass } | ForEach-Object { Write-Host "  - $($_.Name): $($_.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
