#Requires -Version 5.1
<#
.SYNOPSIS
  coralline statusline rendered by Oh-My-Posh.

.DESCRIPTION
  Opt-in alternative entry point. Reads the Claude Code statusLine payload from
  stdin, interprets it with coralline's own parsing code (extracted live from
  statusline.ps1 through the PowerShell AST), and hands Oh-My-Posh a clean payload
  in which every field has the type Oh-My-Posh's Claude model expects. Values that
  model cannot carry (prompt_cache, verbatim token text, the hide decisions for
  ctx and cost) travel as CORALLINE_OMP_* environment variables read by the config
  that tools/build-omp-config.ps1 generates.

  Failure handling:
  - stdin that is not a JSON object renders like statusline.ps1 does for it,
    from an empty payload.
  - If interpreting the payload fails, the raw stdin goes to Oh-My-Posh unchanged.
  - A config that does not parse or lacks the generator marker, a missing
    Oh-My-Posh, or an Oh-My-Posh failure prints an empty line. Oh-My-Posh would
    otherwise fall back to its own default layout without saying so.
  The exit status is always 0.

.PARAMETER OmpExe
  oh-my-posh executable. Defaults to $env:CORALLINE_OMP_EXE, then PATH.

.PARAMETER Config
  Config written by tools/build-omp-config.ps1. Defaults to
  $env:CORALLINE_OMP_CONFIG, then coralline.omp.json in the coralline state folder.

.EXAMPLE
  Get-Content -Raw .\test\sample-input.json | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\statusline-omp.ps1
#>
param(
    [string]$OmpExe = '',
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IntegerStyle = [System.Globalization.NumberStyles]::Integer
$FloatStyle = [System.Globalization.NumberStyles]::Float
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Stdout = [Console]::OpenStandardOutput()
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Write-Bytes {
    <#
    .SYNOPSIS
      Write raw bytes to stdout.
    .PARAMETER Bytes
      Bytes to write.
    .EXAMPLE
      Write-Bytes -Bytes ([byte[]](10))
    #>
    param([byte[]]$Bytes)
    $Stdout.Write($Bytes, 0, $Bytes.Length)
    $Stdout.Flush()
}

function Exit-Blank {
    <#
    .SYNOPSIS
      Print an empty line and exit 0.
    .EXAMPLE
      Exit-Blank
    #>
    Write-Bytes ([byte[]](10))
    exit 0
}

function ConvertTo-JsonText {
    <#
    .SYNOPSIS
      Serialize the normalised payload: ordered maps, strings, longs and doubles.
    .DESCRIPTION
      Output is ASCII; anything outside printable ASCII is written as \uXXXX.
      Doubles use the round-trip format, which is valid JSON on 5.1 and 7.
    .PARAMETER Value
      Value to serialize.
    .EXAMPLE
      ConvertTo-JsonText -Value ([ordered]@{ a = 1L })
    #>
    param($Value)
    switch ($true) {
        { $Value -is [System.Collections.IDictionary] } {
            $parts = New-Object 'System.Collections.Generic.List[string]'
            foreach ($key in $Value.Keys) { [void]$parts.Add((ConvertTo-JsonText ([string]$key)) + ':' + (ConvertTo-JsonText $Value[$key])) }
            return '{' + [string]::Join(',', $parts.ToArray()) + '}'
        }
        { $Value -is [string] } {
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append('"')
            foreach ($ch in $Value.ToCharArray()) {
                $code = [int]$ch
                switch ($true) {
                    { $code -eq 0x22 } { [void]$builder.Append('\"'); break }
                    { $code -eq 0x5C } { [void]$builder.Append('\\'); break }
                    { $code -lt 0x20 -or $code -gt 0x7E } { [void]$builder.Append('\u' + $code.ToString('x4', $Invariant)); break }
                    default { [void]$builder.Append($ch) }
                }
            }
            [void]$builder.Append('"')
            return $builder.ToString()
        }
        { $Value -is [double] } { return $Value.ToString('R', $Invariant) }
        default { return ([long]$Value).ToString($Invariant) }
    }
}

function Test-OmpConfig {
    <#
    .SYNOPSIS
      True when the config parses as JSON and carries the build-omp-config.ps1 marker.
    .PARAMETER Path
      Config path.
    .EXAMPLE
      Test-OmpConfig -Path .\coralline.omp.json
    #>
    param([string]$Path)
    try {
        if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists($Path)) { return $false }
        $parsed = $StrictUtf8.GetString([System.IO.File]::ReadAllBytes($Path)) | ConvertFrom-Json -ErrorAction Stop
        $marker = [string]$parsed.var.CorallineGenerator
        return $marker.StartsWith('coralline-omp/', [System.StringComparison]::Ordinal)
    } catch { return $false }
}

function Get-OmpEnvironment {
    <#
    .SYNOPSIS
      Interpret the payload with coralline's own code and build the Oh-My-Posh input.
    .DESCRIPTION
      Returns @{ Payload = <JSON text>; Env = <name -> value> }, or $null when
      statusline.ps1 cannot supply the parsing code; the caller then passes the raw
      stdin through. It must not run inside try/catch: statusline.ps1 relies on a
      failing statement being skipped under SilentlyContinue, and an enclosing catch
      would abort the whole interpretation instead.
    .PARAMETER RawInput
      Decoded stdin.
    .EXAMPLE
      Get-OmpEnvironment -RawInput '{"model":{"display_name":"Opus"}}'
    #>
    param([string]$RawInput)
    $statusline = [System.IO.Path]::Combine($Here, 'statusline.ps1')
    $tokens = $null
    $errors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($statusline, [ref]$tokens, [ref]$errors) } catch { return $null }
    if ($null -eq $ast -or $errors.Count -ne 0) { return $null }
    $names = @('Remove-ControlChars', 'Try-BoundedDouble', 'Get-PctValue', 'ConvertTo-Epoch', 'Format-Duration',
        'Format-Tok', 'Get-JsonMember', 'Get-JsonPath', 'To-InvariantString', 'Add-CostSegment',
        'Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath', 'ConvertTo-ProbePath')
    $definitions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $node.Name
        }, $false)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
    foreach ($name in $names) {
        if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { return $null }
    }
    # The payload-reading statements, from `$JsonParsed = $false` to `$effort = ...`.
    $statements = $ast.EndBlock.Statements
    $first = -1
    $last = -1
    for ($i = 0; $i -lt $statements.Count; $i++) {
        $text = $statements[$i].Extent.Text
        if ($first -lt 0 -and $text.StartsWith('$JsonParsed = $false', [System.StringComparison]::Ordinal)) { $first = $i }
        if ($first -ge 0 -and $text.StartsWith('$effort = ', [System.StringComparison]::Ordinal)) { $last = $i; break }
    }
    if ($first -lt 0 -or $last -lt 0) { return $null }
    $block = New-Object System.Text.StringBuilder
    for ($i = $first; $i -le $last; $i++) { [void]$block.AppendLine($statements[$i].Extent.Text) }
    $rawInput = $RawInput
    # statusline.ps1 runs under SilentlyContinue: a statement that fails on an odd
    # payload value is skipped and rendering goes on. Everything below mirrors it.
    $ErrorActionPreference = 'SilentlyContinue'
    . ([scriptblock]::Create($block.ToString()))

    $envMap = [ordered]@{}
    $payload = [ordered]@{}
    # statusline.ps1 hides dir without a payload directory, and the git and runtime
    # segments without a valid probe path; Oh-My-Posh would fall back to its own cwd.
    if ([string]::IsNullOrEmpty($cwd)) { $envMap.CORALLINE_OMP_NODIR = '1' }
    if ([string]::IsNullOrEmpty((ConvertTo-ProbePath $cwd))) { $envMap.CORALLINE_OMP_NOPROBE = '1' }
    if (-not [string]::IsNullOrEmpty($cwd)) {
        $envMap.CORALLINE_OMP_CWD = $cwd
        $payload.cwd = $cwd
        $payload.workspace = [ordered]@{ current_dir = $cwd }
    }
    if (-not [string]::IsNullOrEmpty($model)) { $payload.model = [ordered]@{ display_name = $model } }
    if (-not [string]::IsNullOrEmpty($effort)) { $payload.effort = [ordered]@{ level = $effort } }
    if (-not [string]::IsNullOrEmpty($outStyle)) { $payload.output_style = [ordered]@{ name = $outStyle } }

    # ctx: statusline.ps1 Add-CtxSegment shows a known percentage, and a zero gauge
    # under VL_CTX_ALWAYS_SHOW only for a parsed payload whose value is absent.
    $pct = 0
    $known = Get-PctValue $ctxPct ([ref]$pct)
    $context = [ordered]@{}
    if ($known) { $context.used_percentage = [long]$pct }
    if (-not $known -and (-not $JsonParsed -or -not $ctxEmpty)) { $envMap.CORALLINE_OMP_CTX_HIDE = '1' }
    $envMap.CORALLINE_OMP_TOK_IN = Format-Tok $tokIn
    $envMap.CORALLINE_OMP_TOK_OUT = Format-Tok $tokOut
    $envMap.CORALLINE_OMP_TOK_CR = Format-Tok $tokCr
    $envMap.CORALLINE_OMP_TOK_CW = Format-Tok $tokCw
    if ($context.Count -gt 0) { $payload.context_window = $context }

    # Rate limits: a window renders when its percentage reads; the reset is optional.
    $limits = [ordered]@{}
    foreach ($window in @(@('five_hour', $fhPct, $fhRst), @('seven_day', $wdPct, $wdRst))) {
        $windowPct = 0
        if (-not (Get-PctValue $window[1] ([ref]$windowPct))) { continue }
        $entry = [ordered]@{ used_percentage = [long]$windowPct }
        $epoch = ConvertTo-Epoch $window[2]
        if ($null -ne $epoch) { $entry.resets_at = [long]$epoch }
        $limits[$window[0]] = $entry
    }
    if ($limits.Count -gt 0) { $payload.rate_limits = $limits }

    # cost: run coralline's own Add-CostSegment with VL_COST_ALWAYS_SHOW=1. If it
    # still declines, the value is invalid and the segment hides whatever the
    # config says; otherwise a zero is left for the config's own always-show rule.
    $Cfg = @{ VL_COST_ALWAYS_SHOW = '1'; VL_COST_DECIMALS = '2'; VL_BG_COST = ''; VL_FG_TEXT = '' }
    $script:CostPushed = $false
    function Push-Segment { $script:CostPushed = $true }
    function Get-Fg { return '' }
    Add-CostSegment
    $costBlock = [ordered]@{}
    switch ($script:CostPushed) {
        $true {
            $costValue = 0.0
            if ($costKind -eq 'scalar' -and (Try-BoundedDouble $costRaw 0 1000000000 ([ref]$costValue))) { $costBlock.total_cost_usd = [double]$costValue }
        }
        default { $envMap.CORALLINE_OMP_COST_HIDE = '1' }
    }
    foreach ($pair in @(@('total_lines_added', $linesAdd), @('total_lines_removed', $linesDel))) {
        $lines = 0L
        if ([long]::TryParse($pair[1], $IntegerStyle, $Invariant, [ref]$lines) -and $lines -gt 0 -and $lines -le 1000000000000000) { $costBlock[$pair[0]] = $lines }
    }
    $duration = 0.0
    if ((Try-BoundedDouble $durMs 0 1000000000000000 ([ref]$duration)) -and $duration -gt 0) { $costBlock.total_duration_ms = [long][math]::Floor($duration) }
    if ($costBlock.Count -gt 0) { $payload.cost = $costBlock }

    # cache: Add-CacheSegment's percentage and countdown.
    $cachePct = 0
    if (Get-PctValue $cacheHit ([ref]$cachePct)) {
        $envMap.CORALLINE_OMP_CACHE_PCT = [string]$cachePct
        $left = 'cold'
        $expires = ConvertTo-Epoch $cacheExp
        if ($null -ne $expires) {
            $diff = [long]$expires - $Now
            if ($diff -gt 0) { $left = Format-Duration ([double]$diff * 1000) ($diff -lt 3600) }
        }
        $envMap.CORALLINE_OMP_CACHE_LEFT = $left
    }
    return @{ Payload = (ConvertTo-JsonText $payload); Env = $envMap }
}

# ---- stdin, read the way statusline.ps1 reads it -------------------------------------
$buffer = New-Object System.IO.MemoryStream
try { [Console]::OpenStandardInput().CopyTo($buffer) } catch { }
$rawBytes = $buffer.ToArray()
$decoded = ''
try { $decoded = $StrictUtf8.GetString($rawBytes) } catch { $decoded = '' }

# ---- config and executable ------------------------------------------------------------
if ([string]::IsNullOrEmpty($Config)) { $Config = [string]$env:CORALLINE_OMP_CONFIG }
if ([string]::IsNullOrEmpty($Config)) {
    $stateDir = [string]$env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($stateDir)) { $stateDir = [System.IO.Path]::Combine([string]$HOME, '.claude') }
    $Config = [System.IO.Path]::Combine($stateDir, 'coralline', 'coralline.omp.json')
}
if (-not (Test-OmpConfig $Config)) { Exit-Blank }
if ([string]::IsNullOrEmpty($OmpExe)) { $OmpExe = [string]$env:CORALLINE_OMP_EXE }
if ([string]::IsNullOrEmpty($OmpExe)) {
    $command = Get-Command -Name 'oh-my-posh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $OmpExe = $command.Source }
}
if ([string]::IsNullOrEmpty($OmpExe) -or -not [System.IO.File]::Exists($OmpExe)) { Exit-Blank }

# ---- normalise, falling back to the raw stdin ----------------------------------------
$payloadBytes = $rawBytes
$envMap = [ordered]@{}
$result = Get-OmpEnvironment $decoded
if ($result -is [hashtable] -and $result.Payload -is [string]) {
    $payloadBytes = $Utf8NoBom.GetBytes([string]$result.Payload)
    $envMap = $result.Env
}

# ---- render ---------------------------------------------------------------------------
try {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $OmpExe
    $startInfo.Arguments = 'claude --config "' + $Config + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.CreateNoWindow = $true
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if (([string]$name).StartsWith('CORALLINE_OMP_', [System.StringComparison]::OrdinalIgnoreCase)) { $startInfo.EnvironmentVariables.Remove([string]$name) }
    }
    foreach ($name in $envMap.Keys) { $startInfo.EnvironmentVariables[[string]$name] = [string]$envMap[$name] }
    # .NET Framework opens the child's stdin writer with Console.InputEncoding and
    # flushes its preamble at once, so under code page 65001 the payload would start
    # with a BOM that Oh-My-Posh's JSON decoder rejects. Swapping in the same code
    # page without a preamble leaves the shared console's code page unchanged.
    try {
        $inputEncoding = [Console]::InputEncoding
        if ($inputEncoding.CodePage -eq 65001 -and $inputEncoding.GetPreamble().Length -gt 0) { [Console]::InputEncoding = $Utf8NoBom }
    } catch { }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # Write and close the pipe itself: on 5.1 closing the StreamWriter emits the
    # console encoding's BOM after the payload, and Oh-My-Posh then drops it all.
    $pipe = $process.StandardInput.BaseStream
    $pipe.Write($payloadBytes, 0, $payloadBytes.Length)
    $pipe.Flush()
    $pipe.Close()
    $output = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($output)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { Exit-Blank }
    Write-Bytes $output.ToArray()
} catch { Exit-Blank }
exit 0
