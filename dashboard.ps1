# ============================================================
# Local LLM Inference Benchmark - Live Dashboard
#
# Serves a local web UI that lets you:
#   * pick which llama.cpp build (server binary) to run
#   * pick which GGUF model (and optional MTP draft model) to load
#   * configure llama-server launch parameters
#   * watch live GPU telemetry (nvidia-smi) and tokens/sec
#   * run prompts and save benchmark run history
#
# Nothing is hardcoded to a specific machine - all paths are
# parameters and everything is discovered at runtime.
# ============================================================

param(
    # Folder containing one subfolder per llama.cpp build,
    # e.g. C:\Users\<user>\Documents\Llama-Server
    #        \llama-b10586-bin-win-cuda-13.3-x64
    #        \llama-b10662-bin-win-cuda-13.3-x64
    [string]$BuildsDir = "$env:USERPROFILE\Documents\Llama-Server",

    # Root folder that is searched recursively for *.gguf models,
    # e.g. C:\AI\Models\Qwen3.8-27B\Qwen3.8-27B-UD-Q5_K_XL.gguf
    #      C:\AI\Models\Qwen3.8-27B\MTP\<draft model>.gguf
    [string]$ModelsDir = "C:\AI\Models",

    [string]$LlamaHost = "127.0.0.1",
    [int]$LlamaPort    = 8080,

    # Port for this dashboard itself
    [int]$Port         = 8090
)

function Get-AvailableTcpPort {
    param(
        [int]$PreferredPort = 8090,
        [int]$MaxAttempts = 20
    )

    for ($port = $PreferredPort; $port -lt ($PreferredPort + $MaxAttempts); $port++) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
            $listener.Start()
            return $port
        }
        catch {
            continue
        }
        finally {
            if ($listener) { $listener.Stop() }
        }
    }

    throw "No free local TCP port available in the range $PreferredPort-$($PreferredPort + $MaxAttempts - 1)."
}

$Port = Get-AvailableTcpPort -PreferredPort $Port

$ScriptDir           = Split-Path -Parent $MyInvocation.MyCommand.Path
$WebRoot             = Join-Path $ScriptDir "dashboard"
$IndexPath           = Join-Path $WebRoot "index.html"
$LogDir              = Join-Path $ScriptDir "logs"
$ResultsPath         = Join-Path $ScriptDir "benchmark-history.json"
$PromptTemplatesPath = Join-Path $ScriptDir "prompt-templates.json"

try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
}
catch {
    # No-op: the runtime may already have loaded the assembly.
}

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$DefaultPrompt = @"
Review this Python function:

    counts = {}
    for word in words:
        counts[word] = counts.get(word, 0) + 1
    return sorted(counts, key=counts.get, reverse=True)[:k]

It should return the top K most frequent words, ordered by descending frequency and alphabetically for ties.

Identify every correctness issue, provide a corrected implementation with type hints and a docstring, explain time and space complexity, and provide 3 test cases including a frequency tie.
"@

if (-not (Test-Path $PromptTemplatesPath)) {
    $defaultTemplateName = "python-review-template"
    $defaultTemplate = [PSCustomObject]@{
        name      = $defaultTemplateName
        prompt    = $DefaultPrompt
        updatedAt = (Get-Date).ToString("o")
    }
    $defaultTemplate | ConvertTo-Json -Depth 10 | Out-File -FilePath $PromptTemplatesPath -Encoding UTF8
}

# ============================================================
# SHARED STATE (thread-safe across runspaces)
# ============================================================

$Sync = [hashtable]::Synchronized(@{

    Gpu = @{
        name       = "NVIDIA GPU"
        power      = 0
        powerLimit = 0
        temp       = 0
        util       = 0
        memUtil    = 0
        clockSm    = 0
        clockMem   = 0
        pstate     = "--"
        memUsedGB  = 0
        memTotalGB = 0
    }

    Gen = @{
        status      = "idle"     # idle | generating | done | error
        message     = ""
        text        = ""
        tokens      = 0
        tps         = 0.0
        promptTps   = 0.0
        elapsedSec  = 0.0
        ttftSec     = 0.0
        runIndex    = 0
        totalRuns   = 1
        error       = $null
    }

    Server = @{
        status          = "stopped"   # stopped | starting | running | error
        pid             = $null
        build           = $null
        buildPath       = $null
        model           = $null
        modelPath       = $null
        draftModel      = $null
        draftModelPath  = $null
        host            = $LlamaHost
        port            = $LlamaPort
        serverUrl       = "http://${LlamaHost}:${LlamaPort}/v1/chat/completions"
        healthUrl       = "http://${LlamaHost}:${LlamaPort}/health"
        contextSize     = 8192
        gpuLayers       = 999
        specType        = "draft-mtp"
        specDraftNMax   = 4
        reasoningEffort = "medium"
        extraArgs       = ""
        args            = $null
        error           = $null
    }
})

# Live .NET Process handle kept outside $Sync so it is never serialized to JSON.
$Global:ServerProcess = $null
$Global:LlamaServerLock = [System.Threading.Mutex]::new($false, "Local\LocalLlmBenchmark.LlamaServer")
$Global:LlamaServerLockHeld = $false

# ============================================================
# BACKGROUND RUNSPACE HELPER
# ============================================================

function Start-BackgroundRunspace {
    param(
        [scriptblock]$ScriptBlock,
        [hashtable]$Variables = @{}
    )

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()

    foreach ($key in $Variables.Keys) {
        $rs.SessionStateProxy.SetVariable($key, $Variables[$key])
    }

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($ScriptBlock)

    $handle = $ps.BeginInvoke()

    return [PSCustomObject]@{
        PowerShell = $ps
        Runspace   = $rs
        Handle     = $handle
    }
}

function Get-NvidiaGpuModelName {
    try {
        $line = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null |
            Select-Object -First 1

        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return ($line.Trim() -replace '^\s+|\s+$', '')
        }
    }
    catch {
        # no-op; caller will keep the default label
    }

    return "NVIDIA GPU"
}

function Convert-To-DoubleOrDefault {
    param(
        [AllowNull()]
        $Value,

        [double]$Default = 0
    )

    if ($null -eq $Value) { return $Default }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    $trimmed = $text.Trim()
    if ($trimmed -match '^(\[N/A\]|N/A|Unknown|Not Available)$') { return $Default }

    try {
        return [double]$trimmed
    }
    catch {
        return $Default
    }
}

function Update-GpuTelemetryFromNvidiaSmi {
    $query = "timestamp,name,pstate,power.draw,power.default_limit,power.max_limit,power.limit,temperature.gpu,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total"

    try {
        $csvLine = & nvidia-smi --query-gpu=$query --format=csv,noheader,nounits 2>$null |
            Select-Object -First 1

        if (-not $csvLine) { return }

        $parts = @($csvLine -split ',') | ForEach-Object { $_.Trim() }
        $fieldNames = @(
            'timestamp', 'name', 'pstate', 'power.draw', 'power.default_limit', 'power.max_limit', 'power.limit', 'temperature.gpu', 'clocks.sm',
            'clocks.mem', 'utilization.gpu', 'utilization.memory', 'memory.used', 'memory.total'
        )

        $valueMap = @{}
        for ($i = 0; $i -lt $fieldNames.Count; $i++) {
            $valueMap[$fieldNames[$i]] = if ($i -lt $parts.Count) { $parts[$i] } else { '' }
        }

        $gpuName = if (-not [string]::IsNullOrWhiteSpace($valueMap['name'])) { $valueMap['name'] } else { 'NVIDIA GPU' }
        if (-not [string]::IsNullOrWhiteSpace($gpuName)) {
            $Sync.Gpu.name = $gpuName
        }

        $powerDraw = Convert-To-DoubleOrDefault $valueMap['power.draw']
        $powerDefaultLimit = Convert-To-DoubleOrDefault $valueMap['power.default_limit']
        $powerMaxLimit = Convert-To-DoubleOrDefault $valueMap['power.max_limit']
        $powerLimitValue = Convert-To-DoubleOrDefault $valueMap['power.limit']
        $powerLimit = if ($powerLimitValue -gt 0) { $powerLimitValue } elseif ($powerDefaultLimit -gt 0) { $powerDefaultLimit } elseif ($powerMaxLimit -gt 0) { $powerMaxLimit } else { 0 }
        $temperature = Convert-To-DoubleOrDefault $valueMap['temperature.gpu']
        $smClock = Convert-To-DoubleOrDefault $valueMap['clocks.sm']
        $memoryClock = Convert-To-DoubleOrDefault $valueMap['clocks.mem']
        $gpuUtilization = Convert-To-DoubleOrDefault $valueMap['utilization.gpu']
        $memoryUtilization = Convert-To-DoubleOrDefault $valueMap['utilization.memory']
        $memoryUsed = Convert-To-DoubleOrDefault $valueMap['memory.used']
        $memoryTotal = Convert-To-DoubleOrDefault $valueMap['memory.total']

        $Sync.Gpu.pstate     = if (-not [string]::IsNullOrWhiteSpace($valueMap['pstate'])) { $valueMap['pstate'] } else { '--' }
        $Sync.Gpu.power      = [math]::Round($powerDraw, 1)
        $Sync.Gpu.powerLimit = [math]::Round($powerLimit, 1)
        $Sync.Gpu.temp       = [math]::Round($temperature, 1)
        $Sync.Gpu.clockSm    = [math]::Round($smClock, 1)
        $Sync.Gpu.clockMem   = [math]::Round($memoryClock, 1)
        $Sync.Gpu.util       = [math]::Round($gpuUtilization, 1)
        $Sync.Gpu.memUtil    = [math]::Round($memoryUtilization, 1)
        $Sync.Gpu.memUsedGB  = [math]::Round(($memoryUsed / 1024), 2)
        $Sync.Gpu.memTotalGB = [math]::Round(($memoryTotal / 1024), 2)
    }
    catch {
        # nvidia-smi missing or transient failure - keep previous readings
    }
}

# ============================================================
# GPU POLLING LOOP (background runspace)
# ============================================================

$GpuPollScript = {
    $query = "timestamp,name,pstate,power.draw,power.default_limit,power.max_limit,power.limit,temperature.gpu,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,memory.used,memory.total"

    while ($true) {
        try {
            $csvLine = & nvidia-smi --query-gpu=$query --format=csv,noheader,nounits 2>$null |
                Select-Object -First 1

            if ($csvLine) {
                $parts = @($csvLine -split ',') | ForEach-Object { $_.Trim() }
                $fieldNames = @(
                    'timestamp', 'name', 'pstate', 'power.draw', 'power.default_limit', 'power.max_limit', 'power.limit', 'temperature.gpu', 'clocks.sm',
                    'clocks.mem', 'utilization.gpu', 'utilization.memory', 'memory.used', 'memory.total'
                )

                $valueMap = @{}
                for ($i = 0; $i -lt $fieldNames.Count; $i++) {
                    $valueMap[$fieldNames[$i]] = if ($i -lt $parts.Count) { $parts[$i] } else { '' }
                }

                $gpuName = if (-not [string]::IsNullOrWhiteSpace($valueMap['name'])) { $valueMap['name'] } else { 'NVIDIA GPU' }
                if (-not [string]::IsNullOrWhiteSpace($gpuName)) {
                    $Sync.Gpu.name = $gpuName
                }

                $powerDraw = Convert-To-DoubleOrDefault $valueMap['power.draw']
                $powerDefaultLimit = Convert-To-DoubleOrDefault $valueMap['power.default_limit']
                $powerMaxLimit = Convert-To-DoubleOrDefault $valueMap['power.max_limit']
                $powerLimitValue = Convert-To-DoubleOrDefault $valueMap['power.limit']
                $powerLimit = if ($powerLimitValue -gt 0) { $powerLimitValue } elseif ($powerDefaultLimit -gt 0) { $powerDefaultLimit } elseif ($powerMaxLimit -gt 0) { $powerMaxLimit } else { 0 }
                $temperature = Convert-To-DoubleOrDefault $valueMap['temperature.gpu']
                $smClock = Convert-To-DoubleOrDefault $valueMap['clocks.sm']
                $memoryClock = Convert-To-DoubleOrDefault $valueMap['clocks.mem']
                $gpuUtilization = Convert-To-DoubleOrDefault $valueMap['utilization.gpu']
                $memoryUtilization = Convert-To-DoubleOrDefault $valueMap['utilization.memory']
                $memoryUsed = Convert-To-DoubleOrDefault $valueMap['memory.used']
                $memoryTotal = Convert-To-DoubleOrDefault $valueMap['memory.total']

                $Sync.Gpu.pstate     = if (-not [string]::IsNullOrWhiteSpace($valueMap['pstate'])) { $valueMap['pstate'] } else { '--' }
                $Sync.Gpu.power      = [math]::Round($powerDraw, 1)
                $Sync.Gpu.powerLimit = [math]::Round($powerLimit, 1)
                $Sync.Gpu.temp       = [math]::Round($temperature, 1)
                $Sync.Gpu.clockSm    = [math]::Round($smClock, 1)
                $Sync.Gpu.clockMem   = [math]::Round($memoryClock, 1)
                $Sync.Gpu.util       = [math]::Round($gpuUtilization, 1)
                $Sync.Gpu.memUtil    = [math]::Round($memoryUtilization, 1)
                $Sync.Gpu.memUsedGB  = [math]::Round(($memoryUsed / 1024), 2)
                $Sync.Gpu.memTotalGB = [math]::Round(($memoryTotal / 1024), 2)
            }
        }
        catch {
            # nvidia-smi missing or transient failure - keep previous readings
        }

        Start-Sleep -Milliseconds 1000
    }
}

# ============================================================
# PROMPT GENERATION (background runspace, SSE streaming)
# ============================================================

$GenerateScript = {

    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    }
    catch {
        # Keep going; the type may already be available in this runspace.
    }

    $syncRepeatCount = if ($RepeatCount -and [int]$RepeatCount -gt 0) { [int]$RepeatCount } else { 1 }

    $Sync.Gen.status    = "generating"
    $Sync.Gen.message   = "Running benchmark 1/$syncRepeatCount..."
    $Sync.Gen.text      = ""
    $Sync.Gen.tokens    = 0
    $Sync.Gen.tps       = 0.0
    $Sync.Gen.promptTps = 0.0
    $Sync.Gen.elapsedSec = 0.0
    $Sync.Gen.ttftSec   = 0.0
    $Sync.Gen.runIndex  = 0
    $Sync.Gen.totalRuns = $syncRepeatCount
    $Sync.Gen.error     = $null
    $runRecords = @()

    for ($runIndex = 1; $runIndex -le $syncRepeatCount; $runIndex++) {

        $Sync.Gen.runIndex = $runIndex
        $Sync.Gen.message = "Running benchmark $runIndex/$syncRepeatCount..."
        $Sync.Gen.text = "=== Benchmark run $runIndex/$syncRepeatCount ===`n`nPrompt:`n$Prompt`n`n--- model output ---`n"

        $bodyObj = @{
            model = $Model
            messages = @(
                @{ role = "system"; content = $SystemPrompt },
                @{ role = "user";   content = $Prompt }
            )
            max_tokens  = $MaxTokens
            temperature = $Temperature
            stream      = $true
        }

        $json = $bodyObj | ConvertTo-Json -Depth 10

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tokenCount = 0
        $firstTokenAt = $null
        $timings = $null

        try {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $client  = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [System.TimeSpan]::FromMinutes(30)

            $content = New-Object System.Net.Http.StringContent(
                $json, [System.Text.Encoding]::UTF8, "application/json")

            $request = New-Object System.Net.Http.HttpRequestMessage(
                [System.Net.Http.HttpMethod]::Post, $ServerUrl)
            $request.Content = $content

            $response = $client.SendAsync(
                $request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

            if (-not $response.IsSuccessStatusCode) {
                throw "Server returned HTTP $([int]$response.StatusCode) $($response.StatusCode)"
            }

            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $reader = New-Object System.IO.StreamReader($stream)

            while (-not $reader.EndOfStream) {

                $line = $reader.ReadLine()

                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if (-not $line.StartsWith("data:"))      { continue }

                $payload = $line.Substring(5).Trim()

                if ($payload -eq "[DONE]") { break }

                try   { $chunk = $payload | ConvertFrom-Json }
                catch { continue }

                if ($chunk.PSObject.Properties.Name -contains "timings" -and $chunk.timings) {
                    $timings = $chunk.timings
                }

                $delta = $chunk.choices[0].delta.content

                if ($delta) {

                    if ($null -eq $firstTokenAt) {
                        $firstTokenAt = $sw.Elapsed.TotalSeconds
                        $Sync.Gen.ttftSec = [math]::Round($firstTokenAt, 3)
                    }

                    $Sync.Gen.text += $delta
                    $tokenCount += 1
                    $Sync.Gen.tokens = $tokenCount

                    $elapsedSec = $sw.Elapsed.TotalSeconds
                    $Sync.Gen.elapsedSec = [math]::Round($elapsedSec, 2)

                    if ($elapsedSec -gt 0) {
                        $Sync.Gen.tps = [math]::Round($tokenCount / $elapsedSec, 2)
                    }
                }
            }

            $reader.Dispose()
            $client.Dispose()
            $sw.Stop()

            $finalTps      = $Sync.Gen.tps
            $finalTokens   = $tokenCount
            $promptTps     = 0.0
            $promptTokens  = 0
            $acceptancePct = $null

            if ($timings) {
                if ($timings.predicted_per_second) { $finalTps    = [math]::Round($timings.predicted_per_second, 2) }
                if ($timings.predicted_n)          { $finalTokens = $timings.predicted_n }
                if ($timings.prompt_per_second)    { $promptTps   = [math]::Round($timings.prompt_per_second, 2) }
                if ($timings.prompt_n)             { $promptTokens = $timings.prompt_n }

                if ($timings.draft_n -and $timings.draft_n -gt 0) {
                    $acceptancePct = [math]::Round(
                        ($timings.draft_n_accepted / $timings.draft_n) * 100, 2)
                }
            }

            $Sync.Gen.tps       = $finalTps
            $Sync.Gen.tokens    = $finalTokens
            $Sync.Gen.promptTps = $promptTps

            $record = [PSCustomObject]@{
                id              = [guid]::NewGuid().ToString()
                timestamp       = (Get-Date).ToString("s")
                build           = $Sync.Server.build
                model           = $Sync.Server.model
                draftModel      = $Sync.Server.draftModel
                contextSize     = $Sync.Server.contextSize
                gpuLayers       = $Sync.Server.gpuLayers
                specType        = $Sync.Server.specType
                specDraftNMax   = $Sync.Server.specDraftNMax
                reasoningEffort = $Sync.Server.reasoningEffort
                gpuName         = $Sync.Gpu.name
                tps             = $finalTps
                tokens          = $finalTokens
                promptTps       = $promptTps
                promptTokens    = $promptTokens
                acceptancePct   = $acceptancePct
                ttftSec         = $Sync.Gen.ttftSec
                elapsedSec      = [math]::Round($sw.Elapsed.TotalSeconds, 2)
                peakPowerW      = $Sync.Gpu.power
                peakTempC       = $Sync.Gpu.temp
                vramUsedGB      = $Sync.Gpu.memUsedGB
                prompt          = $Prompt
                repeatRuns      = $syncRepeatCount
                runIndex        = $runIndex
                totalRuns       = $syncRepeatCount
            }

            $runRecords += $record

            if ($runIndex -lt $syncRepeatCount) {
                Start-Sleep -Milliseconds 300
            }
        }
        catch {
            $Sync.Gen.status = "error"
            $Sync.Gen.message = "Benchmark failed on run $runIndex/$syncRepeatCount."
            $Sync.Gen.error = $_.Exception.Message
            $Sync.Gen.text += "`n`n[ERROR] $($_.Exception.Message)"
            break
        }
    }

    if ($Sync.Gen.status -ne "error") {
        try {
            $average = {
                param([string]$PropertyName)
                $values = @($runRecords | ForEach-Object { $_.$PropertyName } |
                    Where-Object { $null -ne $_ -and $_ -ne "" } |
                    ForEach-Object { [double]$_ })
                if ($values.Count -eq 0) { return $null }
                return [math]::Round((($values | Measure-Object -Average).Average), 2)
            }

            $groupRecord = [PSCustomObject]@{
                id              = [guid]::NewGuid().ToString()
                timestamp       = (Get-Date).ToString("s")
                build           = $runRecords[0].build
                model           = $runRecords[0].model
                draftModel      = $runRecords[0].draftModel
                contextSize     = $runRecords[0].contextSize
                gpuLayers       = $runRecords[0].gpuLayers
                specType        = $runRecords[0].specType
                specDraftNMax   = $runRecords[0].specDraftNMax
                reasoningEffort = $runRecords[0].reasoningEffort
                gpuName         = $runRecords[0].gpuName
                tps             = & $average "tps"
                tokens          = & $average "tokens"
                promptTps       = & $average "promptTps"
                promptTokens    = & $average "promptTokens"
                acceptancePct   = & $average "acceptancePct"
                ttftSec         = & $average "ttftSec"
                elapsedSec      = & $average "elapsedSec"
                peakPowerW      = & $average "peakPowerW"
                peakTempC       = & $average "peakTempC"
                vramUsedGB      = & $average "vramUsedGB"
                prompt          = $runRecords[0].prompt
                repeatRuns      = $runRecords.Count
                runIndex        = 1
                totalRuns       = $runRecords.Count
                runs            = @($runRecords)
            }

            $history = @()
            if (Test-Path -LiteralPath $ResultsPath) {
                $rawHistory = Get-Content -LiteralPath $ResultsPath -Raw -Encoding UTF8
                if (-not [string]::IsNullOrWhiteSpace($rawHistory)) {
                    $parsedHistory = $rawHistory | ConvertFrom-Json
                    $history = @($parsedHistory)
                }
            }

            $history += $groupRecord
            $historyJson = ConvertTo-Json -InputObject ([object[]]$history) -Depth 50
            $resultsDirectory = Split-Path -Parent -Path $ResultsPath
            if ($resultsDirectory -and -not (Test-Path -LiteralPath $resultsDirectory)) {
                New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
            }
            [System.IO.File]::WriteAllText(
                $ResultsPath,
                $historyJson,
                [System.Text.UTF8Encoding]::new($false))
        }
        catch {
            $Sync.Gen.error = "History persistence failed: $($_.Exception.Message)"
            $Sync.Gen.message = "Benchmark complete, but history could not be saved."
        }

        $Sync.Gen.status = "done"
        $Sync.Gen.message = "Benchmark complete ($syncRepeatCount run(s))."
    }
}

# ============================================================
# DISCOVERY: llama.cpp BUILDS
# ============================================================

function Get-LlamaBuilds {
    param([string]$Directory)

    if (-not (Test-Path -Path $Directory)) { return @() }

    $results = @()

    # Each build is normally a subfolder containing llama-server.exe.
    Get-ChildItem -Path $Directory -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {

            $exe = Join-Path $_.FullName "llama-server.exe"

            if (Test-Path $exe) {
                $results += [PSCustomObject]@{
                    name    = $_.Name
                    path    = $exe
                    dir     = $_.FullName
                    version = (Get-Item $exe).VersionInfo.FileVersion
                }
            }
        }

    # Also allow a llama-server.exe sitting directly in the builds folder.
    $rootExe = Join-Path $Directory "llama-server.exe"
    if (Test-Path $rootExe) {
        $results += [PSCustomObject]@{
            name    = Split-Path -Leaf $Directory
            path    = $rootExe
            dir     = $Directory
            version = (Get-Item $rootExe).VersionInfo.FileVersion
        }
    }

    return $results | Sort-Object name
}

# ============================================================
# DISCOVERY: GGUF MODELS
# ============================================================

function Get-GgufModels {
    param([string]$Directory)

    if (-not (Test-Path -Path $Directory)) { return @() }

    # Resolve to the canonical full path so relative-path trimming is exact
    # (handles 8.3 short names, trailing slashes and relative inputs).
    $rootFull = (Get-Item -LiteralPath $Directory).FullName.TrimEnd('\')

    Get-ChildItem -LiteralPath $rootFull -Filter "*.gguf" -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {

            $full = $_.FullName
            $relative = if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                $full.Substring($rootFull.Length).TrimStart('\')
            } else {
                $_.Name
            }

            [PSCustomObject]@{
                name     = $_.Name
                relative = $relative
                path     = $full
                folder   = Split-Path -Leaf $_.DirectoryName
                sizeGB   = [math]::Round($_.Length / 1GB, 2)
                # Models under a folder named "MTP"/"draft" are draft-model candidates
                isDraft  = ($_.DirectoryName -match '\\(MTP|draft)$')
            }
        } | Sort-Object relative
}

# ============================================================
# LLAMA-SERVER PROCESS MANAGEMENT
# ============================================================

function Update-ServerStatusFromProcess {

    if (-not $Global:ServerProcess) { return }

    if ($Global:ServerProcess.HasExited) {

        if ($Sync.Server.status -ne "stopped") {
            $Sync.Server.status = "error"
            $Sync.Server.error  = "llama-server exited (code $($Global:ServerProcess.ExitCode)). See logs\llama-server.err.log."
        }

        $Global:ServerProcess = $null
        $Sync.Server.pid = $null
        if ($Global:LlamaServerLockHeld) {
            $Global:LlamaServerLock.ReleaseMutex()
            $Global:LlamaServerLockHeld = $false
        }
    }
    elseif ($Sync.Server.status -eq "starting") {
        $Sync.Server.status = "running"
    }
}

function Start-LlamaServer {
    param(
        [string]$BuildPath,
        [string]$ModelPath,
        [string]$DraftModelPath,
        [int]$ContextSize,
        [int]$GpuLayers,
        [string]$SpecType,
        [int]$SpecDraftNMax,
        [string]$ReasoningEffort,
        [string]$ExtraArgs,
        [string]$TargetHost,
        [int]$TargetPort
    )

    if ($Global:ServerProcess -and -not $Global:ServerProcess.HasExited) {
        return @{ ok = $false; message = "llama-server is already running. Stop it first." }
    }
    if ($Global:ServerProcess -and $Global:ServerProcess.HasExited -and $Global:LlamaServerLockHeld) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
    }

    $otherServer = Get-Process -Name "llama-server" -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID } |
        Select-Object -First 1
    if ($otherServer) {
        return @{ ok = $false; message = "Another llama-server is already running (PID $($otherServer.Id)). Stop it first." }
    }

    try {
        if (-not $Global:LlamaServerLock.WaitOne(0)) {
            return @{ ok = $false; message = "Another dashboard is already starting or running llama-server. Stop it first." }
        }
        $Global:LlamaServerLockHeld = $true
    }
    catch {
        return @{ ok = $false; message = "Could not acquire the llama-server start lock: $($_.Exception.Message)" }
    }

    if (-not (Test-Path -Path $BuildPath)) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
        return @{ ok = $false; message = "llama-server executable not found: $BuildPath" }
    }

    if (-not (Test-Path -Path $ModelPath)) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
        return @{ ok = $false; message = "Model file not found: $ModelPath" }
    }

    if ($DraftModelPath -and -not (Test-Path -Path $DraftModelPath)) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
        return @{ ok = $false; message = "Draft model file not found: $DraftModelPath" }
    }

    $argsList = @(
        "-m", "`"$ModelPath`"",
        "-c", $ContextSize,
        "-ngl", $GpuLayers,
        "--host", $TargetHost,
        "--port", $TargetPort
    )

    if ($SpecType -and $SpecType -ne "none") {
        $argsList += @("--spec-type", $SpecType, "--spec-draft-n-max", $SpecDraftNMax)
    }

    if ($DraftModelPath) {
        $argsList += @("-md", "`"$DraftModelPath`"")
    }

    if ($ExtraArgs) {
        $argsList += ($ExtraArgs -split '\s+' | Where-Object { $_ })
    }

    # llama-server reads reasoning effort from this env var.
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS =
        (@{ reasoning_effort = $ReasoningEffort } | ConvertTo-Json -Compress)

    $outLog = Join-Path $LogDir "llama-server.out.log"
    $errLog = Join-Path $LogDir "llama-server.err.log"

    try {
        $proc = Start-Process -FilePath $BuildPath -ArgumentList $argsList `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
            -WindowStyle Hidden -PassThru

        $Global:ServerProcess = $proc

        $Sync.Server.status          = "starting"
        $Sync.Server.pid             = $proc.Id
        $Sync.Server.build           = Split-Path -Leaf (Split-Path -Parent $BuildPath)
        $Sync.Server.buildPath       = $BuildPath
        $Sync.Server.model           = Split-Path -Leaf $ModelPath
        $Sync.Server.modelPath       = $ModelPath
        $Sync.Server.draftModel      = if ($DraftModelPath) { Split-Path -Leaf $DraftModelPath } else { $null }
        $Sync.Server.draftModelPath  = $DraftModelPath
        $Sync.Server.host            = $TargetHost
        $Sync.Server.port            = $TargetPort
        $Sync.Server.serverUrl       = "http://${TargetHost}:${TargetPort}/v1/chat/completions"
        $Sync.Server.healthUrl       = "http://${TargetHost}:${TargetPort}/health"
        $Sync.Server.contextSize     = $ContextSize
        $Sync.Server.gpuLayers       = $GpuLayers
        $Sync.Server.specType        = $SpecType
        $Sync.Server.specDraftNMax   = $SpecDraftNMax
        $Sync.Server.reasoningEffort = $ReasoningEffort
        $Sync.Server.extraArgs       = $ExtraArgs
        $Sync.Server.args            = "$BuildPath $($argsList -join ' ')"
        $Sync.Server.error           = $null
        $Sync.Gen.status             = "idle"
        $Sync.Gen.message            = "Server starting..."
        $Sync.Gen.text               = ""
        $Sync.Gen.tokens             = 0
        $Sync.Gen.tps                = 0.0
        $Sync.Gen.promptTps          = 0.0
        $Sync.Gen.elapsedSec         = 0.0
        $Sync.Gen.ttftSec             = 0.0
        $Sync.Gen.runIndex           = 0
        $Sync.Gen.totalRuns          = 1
        $Sync.Gen.error              = $null

        return @{ ok = $true; message = "llama-server starting (PID $($proc.Id))." }
    }
    catch {
        if ($Global:LlamaServerLockHeld) {
            $Global:LlamaServerLock.ReleaseMutex()
            $Global:LlamaServerLockHeld = $false
        }
        $Sync.Server.status = "error"
        $Sync.Server.error  = $_.Exception.Message
        return @{ ok = $false; message = "Failed to start llama-server: $($_.Exception.Message)" }
    }
}

function Stop-LlamaServer {

    if (-not $Global:ServerProcess -or $Global:ServerProcess.HasExited) {
        $Global:ServerProcess = $null
        $Sync.Server.status = "stopped"
        $Sync.Server.pid    = $null
        if ($Global:LlamaServerLockHeld) {
            $Global:LlamaServerLock.ReleaseMutex()
            $Global:LlamaServerLockHeld = $false
        }
        return @{ ok = $false; message = "llama-server is not running." }
    }

    try { Stop-Process -Id $Global:ServerProcess.Id -Force }
    catch { }

    $Global:ServerProcess = $null
    $Sync.Server.status = "stopped"
    $Sync.Server.pid    = $null
    if ($Global:LlamaServerLockHeld) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
    }

    return @{ ok = $true; message = "llama-server stopped." }
}

function Stop-GpuProcesses {
    $gpuPids = @()

    try {
        $gpuOut = & nvidia-smi --query-compute-apps=pid,name --format=csv,noheader 2>$null
        foreach ($line in $gpuOut) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split ',', 2
            $pid = $parts[0].Trim()
            if ($pid -match '^\d+$') { $gpuPids += [int]$pid }
        }
    }
    catch {
        $gpuPids = @()
    }

    if (-not $gpuPids.Count) {
        return @{ ok = $true; message = "No GPU-using processes were found."; stopped = @() }
    }

    $stopped = @()
    foreach ($pid in ($gpuPids | Sort-Object -Unique)) {
        if ($pid -eq $PID) { continue }
        try {
            Stop-Process -Id $pid -Force -ErrorAction Stop
            $stopped += $pid
        }
        catch { }
    }

    if ($Global:ServerProcess -and -not $Global:ServerProcess.HasExited) {
        try {
            Stop-Process -Id $Global:ServerProcess.Id -Force -ErrorAction Stop
            $Global:ServerProcess = $null
            $Sync.Server.status = "stopped"
            $Sync.Server.pid = $null
            if ($Global:LlamaServerLockHeld) {
                $Global:LlamaServerLock.ReleaseMutex()
                $Global:LlamaServerLockHeld = $false
            }
        }
        catch { }
    }

    $message = if ($stopped.Count) {
        "Stopped GPU memory users: $($stopped -join ', ')"
    }
    else {
        "No active GPU processes were stopped."
    }

    return @{ ok = ($stopped.Count -gt 0); message = $message; stopped = $stopped }
}

# ============================================================
# BENCHMARK HISTORY
# ============================================================

function Flatten-HistoryEntries {
    param([object]$Value)

    $items = [System.Collections.Generic.List[object]]::new()

    function Add-Entry {
        param([object]$Entry)

        if ($null -eq $Entry) { return }

        if ($Entry -is [System.Collections.IEnumerable] -and -not ($Entry -is [string])) {
            foreach ($item in @($Entry)) { Add-Entry -Entry $item }
            return
        }

        if ($Entry.PSObject.Properties.Name -contains "value") {
            $nested = $Entry.value
            if ($nested -ne $null) {
                if ($nested -is [System.Collections.IEnumerable] -and -not ($nested -is [string])) {
                    foreach ($item in @($nested)) { Add-Entry -Entry $item }
                    return
                }
                if ($nested -is [pscustomobject] -or $nested -is [hashtable]) {
                    Add-Entry -Entry $nested
                    return
                }
            }
        }

        $items.Add($Entry)
    }

    if ($null -ne $Value) {
        foreach ($item in @($Value)) { Add-Entry -Entry $item }
    }

    return @($items)
}

function Get-BenchmarkHistory {

    if (-not (Test-Path $ResultsPath)) { return @() }

    try {
        $raw = Get-Content -Path $ResultsPath -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @() }

        $parsed = $raw | ConvertFrom-Json
        $entries = @(Flatten-HistoryEntries -Value $parsed)
        return @($entries | Where-Object { $_ -ne $null })
    }
    catch {
        return @()
    }
}

function Save-BenchmarkHistory {
    param([object[]]$Entries)

    $safeEntries = @(Flatten-HistoryEntries -Value $Entries)
    $safeEntries | ConvertTo-Json -Depth 50 | Out-File -FilePath $ResultsPath -Encoding UTF8
    return @{ ok = $true; count = $safeEntries.Count; path = $ResultsPath }
}

function Get-PromptTemplates {

    if (-not (Test-Path $PromptTemplatesPath)) { return @() }

    try {
        $raw = Get-Content -Path $PromptTemplatesPath -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @() }
        return @($raw | ConvertFrom-Json)
    }
    catch {
        return @()
    }
}

function Save-PromptTemplate {
    param(
        [string]$TemplateName,
        [string]$PromptText
    )

    if ([string]::IsNullOrWhiteSpace($TemplateName)) {
        return @{ ok = $false; message = "Template name is required." }
    }
    if ([string]::IsNullOrWhiteSpace($PromptText)) {
        return @{ ok = $false; message = "Prompt text is required." }
    }

    $templates = @(Get-PromptTemplates)
    $updated = @()
    $found = $false

    foreach ($template in $templates) {
        if ($template.name -ieq $TemplateName) {
            $updated += [PSCustomObject]@{
                name      = $TemplateName
                prompt    = $PromptText
                updatedAt = (Get-Date).ToString("o")
            }
            $found = $true
        }
        else {
            $updated += $template
        }
    }

    if (-not $found) {
        $updated += [PSCustomObject]@{
            name      = $TemplateName
            prompt    = $PromptText
            updatedAt = (Get-Date).ToString("o")
        }
    }

    $updated | ConvertTo-Json -Depth 10 | Out-File -FilePath $PromptTemplatesPath -Encoding UTF8

    return @{ ok = $true; message = "Template saved: $TemplateName"; templates = $updated }
}

function Get-HistoryItemId {
    param([object]$Entry)

    if ($null -eq $Entry) { return $null }

    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.ContainsKey('id')) { return [string]$Entry['id'] }
    }
    elseif ($Entry.PSObject -and $Entry.PSObject.Properties.Name -contains 'id') {
        if ($null -ne $Entry.id) { return [string]$Entry.id }
    }

    return Get-HistoryRowKey -Entry $Entry
}

function Get-HistoryRowKey {
    param([object]$Entry)

    if ($null -eq $Entry) { return $null }

    $timestamp = if ($null -ne $Entry.timestamp) { [string]$Entry.timestamp } else { '' }
    $build = if ($null -ne $Entry.build) { [string]$Entry.build } else { '' }
    $model = if ($null -ne $Entry.model) { [string]$Entry.model } else { '' }
    $runIndex = if ($null -ne $Entry.runIndex) { [string]$Entry.runIndex } else { '1' }

    $hasRunsProp = $false
    if ($Entry -is [System.Collections.IDictionary]) {
        $hasRunsProp = $Entry.ContainsKey('runs')
    }
    elseif ($Entry.PSObject -and $Entry.PSObject.Properties.Name -contains 'runs') {
        $hasRunsProp = $true
    }

    if ($null -ne $Entry.totalRuns) {
        $totalRuns = [string]$Entry.totalRuns
    }
    elseif ($hasRunsProp) {
        $totalRuns = [string]@($Entry.runs).Count
    }
    else {
        $totalRuns = '1'
    }

    return "$timestamp|$build|$model|$runIndex|$totalRuns"
}

function Delete-BenchmarkHistoryByKeys {
    param([string[]]$Keys)

    $selectedKeys = @($Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not $selectedKeys.Count) {
        return @{ ok = $true; message = "No history entries selected."; deleted = 0 }
    }

    if (-not (Test-Path $ResultsPath)) {
        return @{ ok = $true; message = "No history file found."; deleted = 0 }
    }

    try {
        $raw = Get-Content -Path $ResultsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw.Trim())) {
            return @{ ok = $true; message = "History file is empty."; deleted = 0 }
        }

        $history = @($raw | ConvertFrom-Json)
        $deleted = 0
        $filtered = @()

        foreach ($entry in $history) {
            $entryId = Get-HistoryItemId -Entry $entry
            if ($selectedKeys -contains $entryId) {
                $deleted += 1
                continue
            }

            $hasRunsProp = $false
            if ($entry -and $entry -is [System.Collections.IDictionary]) {
                $hasRunsProp = $entry.ContainsKey('runs')
            }
            elseif ($entry -and $entry.PSObject -and $entry.PSObject.Properties.Name -contains 'runs') {
                $hasRunsProp = $true
            }

            if ($hasRunsProp) {
                $runs = @($entry.runs)
                $remainingRuns = @()

                foreach ($run in $runs) {
                    $runId = Get-HistoryItemId -Entry $run
                    if ($selectedKeys -contains $runId) {
                        $deleted += 1
                        continue
                    }
                    $remainingRuns += $run
                }

                if ($remainingRuns.Count -gt 0) {
                    $entryProps = [ordered]@{}
                    foreach ($prop in $entry.PSObject.Properties) {
                        $entryProps[$prop.Name] = $prop.Value
                    }
                    $entryProps['runs'] = $remainingRuns
                    $filtered += [pscustomobject]$entryProps
                }
                continue
            }

            $filtered += $entry
        }

        if ($filtered.Count -eq $history.Count) {
            $allKeys = @()
            foreach ($entry in $history) {
                $allKeys += Get-HistoryRowKey -Entry $entry
                if ($entry -and $entry.runs) {
                    foreach ($run in @($entry.runs)) {
                        $allKeys += Get-HistoryRowKey -Entry $run
                    }
                }
            }
            $matched = @($selectedKeys | Where-Object { $allKeys -contains $_ })
            if (-not $matched.Count) {
                return @{ ok = $true; message = "No matching history entries found."; deleted = 0 }
            }
        }

        $filtered | ConvertTo-Json -Depth 50 | Out-File -FilePath $ResultsPath -Encoding UTF8
        return @{ ok = $true; message = "Deleted $deleted selected benchmark record(s)."; deleted = $deleted }
    }
    catch {
        return @{ ok = $false; message = "Failed to delete selected history entries: $($_.Exception.Message)"; deleted = 0 }
    }
}

function Clear-BenchmarkHistory {
    if (Test-Path $ResultsPath) { Remove-Item $ResultsPath -Force }
    return @{ ok = $true; message = "Benchmark history cleared." }
}

# ============================================================
# STARTUP
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "LOCAL LLM INFERENCE DASHBOARD"
Write-Host "============================================================"
Write-Host "Builds dir:  $BuildsDir"
Write-Host "Models dir:  $ModelsDir"
Write-Host "Dashboard:   http://localhost:$Port/"
Write-Host "History:     $ResultsPath"
Write-Host ""

$nvidiaSmiOk = $true
try {
    & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $nvidiaSmiOk = $false }
}
catch { $nvidiaSmiOk = $false }

if (-not $nvidiaSmiOk) {
    Write-Host "WARNING: nvidia-smi unavailable - GPU stats will read 0." -ForegroundColor Yellow
}
else {
    $Sync.Gpu.name = Get-NvidiaGpuModelName
}

$gpuJob = Start-BackgroundRunspace -ScriptBlock $GpuPollScript -Variables @{ Sync = $Sync }

# ============================================================
# HTTP SERVER
# ============================================================

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")

try {
    $listener.Start()
}
catch {
    Write-Host "ERROR: Could not bind port $Port (already in use?)." -ForegroundColor Red
    Write-Host $_
    exit 1
}

Write-Host "Dashboard running. Open http://localhost:$Port/  (Ctrl+C to stop)"
Write-Host ""

$activeGenJob = $null

function Write-JsonResponse {
    param($Context, [object]$Obj, [int]$StatusCode = 200)

    $json  = $Obj | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $Context.Response.StatusCode      = $StatusCode
    $Context.Response.ContentType     = "application/json"
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-RequestBody {
    param($Request)

    $reader   = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    $bodyText = $reader.ReadToEnd()
    $reader.Dispose()
    return $bodyText
}

try {
    while ($listener.IsListening) {

        $context  = $listener.GetContext()
        $request  = $context.Request
        $response = $context.Response
        $path     = $request.Url.AbsolutePath
        $method   = $request.HttpMethod

        try {

            # ---------- static page ----------
            if ($method -eq "GET" -and ($path -eq "/" -or $path -eq "/index.html")) {

                $html  = Get-Content -Path $IndexPath -Raw -Encoding UTF8
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)

                $response.ContentType     = "text/html; charset=utf-8"
                $response.ContentLength64 = $bytes.Length
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
            }

            # ---------- live state ----------
            elseif ($method -eq "GET" -and $path -eq "/api/state") {

                Update-ServerStatusFromProcess
                Update-GpuTelemetryFromNvidiaSmi

                Write-JsonResponse -Context $context -Obj @{
                    gpu = @{
                        name       = $Sync.Gpu.name
                        power      = $Sync.Gpu.power
                        powerLimit = $Sync.Gpu.powerLimit
                        temp       = $Sync.Gpu.temp
                        util       = $Sync.Gpu.util
                        memUtil    = $Sync.Gpu.memUtil
                        clockSm    = $Sync.Gpu.clockSm
                        clockMem   = $Sync.Gpu.clockMem
                        pstate     = $Sync.Gpu.pstate
                        memUsedGB  = $Sync.Gpu.memUsedGB
                        memTotalGB = $Sync.Gpu.memTotalGB
                    }
                    gen = @{
                        status     = $Sync.Gen.status
                        message    = $Sync.Gen.message
                        text       = $Sync.Gen.text
                        tokens     = $Sync.Gen.tokens
                        tps        = $Sync.Gen.tps
                        promptTps  = $Sync.Gen.promptTps
                        elapsedSec = $Sync.Gen.elapsedSec
                        ttftSec    = $Sync.Gen.ttftSec
                        runIndex   = $Sync.Gen.runIndex
                        totalRuns  = $Sync.Gen.totalRuns
                        error      = $Sync.Gen.error
                    }
                    server = @{
                        status          = $Sync.Server.status
                        pid             = $Sync.Server.pid
                        build           = $Sync.Server.build
                        model           = $Sync.Server.model
                        draftModel      = $Sync.Server.draftModel
                        host            = $Sync.Server.host
                        port            = $Sync.Server.port
                        serverUrl       = $Sync.Server.serverUrl
                        contextSize     = $Sync.Server.contextSize
                        gpuLayers       = $Sync.Server.gpuLayers
                        specType        = $Sync.Server.specType
                        specDraftNMax   = $Sync.Server.specDraftNMax
                        reasoningEffort = $Sync.Server.reasoningEffort
                        args            = $Sync.Server.args
                        error           = $Sync.Server.error
                    }
                }
            }

            # ---------- discover llama.cpp builds ----------
            elseif ($method -eq "GET" -and $path -eq "/api/builds") {

                $dir = $request.QueryString["dir"]
                if ($dir) { $BuildsDir = $dir } else { $dir = $BuildsDir }

                $builds = @(Get-LlamaBuilds -Directory $dir)

                Write-JsonResponse -Context $context -Obj @{
                    ok     = $true
                    dir    = $dir
                    builds = $builds
                }
            }

            # ---------- discover gguf models ----------
            elseif ($method -eq "GET" -and $path -eq "/api/models") {

                $dir = $request.QueryString["dir"]
                if ($dir) { $ModelsDir = $dir } else { $dir = $ModelsDir }

                $models = @(Get-GgufModels -Directory $dir)

                Write-JsonResponse -Context $context -Obj @{
                    ok     = $true
                    dir    = $dir
                    models = $models
                }
            }

            # ---------- start llama-server ----------
            elseif ($method -eq "POST" -and $path -eq "/api/server/start") {

                $parsed = $null
                try { $parsed = (Read-RequestBody -Request $request) | ConvertFrom-Json } catch { }

                if (-not $parsed -or -not $parsed.buildPath -or -not $parsed.modelPath) {
                    Write-JsonResponse -Context $context -Obj @{
                        ok = $false; message = "buildPath and modelPath are required."
                    }
                }
                else {
                    $result = Start-LlamaServer `
                        -BuildPath       $parsed.buildPath `
                        -ModelPath       $parsed.modelPath `
                        -DraftModelPath  $(if ($parsed.draftModelPath) { [string]$parsed.draftModelPath } else { $null }) `
                        -ContextSize     $(if ($parsed.contextSize)     { [int]$parsed.contextSize }        else { 8192 }) `
                        -GpuLayers       $(if ($null -ne $parsed.gpuLayers) { [int]$parsed.gpuLayers }      else { 999 }) `
                        -SpecType        $(if ($parsed.specType)        { [string]$parsed.specType }        else { "draft-mtp" }) `
                        -SpecDraftNMax   $(if ($parsed.specDraftNMax)   { [int]$parsed.specDraftNMax }      else { 4 }) `
                        -ReasoningEffort $(if ($parsed.reasoningEffort) { [string]$parsed.reasoningEffort } else { "medium" }) `
                        -ExtraArgs       $(if ($parsed.extraArgs)       { [string]$parsed.extraArgs }       else { "" }) `
                        -TargetHost      $(if ($parsed.host)            { [string]$parsed.host }            else { $LlamaHost }) `
                        -TargetPort      $(if ($parsed.port)            { [int]$parsed.port }               else { $LlamaPort })

                    Write-JsonResponse -Context $context -Obj $result
                }
            }

            # ---------- stop llama-server ----------
            elseif ($method -eq "POST" -and $path -eq "/api/server/stop") {

                Write-JsonResponse -Context $context -Obj (Stop-LlamaServer)
            }

            # ---------- offload all GPU-using processes ----------
            elseif ($method -eq "POST" -and $path -eq "/api/gpu/offload") {

                Write-JsonResponse -Context $context -Obj (Stop-GpuProcesses)
            }

            # ---------- run a prompt ----------
            elseif ($method -eq "POST" -and $path -eq "/api/generate") {

                $parsed = $null
                try { $parsed = (Read-RequestBody -Request $request) | ConvertFrom-Json } catch { }

                $prompt = if ($parsed -and $parsed.prompt) { [string]$parsed.prompt } else { $DefaultPrompt }
                $repeatCount = if ($parsed -and $null -ne $parsed.repeatRuns) { [int]$parsed.repeatRuns }
                               elseif ($parsed -and $null -ne $parsed.repeatCount) { [int]$parsed.repeatCount }
                               else { 1 }
                if ($repeatCount -lt 1) { $repeatCount = 1 }

                if ($Sync.Gen.status -eq "generating") {

                    Write-JsonResponse -Context $context -Obj @{
                        ok = $false; message = "A generation is already in progress."
                    }
                }
                elseif ($Sync.Server.status -ne "running" -and $Sync.Server.status -ne "starting") {

                    Write-JsonResponse -Context $context -Obj @{
                        ok = $false; message = "Start llama-server before running a prompt."
                    }
                }
                else {
                    $activeGenJob = Start-BackgroundRunspace -ScriptBlock $GenerateScript -Variables @{
                        Sync         = $Sync
                        Prompt       = $prompt
                        SystemPrompt = $(if ($parsed -and $parsed.systemPrompt) { [string]$parsed.systemPrompt }
                                         else { "You are an expert engineer. Be precise, skeptical, and concise." })
                        MaxTokens    = $(if ($parsed -and $parsed.maxTokens)   { [int]$parsed.maxTokens }      else { 1500 })
                        Temperature  = $(if ($parsed -and $null -ne $parsed.temperature) { [double]$parsed.temperature } else { 0.2 })
                        RepeatCount  = $repeatCount
                        Model        = $(if ($Sync.Server.model) { $Sync.Server.model } else { "default" })
                        ServerUrl    = $Sync.Server.serverUrl
                        ResultsPath  = $ResultsPath
                    }

                    Write-JsonResponse -Context $context -Obj @{
                        ok = $true; message = "Generation started ($repeatCount run(s))."
                    }
                }
            }

            # ---------- prompt templates ----------
            elseif ($method -eq "GET" -and $path -eq "/api/templates") {

                $selectedName = $request.QueryString["name"]
                $templates = @(Get-PromptTemplates)

                if ($selectedName) {
                    $selected = $templates | Where-Object { $_.name -ieq $selectedName } | Select-Object -First 1
                    Write-JsonResponse -Context $context -Obj @{ ok = $true; template = $selected; templates = $templates }
                }
                else {
                    Write-JsonResponse -Context $context -Obj @{ ok = $true; templates = $templates }
                }
            }
            elseif ($method -eq "POST" -and $path -eq "/api/templates") {

                $parsed = $null
                try { $parsed = (Read-RequestBody -Request $request) | ConvertFrom-Json } catch { }

                if (-not $parsed -or -not $parsed.name) {
                    Write-JsonResponse -Context $context -Obj @{ ok = $false; message = "Template name is required." }
                }
                else {
                    $result = Save-PromptTemplate -TemplateName $parsed.name -PromptText $parsed.prompt
                    Write-JsonResponse -Context $context -Obj $result
                }
            }

            # ---------- benchmark history ----------
            elseif ($method -eq "GET" -and $path -eq "/api/history") {

                Write-JsonResponse -Context $context -Obj @{
                    ok = $true; runs = @(Get-BenchmarkHistory)
                }
            }

            elseif ($method -eq "POST" -and $path -eq "/api/history/delete") {

                $parsed = $null
                try { $parsed = (Read-RequestBody -Request $request) | ConvertFrom-Json } catch { }

                $keys = @()
                if ($parsed -and $parsed.keys) {
                    $keys = @($parsed.keys | ForEach-Object { [string]$_ })
                }

                Write-JsonResponse -Context $context -Obj (Delete-BenchmarkHistoryByKeys -Keys $keys)
            }

            elseif ($method -eq "POST" -and $path -eq "/api/history/clear") {

                Write-JsonResponse -Context $context -Obj (Clear-BenchmarkHistory)
            }

            else {
                $response.StatusCode = 404
                $response.OutputStream.Close()
            }
        }
        catch {
            try {
                $response.StatusCode = 500
                $response.OutputStream.Close()
            } catch { }

            Write-Host "Request error ($path): $_" -ForegroundColor Red
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()

    if ($gpuJob) {
        $gpuJob.PowerShell.Stop()
        $gpuJob.PowerShell.Dispose()
        $gpuJob.Runspace.Close()
    }

    if ($activeGenJob) {
        $activeGenJob.PowerShell.Stop()
        $activeGenJob.PowerShell.Dispose()
        $activeGenJob.Runspace.Close()
    }

    if ($Global:ServerProcess -and -not $Global:ServerProcess.HasExited) {
        Stop-Process -Id $Global:ServerProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($Global:LlamaServerLockHeld) {
        $Global:LlamaServerLock.ReleaseMutex()
        $Global:LlamaServerLockHeld = $false
    }
    $Global:LlamaServerLock.Dispose()
}
