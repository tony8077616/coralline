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

  VL_FLOAT: after the statusline is written, the float file is produced the way
  statusline.ps1 produces it. The config, the float target and its collision
  checks, and the atomic writer are coralline's own code, extracted from
  statusline.ps1 and evaluated on every render. The text comes from a second
  Oh-My-Posh call on the float config (tools/build-omp-config.ps1 -FloatOutFile),
  whose per-segment markers let this script trim and join the segments with
  VL_FLOAT_SEP. Any failure skips the float file silently.

.PARAMETER OmpExe
  oh-my-posh executable. Defaults to $env:CORALLINE_OMP_EXE, then PATH.

.PARAMETER Config
  Config written by tools/build-omp-config.ps1. Defaults to
  $env:CORALLINE_OMP_CONFIG, then coralline.omp.json in the coralline state folder.

.PARAMETER FloatConfig
  Float config written by tools/build-omp-config.ps1 -FloatOutFile. Defaults to
  $env:CORALLINE_OMP_FLOAT_CONFIG, then coralline.float.omp.json next to Config.

.EXAMPLE
  Get-Content -Raw .\test\sample-input.json | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\statusline-omp.ps1
#>
param(
    [string]$OmpExe = '',
    [string]$Config = '',
    [string]$FloatConfig = ''
)

$ErrorActionPreference = 'Stop'
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IntegerStyle = [System.Globalization.NumberStyles]::Integer
$FloatStyle = [System.Globalization.NumberStyles]::Float
$WrapperPath = [string]$MyInvocation.MyCommand.Path
$Here = Split-Path -Path $WrapperPath -Parent
$StatuslinePath = [System.IO.Path]::Combine($Here, 'statusline.ps1')
$script:StatuslineAst = $null
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

function Get-StatuslineAst {
    <#
    .SYNOPSIS
      statusline.ps1 parsed once per render, or $null when it is missing or does not parse.
    .EXAMPLE
      Get-StatuslineAst
    #>
    if ($null -ne $script:StatuslineAst) { return $script:StatuslineAst }
    $tokens = $null
    $errors = $null
    $ast = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($StatuslinePath, [ref]$tokens, [ref]$errors) } catch { return $null }
    if ($null -eq $ast -or $errors.Count -ne 0) { return $null }
    $script:StatuslineAst = $ast
    return $ast
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
    $ast = Get-StatuslineAst
    if ($null -eq $ast) { return $null }
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

function Invoke-Omp {
    <#
    .SYNOPSIS
      Run `oh-my-posh claude` on a config; returns its stdout bytes, or $null when it fails.
    .DESCRIPTION
      Inherited CORALLINE_OMP_* variables are dropped and Environment is applied, so
      the main render and the float render see exactly the same flags. stdout is read
      as raw bytes: StandardOutput.ReadToEnd() would decode with the console code page
      on 5.1. Throws when the process cannot be started.
    .PARAMETER ExePath
      oh-my-posh executable.
    .PARAMETER ConfigPath
      Validated config.
    .PARAMETER Payload
      stdin bytes.
    .PARAMETER Environment
      CORALLINE_OMP_* name -> value.
    .EXAMPLE
      Invoke-Omp -ExePath $OmpExe -ConfigPath $Config -Payload ([byte[]]@()) -Environment @{}
    #>
    param([string]$ExePath, [string]$ConfigPath, [byte[]]$Payload, $Environment)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $ExePath
    $startInfo.Arguments = 'claude --config "' + $ConfigPath + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.CreateNoWindow = $true
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if (([string]$name).StartsWith('CORALLINE_OMP_', [System.StringComparison]::OrdinalIgnoreCase)) { $startInfo.EnvironmentVariables.Remove([string]$name) }
    }
    foreach ($name in $Environment.Keys) { $startInfo.EnvironmentVariables[[string]$name] = [string]$Environment[$name] }
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
    $pipe.Write($Payload, 0, $Payload.Length)
    $pipe.Flush()
    $pipe.Close()
    $output = New-Object System.IO.MemoryStream
    $process.StandardOutput.BaseStream.CopyTo($output)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { return $null }
    return , $output.ToArray()
}

function Get-FloatCount {
    <#
    .SYNOPSIS
      Number of float blocks recorded in a float config, or -1 when the record is unusable.
    .DESCRIPTION
      CorallineFloatCount must be an integer from 0 to 64 (statusline.ps1 renders at
      most 64 float tokens, so indices have at most two digits) and must equal the
      length of the CorallineFloatTokens list written beside it.
    .PARAMETER Path
      Float config that already passed Test-OmpConfig.
    .EXAMPLE
      Get-FloatCount -Path .\coralline.float.omp.json
    #>
    param([string]$Path)
    try {
        $parsed = $StrictUtf8.GetString([System.IO.File]::ReadAllBytes($Path)) | ConvertFrom-Json -ErrorAction Stop
        $count = $parsed.var.CorallineFloatCount
        $names = $parsed.var.CorallineFloatTokens
        if (-not ($count -is [int] -or $count -is [long])) { return -1 }
        if ($count -lt 0 -or $count -gt 64) { return -1 }
        if ($null -eq $names -or -not ($names -is [System.Array]) -or $names.Length -ne $count) { return -1 }
        return [int]$count
    } catch { return -1 }
}

function Invoke-OmpFloat {
    <#
    .SYNOPSIS
      Write the VL_FLOAT file the way statusline.ps1 Invoke-Float does, from an Oh-My-Posh render.
    .DESCRIPTION
      coralline's config loader, float target resolution, collision check, text check
      and atomic writer are extracted from statusline.ps1 unchanged and evaluated
      here, so relative VL_FLOAT_FILE values follow the current directory of this
      render exactly as they do natively. On top of statusline.ps1's own collision
      set, the target may not be statusline.ps1, this script, the generator, either
      Oh-My-Posh config or the Oh-My-Posh executable.

      The float config prints U+FDD0 <i> U+FDD1 before block i. The output is
      stripped of SGR and refused if any control character remains; it must hold
      exactly N markers of each kind, numbered 0..N-1 in order with nothing before
      the first. Each piece is trimmed, empty pieces are skipped, and the rest are
      joined with the VL_FLOAT_SEP of this render.

      The caller wraps the call in try/catch: every failure means no float file.
    .PARAMETER ExePath
      oh-my-posh executable.
    .PARAMETER MainConfig
      Validated main config.
    .PARAMETER FloatConfigPath
      Float config, or empty for the default next to MainConfig.
    .PARAMETER Payload
      The stdin bytes the main render received.
    .PARAMETER Environment
      The CORALLINE_OMP_* flags the main render received.
    .EXAMPLE
      Invoke-OmpFloat -ExePath $OmpExe -MainConfig $Config -FloatConfigPath '' -Payload $payloadBytes -Environment $envMap
    #>
    param([string]$ExePath, [string]$MainConfig, [string]$FloatConfigPath, [byte[]]$Payload, $Environment)
    if ([string]::IsNullOrEmpty($FloatConfigPath)) { $FloatConfigPath = [string]$env:CORALLINE_OMP_FLOAT_CONFIG }
    if ([string]::IsNullOrEmpty($FloatConfigPath)) {
        $FloatConfigPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($MainConfig)), 'coralline.float.omp.json')
    }
    $ast = Get-StatuslineAst
    if ($null -eq $ast) { return }

    # Every function the float path reaches, including transitive helpers. A missing
    # one skips the float file instead of failing inside the chain.
    $names = @('Glyph', 'Remove-ControlChars', 'Copy-Config', 'Add-Utf8Text', 'Read-WordChar', 'Decode-ShellWord',
        'Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath', 'Test-PathInside',
        'Test-NoReparseComponents', 'Test-SafeRegularFile', 'Read-StrictUtf8File', 'Import-ConfigFile',
        'Get-BoundedInt', 'Test-Color', 'Get-SegmentTokens', 'Get-StatePaths', 'Test-StateObjectExists',
        'Test-FloatCollision', 'Get-FloatTarget', 'Write-FloatAtomic', 'Test-FloatText', 'Remove-Sgr')
    $definitions = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $names -contains $node.Name
        }, $false)
    foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
    foreach ($name in $names) {
        if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { return }
    }

    # Script-level statements of statusline.ps1, located by their opening text:
    #   defaults  from `$HomeDir = [string]$HOME` to the $ConfigKeys loop, without
    #             $ScriptDir and $ScriptPath, which describe statusline.ps1 and are set here;
    #   config    from `$Cfg = Copy-Config $Defaults` to the Remove-ControlChars pass;
    #   float     $FloatTokens, $FloatEnabled and the $AllStatePaths derivation.
    $statements = $ast.EndBlock.Statements
    $defaultsCode = New-Object System.Text.StringBuilder
    $configCode = New-Object System.Text.StringBuilder
    $floatCode = New-Object System.Text.StringBuilder
    $stage = 0
    $floatStarts = @('$FloatTokens = ', '$FloatEnabled = ', '$AllStatePaths = ', 'foreach ($base in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE))')
    $floatFound = 0
    foreach ($statement in $statements) {
        $text = $statement.Extent.Text
        switch ($stage) {
            0 {
                if ($text.StartsWith('$HomeDir = [string]$HOME', [System.StringComparison]::Ordinal)) { $stage = 1; [void]$defaultsCode.AppendLine($text) }
                break
            }
            1 {
                if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                if ($text.StartsWith('$ScriptDir = ', [System.StringComparison]::Ordinal) -or $text.StartsWith('$ScriptPath = ', [System.StringComparison]::Ordinal)) { break }
                [void]$defaultsCode.AppendLine($text)
                if ($text.StartsWith('foreach ($key in $Defaults.Keys)', [System.StringComparison]::Ordinal)) { $stage = 2 }
                break
            }
            2 {
                if ($text.StartsWith('$Cfg = Copy-Config $Defaults', [System.StringComparison]::Ordinal)) { $stage = 3; [void]$configCode.AppendLine($text) }
                break
            }
            3 {
                if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                [void]$configCode.AppendLine($text)
                if ($text.StartsWith('foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars', [System.StringComparison]::Ordinal)) { $stage = 4 }
                break
            }
            4 {
                if ($floatFound -lt $floatStarts.Count -and $text.StartsWith($floatStarts[$floatFound], [System.StringComparison]::Ordinal)) {
                    [void]$floatCode.AppendLine($text)
                    $floatFound++
                }
                break
            }
        }
    }
    if ($stage -ne 4 -or $floatFound -ne $floatStarts.Count) { return }

    # statusline.ps1 runs under SilentlyContinue; the caller's catch still ends the
    # float path on anything that would otherwise terminate a statement.
    $ErrorActionPreference = 'SilentlyContinue'
    $visited = $null
    . ([scriptblock]::Create($defaultsCode.ToString()))
    # The native script's own folder and path, not this wrapper's: $ScriptDir roots
    # the approved themes folder, and $ScriptPath is the free variable
    # Test-FloatCollision reads to protect statusline.ps1.
    $ScriptDir = Split-Path -Path $StatuslinePath -Parent
    $ScriptPath = $StatuslinePath
    . ([scriptblock]::Create($configCode.ToString()))
    . ([scriptblock]::Create($floatCode.ToString()))
    if ($FloatEnabled -ne $true) { return }
    $target = Get-FloatTarget
    if ([string]::IsNullOrEmpty($target)) { return }

    # Explicit collision set, independent of $ScriptPath above.
    $protected = @($StatuslinePath, $WrapperPath, [System.IO.Path]::Combine($Here, 'tools', 'build-omp-config.ps1'), $MainConfig, $FloatConfigPath, $ExePath)
    foreach ($path in $protected) {
        if ([string]::IsNullOrEmpty([string]$path)) { continue }
        if ($target.Equals([string]$path, [System.StringComparison]::OrdinalIgnoreCase)) { return }
        $full = ''
        try { $full = [System.IO.Path]::GetFullPath([string]$path) } catch { $full = '' }
        if (-not [string]::IsNullOrEmpty($full) -and $target.Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) { return }
    }

    # (1) render and decode
    if (-not (Test-OmpConfig $FloatConfigPath)) { return }
    $count = Get-FloatCount $FloatConfigPath
    if ($count -lt 0) { return }
    $plain = ''
    if ($count -gt 0) {
        $rendered = Invoke-Omp $ExePath $FloatConfigPath $Payload $Environment
        if ($null -eq $rendered) { return }
        $decoded = $null
        try { $decoded = $StrictUtf8.GetString($rendered) } catch { return }
        # (2) no control character may survive SGR removal anywhere in the output
        $plain = Remove-Sgr $decoded
        if (Test-FloatText $plain) { return }
    }

    # (3) exactly N markers of each kind, numbered 0..N-1 in order, nothing before the first
    $openCount = 0
    $closeCount = 0
    foreach ($ch in $plain.ToCharArray()) {
        switch ([int]$ch) {
            0xFDD0 { $openCount++; break }
            0xFDD1 { $closeCount++; break }
        }
    }
    if ($openCount -ne $count -or $closeCount -ne $count) { return }
    $open = [char]0xFDD0
    $close = [char]0xFDD1
    $pieces = New-Object 'System.Collections.Generic.List[string]'
    $position = 0
    for ($k = 0; $k -lt $count; $k++) {
        if ($position -ge $plain.Length -or [int]$plain[$position] -ne 0xFDD0) { return }
        $end = $plain.IndexOf($close, $position)
        if ($end -lt 0) { return }
        $digits = $plain.Substring($position + 1, $end - $position - 1)
        if ($digits -cnotmatch '\A[0-9]{1,2}\z') { return }
        $index = [int]::Parse($digits, $IntegerStyle, $Invariant)
        if ($index -ne $k -or -not [string]::Equals($digits, $k.ToString($Invariant), [System.StringComparison]::Ordinal)) { return }
        $next = $plain.IndexOf($open, $end + 1)
        if ($next -lt 0) { $next = $plain.Length }
        [void]$pieces.Add($plain.Substring($end + 1, $next - $end - 1))
        $position = $next
    }
    if ($position -ne $plain.Length) { return }

    # (4) trim each piece as Invoke-Float does and join with this render's separator
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($piece in $pieces) {
        $trimmed = $piece.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }
        [void]$parts.Add($trimmed)
    }
    $line = [string]::Join([string]$Cfg.VL_FLOAT_SEP, $parts.ToArray())
    # (5) the joined line, separator included
    if (Test-FloatText $line) { return }
    # (6) size cap and atomic write
    $bytes = $StrictUtf8.GetBytes($line + "`n")
    if ($bytes.Length -gt 65536) { return }
    [void](Write-FloatAtomic $target $bytes)
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
$mainBytes = [byte[]](10)
try {
    $rendered = Invoke-Omp $OmpExe $Config $payloadBytes $envMap
    if ($null -ne $rendered) { $mainBytes = $rendered }
} catch { }
Write-Bytes $mainBytes

# ---- float, after the statusline is out; a failure never reaches stdout or the exit code
try { Invoke-OmpFloat $OmpExe $Config $FloatConfig $payloadBytes $envMap } catch { }
exit 0
