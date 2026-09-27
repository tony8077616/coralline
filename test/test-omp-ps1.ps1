#Requires -Version 5.1
<#
.SYNOPSIS
  Regression tests for statusline-omp.ps1 (the Oh-My-Posh engine) and tools/build-omp-config.ps1.

.DESCRIPTION
  Runs on the PowerShell that runs it (5.1 or 7): every renderer, generator and
  probe is started with (Get-Process -Id $PID).Path, stdin handed over as raw bytes
  through the OS pipe, stdout captured as raw bytes.

  Isolation: everything runs inside a fresh temporary root holding copies of
  statusline.ps1, statusline-omp.ps1, tools\build-omp-config.ps1, the themes and
  the Oh-My-Posh executable. Child processes get an environment built from an
  allow-list, with HOME, USERPROFILE, LOCALAPPDATA, APPDATA, CLAUDE_CONFIG_DIR,
  XDG_* and TEMP pointing into the temporary root. The repo files, the Oh-My-Posh
  source and the Oh-My-Posh entry on PATH are witnessed before and after (SHA-256,
  or attributes for an App Execution Alias, which cannot be read).

  Groups (minimum PASS count under -Strict):
    A  generator (12)            B  main-line cell parity (16)   C  failure semantics (4)
    D  float (14)                E  burn and limit sync (10)     F  --subagent (3)
    G  VL_LAYOUT=auto (8)        H  upstream sync tripwires (10) I  R1 protected paths (20)
    X  isolation and integrity witnesses (no minimum)
  Checks that reach the wrapper's Oh-My-Posh call need Oh-My-Posh; without one
  they are BLOCKED. H and the I unit table never need it.

  Every check that expects the wrapper NOT to write has a reachability control in
  the same setting that must write; if the control does not write, the check is
  BLOCKED instead of passing. Before any run whose target could be damaged, the
  target is confirmed to be inside the temporary root.

.PARAMETER OmpSource
  Oh-My-Posh executable to copy into the temporary root (alias -OmpExe). When
  omitted, the first oh-my-posh on PATH is used if it is a regular file; an App
  Execution Alias cannot be copied, so the checks that need Oh-My-Posh are then
  BLOCKED. Version 31.3.0 or later is required.

.PARAMETER Strict
  Exit 2 when any BLOCKED check falls outside the allow-list (git missing, an
  elevated token) or any group has fewer PASS results than its minimum.

.PARAMETER Mutation
  M1..M9: apply one mutation to the copies under test in the temporary root, run
  only the groups it targets, and verify that every check ID listed for it FAILs.
  Exit 0 when all of them do, 1 otherwise.

.PARAMETER Group
  Run only these groups (for example A,H). X always runs.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test\test-omp-ps1.ps1 -OmpSource C:\tools\oh-my-posh.exe -Strict

.EXAMPLE
  pwsh -NoProfile -File .\test\test-omp-ps1.ps1 -OmpSource C:\tools\oh-my-posh.exe -Mutation M3
#>
[CmdletBinding()]
param(
    [Alias('OmpExe')][string]$OmpSource = '',
    [switch]$Strict,
    [string]$Mutation = '',
    [string[]]$Group = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Clock = [System.Diagnostics.Stopwatch]::StartNew()
$StartUtc = [DateTime]::UtcNow
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$HostExe = (Get-Process -Id $PID).Path
$IsLegacyHost = $PSVersionTable.PSEdition -ne 'Core'
$HostTag = 'ps51'
if (-not $IsLegacyHost) { $HostTag = 'pwsh' + $PSVersionTable.PSVersion.Major + $PSVersionTable.PSVersion.Minor }
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$Esc = [char]27
$US = [string][char]0x1F
$USChar = [char]0x1F
$RunId = [guid]::NewGuid().ToString('N')
$Marker = 'mk' + $RunId.Substring(0, 12)
$TempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('coralline-omp-test-' + $RunId))
$TempRoot = [System.IO.Path]::GetFullPath($TempRoot).TrimEnd('\')
$ChildTimeoutMs = 90000
$script:Pass = 0
$script:Fail = 0
$script:Blocked = 0
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:Notes = New-Object 'System.Collections.Generic.List[string]'
$MinimumPass = [ordered]@{ A = 12; B = 16; C = 4; D = 14; E = 10; F = 3; G = 8; H = 10; I = 20 }
# Blocked reasons -Strict accepts (prefix of the reason text).
$AllowedBlockedPrefixes = @('ALLOWED git-missing:', 'ALLOWED elevated-token:')

# ============================================================================================
# Reporting
# ============================================================================================
function Get-CheckGroup {
    <#
    .SYNOPSIS
      Group letter of a check ID: the text before its first '-'.
    .PARAMETER Name
      Check ID.
    .EXAMPLE
      Get-CheckGroup -Name 'I-unit-qC'
    #>
    param([string]$Name)
    $dash = $Name.IndexOf('-')
    if ($dash -lt 1) { return $Name }
    return $Name.Substring(0, $dash)
}

function Check {
    <#
    .SYNOPSIS
      Record one PASS or FAIL.
    .PARAMETER Name
      Check ID.
    .PARAMETER Condition
      True for PASS.
    .PARAMETER Detail
      Printed after a FAIL.
    .EXAMPLE
      Check 'A-gen-pill-claude-coral-runs' $true
    #>
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    switch ($Condition) {
        $true {
            [Console]::Out.WriteLine('PASS  ' + $Name)
            $script:Pass++
            [void]$script:Results.Add(@{ Id = $Name; Group = (Get-CheckGroup $Name); Status = 'PASS'; Detail = '' })
        }
        default {
            [Console]::Out.WriteLine('FAIL  ' + $Name + $(if ($Detail -ne '') { ': ' + $Detail } else { '' }))
            $script:Fail++
            [void]$script:Results.Add(@{ Id = $Name; Group = (Get-CheckGroup $Name); Status = 'FAIL'; Detail = $Detail })
        }
    }
}

function Blocked {
    <#
    .SYNOPSIS
      Record a check that could not run; never counted as PASS.
    .PARAMETER Name
      Check ID.
    .PARAMETER Reason
      Why. Starts with an $AllowedBlockedPrefixes entry only for the -Strict allow-list.
    .EXAMPLE
      Blocked 'B-git-clean' 'ALLOWED git-missing: git.exe not on PATH'
    #>
    param([string]$Name, [string]$Reason)
    [Console]::Out.WriteLine('BLOCKED  ' + $Name + ': ' + $Reason)
    $script:Blocked++
    [void]$script:Results.Add(@{ Id = $Name; Group = (Get-CheckGroup $Name); Status = 'BLOCKED'; Detail = $Reason })
}

function Add-Note {
    <#
    .SYNOPSIS
      Print an observation that is not a check.
    .PARAMETER Text
      Observation.
    .EXAMPLE
      Add-Note 'omp version 31.3.0'
    #>
    param([string]$Text)
    [Console]::Out.WriteLine('NOTE  ' + $Text)
    [void]$script:Notes.Add($Text)
}

function Test-GroupOn {
    <#
    .SYNOPSIS
      True when this run includes the group.
    .PARAMETER Name
      Group letter.
    .EXAMPLE
      Test-GroupOn 'B'
    #>
    param([string]$Name)
    if ($script:ActiveGroups.Count -eq 0) { return $true }
    return ($script:ActiveGroups -contains $Name)
}

# ============================================================================================
# Files and bytes
# ============================================================================================
function Write-Utf8 {
    <#
    .SYNOPSIS
      Write UTF-8 text without BOM, creating the folder.
    .PARAMETER Path
      File.
    .PARAMETER Text
      Content.
    .EXAMPLE
      Write-Utf8 -Path (Join-Path $TempRoot 'a.txt') -Text "x`n"
    #>
    param([string]$Path, [string]$Text)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($TempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw ('refusing to write outside the temporary root: ' + $full) }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function Get-Sha256 {
    <#
    .SYNOPSIS
      Lower-case SHA-256 of a file, or 'absent'.
    .PARAMETER Path
      File.
    .EXAMPLE
      Get-Sha256 -Path $Repo\statusline.ps1
    #>
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return 'absent' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join @($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

function Read-Maybe {
    <#
    .SYNOPSIS
      File bytes, or $null when the file does not exist.
    .PARAMETER Path
      File.
    .EXAMPLE
      Read-Maybe -Path $target
    #>
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    return , ([System.IO.File]::ReadAllBytes($Path))
}

function Test-SameBytes {
    <#
    .SYNOPSIS
      True when both are $null or both hold identical bytes.
    .PARAMETER A
      First value.
    .PARAMETER B
      Second value.
    .EXAMPLE
      Test-SameBytes -A $x -B $y
    #>
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    $left = [byte[]]$A
    $right = [byte[]]$B
    if ($left.Length -ne $right.Length) { return $false }
    for ($i = 0; $i -lt $left.Length; $i++) { if ($left[$i] -ne $right[$i]) { return $false } }
    return $true
}

function Show-Text {
    <#
    .SYNOPSIS
      Printable form of text: non-ASCII and controls as <U+XXXX>, cut at 300 characters.
    .PARAMETER Text
      Text.
    .EXAMPLE
      Show-Text -Text "a`n"
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '<null>' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        switch ($true) {
            { $code -lt 0x20 -or $code -gt 0x7E } { [void]$builder.Append('<U+' + $code.ToString('X4') + '>'); break }
            default { [void]$builder.Append($ch) }
        }
    }
    if ($builder.Length -gt 300) { return $builder.ToString(0, 300) + '...' }
    return $builder.ToString()
}

function Remove-TestTree {
    <#
    .SYNOPSIS
      Delete a file or folder inside the temporary root without following links.
    .DESCRIPTION
      A reparse point (junction, symbolic link) is removed as a link, never
      traversed; anything outside the temporary root is refused.
    .PARAMETER Path
      File or folder.
    .EXAMPLE
      Remove-TestTree -Path (Join-Path $TempRoot 'x')
    #>
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not ($full.Equals($TempRoot, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($TempRoot + '\', [StringComparison]::OrdinalIgnoreCase))) { throw ('refusing to delete outside the temporary root: ' + $full) }
    $attrs = $null
    try { $attrs = [System.IO.File]::GetAttributes($full) } catch { return }
    $isDir = ($attrs -band [System.IO.FileAttributes]::Directory) -ne 0
    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        switch ($isDir) { $true { [System.IO.Directory]::Delete($full, $false) } default { [System.IO.File]::Delete($full) } }
        return
    }
    if ($isDir) {
        foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($full)) { Remove-TestTree $entry }
        [System.IO.Directory]::Delete($full, $false)
        return
    }
    [System.IO.File]::SetAttributes($full, [System.IO.FileAttributes]::Normal)
    [System.IO.File]::Delete($full)
}

function ConvertTo-JsonLiteral {
    <#
    .SYNOPSIS
      JSON string literal with every non-ASCII or control character escaped.
    .PARAMETER Text
      Text.
    .EXAMPLE
      ConvertTo-JsonLiteral -Text 'C:\x'
    #>
    param([string]$Text)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        switch ($true) {
            { $code -eq 0x22 } { [void]$builder.Append('\"'); break }
            { $code -eq 0x5C } { [void]$builder.Append('\\'); break }
            { $code -lt 0x20 -or $code -gt 0x7E } { [void]$builder.Append('\u' + $code.ToString('x4')); break }
            default { [void]$builder.Append($ch) }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Resolve-TimeTokens {
    <#
    .SYNOPSIS
      Replace {T+n} with epoch seconds and {ISO+n} with an ISO-8601 UTC time relative to Second.
    .PARAMETER Text
      Payload template.
    .PARAMETER Second
      Base Unix time.
    .EXAMPLE
      Resolve-TimeTokens -Text '{"x":{T+60}}' -Second 1790000000
    #>
    param([string]$Text, [long]$Second)
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $value = $Second + [long]$m.Groups[2].Value
        switch ($m.Groups[1].Value) {
            'ISO' { return [DateTimeOffset]::FromUnixTimeSeconds($value).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
            default { return [string]$value }
        }
    }
    return [regex]::Replace($Text, '\{(T|ISO)([+-][0-9]+)\}', $evaluator)
}

function Get-UnixNow {
    <#
    .SYNOPSIS
      Current Unix time in seconds.
    .EXAMPLE
      Get-UnixNow
    #>
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

# ============================================================================================
# Child processes
# ============================================================================================
function ConvertTo-ArgText {
    <#
    .SYNOPSIS
      One command-line argument quoted for CommandLineToArgvW.
    .PARAMETER Value
      Argument.
    .EXAMPLE
      ConvertTo-ArgText -Value 'C:\a b\'
    #>
    param([string]$Value)
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

function New-ChildEnvironment {
    <#
    .SYNOPSIS
      The allow-listed environment for a child process, as a name -> value map.
    .DESCRIPTION
      System variables are copied from this process; PATH holds only system32 and
      git's folder; every home, profile, cache and temp variable points into the
      temporary root. Nothing else is inherited: no CORALLINE_*, REMORA_*, POSH_*,
      GIT_*, VIRTUAL_ENV, CONDA_DEFAULT_ENV, COLUMNS or PSModulePath.
    .PARAMETER Extra
      Case-specific variables; a $null value leaves the name out.
    .EXAMPLE
      New-ChildEnvironment -Extra @{ CORALLINE_CONFIG = $conf }
    #>
    param([hashtable]$Extra = @{})
    $map = [ordered]@{}
    foreach ($name in @('SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'SystemDrive', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432', 'ProgramData')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrEmpty($value)) { $map[$name] = $value }
    }
    $pathParts = @([Environment]::SystemDirectory)
    if (-not [string]::IsNullOrEmpty($GitDir)) { $pathParts += $GitDir }
    $map['PATH'] = [string]::Join(';', $pathParts)
    $map['TEMP'] = $ChildTemp
    $map['TMP'] = $ChildTemp
    $map['HOME'] = $ChildHome
    $map['USERPROFILE'] = $ChildHome
    $map['HOMEDRIVE'] = $ChildHome.Substring(0, 2)
    $map['HOMEPATH'] = $ChildHome.Substring(2)
    $map['LOCALAPPDATA'] = [System.IO.Path]::Combine($ChildHome, 'AppData\Local')
    $map['APPDATA'] = [System.IO.Path]::Combine($ChildHome, 'AppData\Roaming')
    $map['XDG_CACHE_HOME'] = [System.IO.Path]::Combine($ChildHome, '.cache')
    $map['XDG_CONFIG_HOME'] = [System.IO.Path]::Combine($ChildHome, '.config')
    $map['CLAUDE_CONFIG_DIR'] = [System.IO.Path]::Combine($ChildHome, '.claude')
    foreach ($key in $Extra.Keys) {
        switch ($null -eq $Extra[$key]) {
            $true { $map.Remove([string]$key) }
            default { $map[[string]$key] = [string]$Extra[$key] }
        }
    }
    return $map
}

function Invoke-Child {
    <#
    .SYNOPSIS
      Run a script with this PowerShell in the allow-listed environment; returns @{ Exit; Bytes; Text; Err; TimedOut }.
    .PARAMETER Script
      Script path as the child receives it after -File (may carry a \\?\ or \\.\ prefix).
    .PARAMETER Arguments
      Arguments after the script.
    .PARAMETER Stdin
      stdin bytes; $null closes stdin at once.
    .PARAMETER Extra
      Case-specific environment (see New-ChildEnvironment).
    .PARAMETER Cwd
      Working directory; the temporary root when empty.
    .EXAMPLE
      Invoke-Child -Script $NativeScript -Stdin $bytes -Extra @{ CORALLINE_CONFIG = $conf }
    #>
    param([string]$Script, [string[]]$Arguments = @(), [byte[]]$Stdin = $null, [hashtable]$Extra = @{}, [string]$Cwd = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $HostExe
    $argv = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script)) { [void]$argv.Add((ConvertTo-ArgText $item)) }
    foreach ($item in $Arguments) { [void]$argv.Add((ConvertTo-ArgText $item)) }
    $psi.Arguments = [string]::Join(' ', $argv.ToArray())
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ([string]::IsNullOrEmpty($Cwd)) { $Cwd = $TempRoot }
    $psi.WorkingDirectory = $Cwd
    $psi.EnvironmentVariables.Clear()
    $environment = New-ChildEnvironment -Extra $Extra
    foreach ($key in $environment.Keys) { $psi.EnvironmentVariables[[string]$key] = [string]$environment[$key] }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $stdout = New-Object System.IO.MemoryStream
        $stderr = New-Object System.IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $pipe = $process.StandardInput.BaseStream
        if ($null -ne $Stdin -and $Stdin.Length -gt 0) { $pipe.Write($Stdin, 0, $Stdin.Length) }
        $pipe.Flush()
        $pipe.Close()
        $timedOut = -not $process.WaitForExit($ChildTimeoutMs)
        if ($timedOut) {
            try { & taskkill.exe /T /F /PID $process.Id 2>&1 | Out-Null } catch { }
            [void]$process.WaitForExit(10000)
        }
        [void]$outTask.Wait(5000)
        [void]$errTask.Wait(5000)
        $bytes = $stdout.ToArray()
        $text = ''
        try { $text = $StrictUtf8.GetString($bytes) } catch { $text = $Utf8.GetString($bytes) }
        $exit = -999
        if (-not $timedOut) { $exit = $process.ExitCode }
        return @{ Exit = $exit; Bytes = $bytes; Text = $text; Err = $Utf8.GetString($stderr.ToArray()); TimedOut = $timedOut }
    } finally { $process.Dispose() }
}

function Invoke-Native {
    <#
    .SYNOPSIS
      Run a statusline.ps1 copy on a payload with a coralline.conf.
    .PARAMETER Dir
      Folder of the copy.
    .PARAMETER Conf
      coralline.conf (CORALLINE_CONFIG).
    .PARAMETER Payload
      stdin text; $null for empty stdin.
    .PARAMETER Extra
      More environment.
    .PARAMETER Arguments
      Script arguments.
    .PARAMETER Cwd
      Working directory.
    .EXAMPLE
      Invoke-Native -Dir $Inst -Conf $conf -Payload '{}'
    #>
    param([string]$Dir, [string]$Conf, [string]$Payload, [hashtable]$Extra = @{}, [string[]]$Arguments = @(), [string]$Cwd = '')
    $environment = @{ CORALLINE_CONFIG = $Conf }
    foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
    $stdin = $null
    if ($null -ne $Payload) { $stdin = $Utf8.GetBytes($Payload) }
    return Invoke-Child -Script (Join-Path $Dir 'statusline.ps1') -Arguments $Arguments -Stdin $stdin -Extra $environment -Cwd $Cwd
}

function Invoke-Wrapper {
    <#
    .SYNOPSIS
      Run a statusline-omp.ps1 copy on a payload.
    .PARAMETER Script
      Wrapper path as given to -File.
    .PARAMETER Conf
      coralline.conf (CORALLINE_CONFIG).
    .PARAMETER Config
      -Config, or '' to leave it out.
    .PARAMETER OmpExe
      -OmpExe, or '' to leave it out.
    .PARAMETER FloatConfig
      -FloatConfig, or '' to leave it out.
    .PARAMETER Payload
      stdin text; $null for empty stdin.
    .PARAMETER Extra
      More environment.
    .PARAMETER Arguments
      More arguments after the named ones.
    .PARAMETER Cwd
      Working directory.
    .EXAMPLE
      Invoke-Wrapper -Script $WrapperScript -Conf $conf -Config $layout.Omp -OmpExe $InstOmp -Payload '{}'
    #>
    param([string]$Script, [string]$Conf, [string]$Config = '', [string]$OmpExe = '', [string]$FloatConfig = '', [string]$Payload,
        [hashtable]$Extra = @{}, [string[]]$Arguments = @(), [string]$Cwd = '')
    $argv = @()
    if ($Config -ne '') { $argv += @('-Config', $Config) }
    if ($OmpExe -ne '') { $argv += @('-OmpExe', $OmpExe) }
    if ($FloatConfig -ne '') { $argv += @('-FloatConfig', $FloatConfig) }
    $argv += $Arguments
    $environment = @{ CORALLINE_CONFIG = $Conf }
    foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
    $stdin = $null
    if ($null -ne $Payload) { $stdin = $Utf8.GetBytes($Payload) }
    return Invoke-Child -Script $Script -Arguments $argv -Stdin $stdin -Extra $environment -Cwd $Cwd
}

# ============================================================================================
# Cell comparison (ported from the S1 harness: SGR state per cell; a space compares on
# background only; clock digits masked) plus the documented 5.1 cost-rounding exception.
# ============================================================================================
function ConvertTo-Cells {
    <#
    .SYNOPSIS
      Interpret ANSI output into rows of comparable cells.
    .DESCRIPTION
      Handles SGR (reset, bold, inverse, default, 256-colour and truecolour
      foreground/background), skips OSC and other CSI sequences. A space cell keeps
      only its background; every other cell keeps character, foreground, background
      and bold. Trailing default-background spaces are dropped; empty rows too.
    .PARAMETER Text
      Raw renderer output.
    .EXAMPLE
      ConvertTo-Cells -Text "$([char]27)[38;5;1mx"
    #>
    param([string]$Text)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ([string]$Text -split "`n")) {
        $cells = New-Object 'System.Collections.Generic.List[string]'
        $fg = 'd'; $bg = 'd'; $bold = $false; $inverse = $false
        $i = 0
        while ($i -lt $line.Length) {
            $ch = $line[$i]
            if ($ch -eq $Esc) {
                $next = ''
                if ($i + 1 -lt $line.Length) { $next = [string]$line[$i + 1] }
                switch ($next) {
                    '[' {
                        $j = $i + 2
                        while ($j -lt $line.Length -and -not ([int]$line[$j] -ge 0x40 -and [int]$line[$j] -le 0x7E)) { $j++ }
                        if ($j -lt $line.Length -and $line[$j] -eq 'm') {
                            $params = @($line.Substring($i + 2, $j - $i - 2).Split(';') | ForEach-Object { if ($_ -eq '') { 0 } else { [int]$_ } })
                            $k = 0
                            while ($k -lt $params.Count) {
                                $p = $params[$k]
                                switch ($p) {
                                    0 { $fg = 'd'; $bg = 'd'; $bold = $false; $inverse = $false }
                                    1 { $bold = $true }
                                    22 { $bold = $false }
                                    7 { $inverse = $true }
                                    27 { $inverse = $false }
                                    39 { $fg = 'd' }
                                    49 { $bg = 'd' }
                                    38 {
                                        if ($params[$k + 1] -eq 5) { $fg = 'i' + $params[$k + 2]; $k += 2 }
                                        else { $fg = 'r' + $params[$k + 2] + ',' + $params[$k + 3] + ',' + $params[$k + 4]; $k += 4 }
                                    }
                                    48 {
                                        if ($params[$k + 1] -eq 5) { $bg = 'i' + $params[$k + 2]; $k += 2 }
                                        else { $bg = 'r' + $params[$k + 2] + ',' + $params[$k + 3] + ',' + $params[$k + 4]; $k += 4 }
                                    }
                                    default {
                                        if ($p -ge 30 -and $p -le 37) { $fg = 'a' + $p } elseif ($p -ge 40 -and $p -le 47) { $bg = 'a' + $p }
                                        elseif ($p -ge 90 -and $p -le 97) { $fg = 'a' + $p } elseif ($p -ge 100 -and $p -le 107) { $bg = 'a' + $p }
                                    }
                                }
                                $k++
                            }
                        }
                        $i = $j + 1
                    }
                    ']' {
                        $j = $i + 2
                        while ($j -lt $line.Length -and $line[$j] -ne [char]7 -and -not ($line[$j] -eq $Esc -and $j + 1 -lt $line.Length -and $line[$j + 1] -eq '\')) { $j++ }
                        if ($j -lt $line.Length -and $line[$j] -eq $Esc) { $j++ }
                        $i = $j + 1
                    }
                    default { $i += 2 }
                }
                continue
            }
            if ($ch -eq "`r") { $i++; continue }
            $glyph = [string]$ch
            if ([char]::IsHighSurrogate($ch) -and $i + 1 -lt $line.Length) { $glyph += $line[$i + 1]; $i++ }
            $f = $fg; $b = $bg
            if ($inverse) { $f = $bg; $b = $fg }
            if ([string]::Equals($glyph, ' ', [StringComparison]::Ordinal)) { [void]$cells.Add(' ' + $US + $b) } else { [void]$cells.Add($glyph + $US + $f + $US + $b + $US + $bold) }
            $i++
        }
        while ($cells.Count -gt 0 -and [string]::Equals($cells[$cells.Count - 1], (' ' + $US + 'd'), [StringComparison]::Ordinal)) { $cells.RemoveAt($cells.Count - 1) }
        if ($cells.Count -gt 0) { [void]$rows.Add($cells) }
    }
    return , $rows
}

function Get-MaskedRow {
    <#
    .SYNOPSIS
      Row cells with clock digits replaced so renders taken seconds apart compare equal.
    .PARAMETER Cells
      One row of cells.
    .EXAMPLE
      Get-MaskedRow -Cells $row
    #>
    param($Cells)
    $builder = New-Object System.Text.StringBuilder
    $owner = New-Object 'System.Collections.Generic.List[int]'
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($c = 0; $c -lt $Cells.Count; $c++) {
        [void]$out.Add($Cells[$c])
        $glyph = $Cells[$c].Substring(0, $Cells[$c].IndexOf($USChar))
        [void]$builder.Append($glyph)
        for ($k = 0; $k -lt $glyph.Length; $k++) { [void]$owner.Add($c) }
    }
    foreach ($m in [regex]::Matches($builder.ToString(), '\d\d:\d\d(:\d\d)?( [ap]m)?')) {
        for ($k = $m.Index; $k -lt $m.Index + $m.Length; $k++) {
            $cell = $out[$owner[$k]]
            $out[$owner[$k]] = 'T' + $cell.Substring($cell.IndexOf($USChar))
        }
    }
    return , $out
}

function Get-Plain {
    <#
    .SYNOPSIS
      Output without SGR sequences.
    .PARAMETER Text
      Output.
    .EXAMPLE
      Get-Plain -Text $run.Text
    #>
    param([string]$Text)
    return [regex]::Replace([string]$Text, '\x1b\[[0-9;]*m', '')
}

function Test-CostRoundingOnly {
    <#
    .SYNOPSIS
      True on 5.1 when two plain renders differ only in one $N.NN cost value by one unit in its last decimal.
    .DESCRIPTION
      S1 known difference 1: .NET Framework's F-format rounds some midpoints up where
      Oh-My-Posh (Go %.2f) and .NET Core round to the binary value. Payloads avoid
      midpoints; this keeps an unlucky value from being reported as a parity break.
    .PARAMETER Native
      Native plain text.
    .PARAMETER Engine
      Wrapper plain text.
    .EXAMPLE
      Test-CostRoundingOnly -Native '$0.13' -Engine '$0.12'
    #>
    param([string]$Native, [string]$Engine)
    if (-not $IsLegacyHost) { return $false }
    $pattern = '\$([0-9]+)\.([0-9]+)'
    $a = [regex]::Matches($Native, $pattern)
    $b = [regex]::Matches($Engine, $pattern)
    if ($a.Count -ne $b.Count -or $a.Count -eq 0) { return $false }
    if ([regex]::Replace($Native, $pattern, '$C') -cne [regex]::Replace($Engine, $pattern, '$C')) { return $false }
    $differences = 0
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i].Value -ceq $b[$i].Value) { continue }
        if ($a[$i].Groups[2].Length -ne $b[$i].Groups[2].Length) { return $false }
        $scale = [decimal][Math]::Pow(10, $a[$i].Groups[2].Length)
        $left = [decimal]::Parse($a[$i].Groups[1].Value + '.' + $a[$i].Groups[2].Value, $Invariant) * $scale
        $right = [decimal]::Parse($b[$i].Groups[1].Value + '.' + $b[$i].Groups[2].Value, $Invariant) * $scale
        if ([Math]::Abs($left - $right) -ne 1) { return $false }
        $differences++
    }
    return ($differences -eq 1)
}

function Compare-Render {
    <#
    .SYNOPSIS
      Cell-level comparison of a native and a wrapper render (row count included); '' when equal.
    .PARAMETER Native
      Native output.
    .PARAMETER Engine
      Wrapper output.
    .EXAMPLE
      Compare-Render -Native $a -Engine $b
    #>
    param([string]$Native, [string]$Engine)
    $a = ConvertTo-Cells $Native
    $b = ConvertTo-Cells $Engine
    if ($a.Count -ne $b.Count) { return ('row count native=' + $a.Count + ' wrapper=' + $b.Count + ' | native: ' + (Show-Text (Get-Plain $Native)) + ' | wrapper: ' + (Show-Text (Get-Plain $Engine))) }
    for ($r = 0; $r -lt $a.Count; $r++) {
        $ra = Get-MaskedRow $a[$r]
        $rb = Get-MaskedRow $b[$r]
        $n = [Math]::Max($ra.Count, $rb.Count)
        for ($c = 0; $c -lt $n; $c++) {
            $ca = '<end>'
            $cb = '<end>'
            if ($c -lt $ra.Count) { $ca = $ra[$c] }
            if ($c -lt $rb.Count) { $cb = $rb[$c] }
            if (-not [string]::Equals($ca, $cb, [StringComparison]::Ordinal)) {
                $plainA = -join @($ra | ForEach-Object { $_.Substring(0, $_.IndexOf($USChar)) })
                $plainB = -join @($rb | ForEach-Object { $_.Substring(0, $_.IndexOf($USChar)) })
                if (Test-CostRoundingOnly $plainA $plainB) { Add-Note ('cost rounding exception taken: native ' + $plainA + ' | wrapper ' + $plainB); break }
                return ('row ' + $r + ' cell ' + $c + ' native=[' + (Show-Text $ca) + '] wrapper=[' + (Show-Text $cb) + '] | native: ' + (Show-Text $plainA) + ' | wrapper: ' + (Show-Text $plainB))
            }
        }
    }
    return ''
}

function Get-RowCount {
    <#
    .SYNOPSIS
      Number of non-empty rendered rows.
    .PARAMETER Text
      Output.
    .EXAMPLE
      Get-RowCount -Text $run.Text
    #>
    param([string]$Text)
    return (ConvertTo-Cells $Text).Count
}

# ============================================================================================
# Fixtures
# ============================================================================================
function Assert-InsideTemp {
    <#
    .SYNOPSIS
      Throw unless a path, normalised the way statusline.ps1 normalises state and float paths, is inside the temporary root.
    .DESCRIPTION
      Run before every render that could write into the path (F3). A failure is
      recorded as FAIL X-target-inside-temp and the whole run stops.
    .PARAMETER Path
      Target that a render must not damage.
    .EXAMPLE
      Assert-InsideTemp -Path $target
    #>
    param([string]$Path)
    $full = ''
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { $full = '' }
    if ([string]::IsNullOrEmpty($full) -or -not $full.StartsWith($TempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Check 'X-target-inside-temp' $false ('target outside the temporary root: ' + $Path)
        throw ('refusing to run with a target outside the temporary root: ' + $Path)
    }
}

function New-Conf {
    <#
    .SYNOPSIS
      Write a coralline.conf into a folder, optionally with a theme copied next to it and included; returns its path.
    .PARAMETER Dir
      Folder.
    .PARAMETER Name
      File name without extension.
    .PARAMETER Lines
      Config lines.
    .PARAMETER Theme
      Theme name from themes\, or '' for none.
    .EXAMPLE
      New-Conf -Dir $d -Name coralline -Lines @("VL_SEGMENTS='model'") -Theme claude-coral
    #>
    param([string]$Dir, [string]$Name, [string[]]$Lines, [string]$Theme = '')
    [void][System.IO.Directory]::CreateDirectory($Dir)
    $text = ''
    if ($Theme -ne '') {
        [System.IO.File]::Copy((Join-Path $InstThemes ($Theme + '.conf')), (Join-Path $Dir ($Theme + '.conf')), $true)
        $text = '. "./' + $Theme + '.conf"' + "`n"
    }
    $text += ($Lines -join "`n") + "`n"
    $conf = Join-Path $Dir ($Name + '.conf')
    Write-Utf8 $conf $text
    return $conf
}

function Invoke-Generator {
    <#
    .SYNOPSIS
      Run the generator copy on a conf; returns @{ Exit; Err; Omp; Float; Auto }.
    .PARAMETER Conf
      coralline.conf.
    .PARAMETER Dir
      Output folder: coralline.omp.json, coralline.float.omp.json, coralline.auto.omp.json.
    .PARAMETER Placeholder
      Pass -AutoPlaceholder.
    .PARAMETER GeneratorDir
      Install folder whose tools\build-omp-config.ps1 runs.
    .EXAMPLE
      Invoke-Generator -Conf $conf -Dir $d
    #>
    param([string]$Conf, [string]$Dir, [switch]$Placeholder, [string]$GeneratorDir = $Inst)
    [void][System.IO.Directory]::CreateDirectory($Dir)
    $omp = Join-Path $Dir 'coralline.omp.json'
    $float = Join-Path $Dir 'coralline.float.omp.json'
    $auto = Join-Path $Dir 'coralline.auto.omp.json'
    $argv = @('-ConfigPath', $Conf, '-OutFile', $omp, '-FloatOutFile', $float, '-AutoOutFile', $auto)
    if ($Placeholder) { $argv += '-AutoPlaceholder' }
    $run = Invoke-Child -Script (Join-Path $GeneratorDir 'tools\build-omp-config.ps1') -Arguments $argv
    return @{ Exit = $run.Exit; Err = $run.Err; Omp = $omp; Float = $float; Auto = $auto; Dir = $Dir; Conf = $Conf }
}

function Get-Layout {
    <#
    .SYNOPSIS
      A generated layout, built once per name: @{ Conf; Omp; Float; Auto; Exit; Err; Dir }.
    .PARAMETER Name
      Layout name (its folder under layouts\).
    .PARAMETER Lines
      Config lines.
    .PARAMETER Theme
      Theme to include, or ''.
    .PARAMETER Placeholder
      Generate with -AutoPlaceholder.
    .EXAMPLE
      Get-Layout -Name pill -Lines @("VL_STYLE=pill") -Theme claude-coral
    #>
    param([string]$Name, [string[]]$Lines, [string]$Theme = '', [switch]$Placeholder)
    if ($script:Layouts.Contains($Name)) { return $script:Layouts[$Name] }
    $dir = Join-Path $TempRoot ('layouts\' + $Name)
    $conf = New-Conf $dir 'coralline' $Lines $Theme
    $layout = Invoke-Generator -Conf $conf -Dir $dir -Placeholder:$Placeholder
    $script:Layouts[$Name] = $layout
    return $layout
}

function Get-RatePayload {
    <#
    .SYNOPSIS
      Payload with a model and optional 5h / 7d windows (absolute epochs).
    .PARAMETER P5
      five_hour used_percentage JSON text, or ''.
    .PARAMETER R5
      five_hour resets_at.
    .PARAMETER P7
      seven_day used_percentage JSON text, or ''.
    .PARAMETER R7
      seven_day resets_at.
    .PARAMETER Model
      model.display_name.
    .EXAMPLE
      Get-RatePayload -P5 '40' -R5 1790009030
    #>
    param([string]$P5 = '', [long]$R5 = 0, [string]$P7 = '', [long]$R7 = 0, [string]$Model = 'Opus')
    $parts = @('"model":{"display_name":' + (ConvertTo-JsonLiteral $Model) + '}')
    $limits = @()
    if ($P5 -ne '') { $limits += ('"five_hour":{"used_percentage":' + $P5 + ',"resets_at":' + $R5.ToString($Invariant) + '}') }
    if ($P7 -ne '') { $limits += ('"seven_day":{"used_percentage":' + $P7 + ',"resets_at":' + $R7.ToString($Invariant) + '}') }
    if ($limits.Count -gt 0) { $parts += ('"rate_limits":{' + ($limits -join ',') + '}') }
    return '{' + ($parts -join ',') + '}'
}

function Get-StoreSnapshot {
    <#
    .SYNOPSIS
      Byte-exact description of a store folder: burn.tsv bytes, rl5.d / rl7.d entry names, anything else.
    .PARAMETER Dir
      Store folder.
    .EXAMPLE
      Get-StoreSnapshot -Dir $storeA
    #>
    param([string]$Dir)
    if (-not [System.IO.Directory]::Exists($Dir)) { return '<no store folder>' }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $tsv = Join-Path $Dir 'burn.tsv'
    switch ([System.IO.File]::Exists($tsv)) {
        $true { [void]$parts.Add('burn.tsv=[' + (Show-Text ($Utf8.GetString([System.IO.File]::ReadAllBytes($tsv)))) + ']') }
        default { [void]$parts.Add('burn.tsv=<absent>') }
    }
    foreach ($root in @('rl5.d', 'rl7.d')) {
        $path = Join-Path $Dir $root
        if (-not [System.IO.Directory]::Exists($path)) { [void]$parts.Add($root + '=<absent>'); continue }
        $names = @([System.IO.Directory]::GetFileSystemEntries($path) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        [void]$parts.Add($root + '=[' + ($names -join ',') + ']')
    }
    $other = @([System.IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Where-Object { @('burn.tsv', 'rl5.d', 'rl7.d') -notcontains $_ })
    [Array]::Sort($other, [StringComparer]::Ordinal)
    [void]$parts.Add('other=[' + ($other -join ',') + ']')
    return ($parts -join ' ; ')
}

function Get-StoreLines {
    <#
    .SYNOPSIS
      BURN_FILE / RL5H_FILE / RL7D_FILE lines for a store folder.
    .PARAMETER Dir
      Store folder.
    .PARAMETER BurnFile
      BURN_FILE override, or '' for <Dir>\burn.tsv.
    .EXAMPLE
      Get-StoreLines -Dir $storeA
    #>
    param([string]$Dir, [string]$BurnFile = '')
    if ($BurnFile -eq '') { $BurnFile = Join-Path $Dir 'burn.tsv' }
    return @(("BURN_FILE='" + $BurnFile + "'"), ("RL5H_FILE='" + (Join-Path $Dir 'rl5.tsv') + "'"), ("RL7D_FILE='" + (Join-Path $Dir 'rl7.tsv') + "'"))
}

function Set-Pinned {
    <#
    .SYNOPSIS
      Rewrite the pinned renderer copies with $Now (and the subagent $now) fixed to one second.
    .PARAMETER Second
      Unix time.
    .EXAMPLE
      Set-Pinned -Second 1790000000
    #>
    param([long]$Second)
    $pinLine = '$Now = [long]' + $Second.ToString($Invariant)
    $pinLineSubagent = '$now = [long]' + $Second.ToString($Invariant)
    Write-Utf8 (Join-Path $Pin 'statusline.ps1') ($NativeSource.Replace($NowLine, $pinLine).Replace($NowLineSubagent, $pinLineSubagent))
    Write-Utf8 (Join-Path $Pin 'statusline-omp.ps1') ($WrapperSource.Replace($NowLine, $pinLine))
}

function Get-MutatedText {
    <#
    .SYNOPSIS
      Source with each anchored replacement applied; throws when an anchor is not found exactly once.
    .PARAMETER Source
      Text.
    .PARAMETER Edits
      Pairs @(anchor, replacement).
    .EXAMPLE
      Get-MutatedText -Source $s -Edits @(,@('a', 'b'))
    #>
    param([string]$Source, [object[]]$Edits)
    $text = $Source
    foreach ($edit in $Edits) {
        $anchor = [string]$edit[0]
        $count = ([regex]::Matches($text, [regex]::Escape($anchor))).Count
        if ($count -ne 1) { throw ('mutation anchor found ' + $count + ' times: ' + $anchor) }
        $text = $text.Replace($anchor, [string]$edit[1])
    }
    return $text
}

function Get-AliasWitness {
    <#
    .SYNOPSIS
      Attributes, length and reparse tag of the oh-my-posh entry on PATH, without reading its content.
    .PARAMETER Path
      PATH hit, or ''.
    .EXAMPLE
      Get-AliasWitness -Path $PathOmp
    #>
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return 'none' }
    try {
        $info = New-Object System.IO.FileInfo($Path)
        if (-not $info.Exists) { return 'missing' }
        $tag = ''
        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $query = (& fsutil.exe reparsepoint query $Path 2>&1 | Out-String)
            $tag = ([regex]::Match($query, '0x[0-9a-fA-F]{8}')).Value
        }
        return ('attrs=' + [string]$info.Attributes + ' length=' + [string]$info.Length + ' tag=' + $tag)
    } catch { return ('error: ' + $_.Exception.Message) }
}

# ============================================================================================
# H helpers: executable enumeration and integer-setting checks, ported from the S3 harness
# (parts G and H). They read the wrapper's helper functions from the copy under test.
# ============================================================================================
$Automatic = @('true', 'false', 'null', '_', 'PSItem', 'args', 'input', 'this', 'PID', 'HOME', 'MyInvocation', 'PSVersionTable', 'Error', 'LASTEXITCODE',
    'Matches', 'PSScriptRoot', 'PSCommandPath', 'Host', 'ExecutionContext', 'PWD', 'ShellId', 'PSCulture', 'PSUICulture', 'PSBoundParameters', 'PSCmdlet', 'StackTrace')
$HExempt = @('BURN_SLACK', 'BURN_TRIM', 'CORALLINE_BURN_WINDOW', 'VL_WRAP_MARGIN')
$HStripText = 'foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars ([string]$Cfg[$key]) }'
$HHotWarnStart = 'if ([int]$Cfg.VL_HOT_PCT -lt [int]$Cfg.VL_WARN_PCT)'

function Get-FunctionNode {
    <#
    .SYNOPSIS
      The one function definition with this name in an AST, or throws.
    .PARAMETER Ast
      Parsed script.
    .PARAMETER Name
      Function name.
    .EXAMPLE
      Get-FunctionNode -Ast $wrapperAst -Name 'Get-OmpState'
    #>
    param($Ast, [string]$Name)
    $found = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true))
    if ($found.Count -ne 1) { throw ('expected one function ' + $Name + ', found ' + $found.Count) }
    return $found[0]
}

function Get-ListLiteral {
    <#
    .SYNOPSIS
      The string constants on the right of the one assignment to Variable inside Scope.
    .PARAMETER Scope
      AST node to search.
    .PARAMETER Variable
      Left side text, e.g. '$ompConfigNames'.
    .EXAMPLE
      Get-ListLiteral -Scope $ompState -Variable '$ompStateNames'
    #>
    param($Scope, [string]$Variable)
    $found = @($Scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Variable }, $true))
    if ($found.Count -ne 1) { throw ('expected one assignment of ' + $Variable + ', found ' + $found.Count) }
    return @($found[0].Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { [string]$_.Value })
}

function Get-BoundNames {
    <#
    .SYNOPSIS
      Names listed in a foreach loop whose body calls the given binder.
    .PARAMETER Scope
      AST node to search.
    .PARAMETER Binder
      Command name.
    .EXAMPLE
      Get-BoundNames -Scope $ompState -Binder 'Get-StatuslineBinding'
    #>
    param($Scope, [string]$Binder)
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($loop in $Scope.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) {
        $calls = @($loop.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -eq $Binder }, $true))
        if ($calls.Count -eq 0) { continue }
        foreach ($constant in $loop.Condition.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) { [void]$names.Add([string]$constant.Value) }
    }
    return $names.ToArray()
}

function Get-DefinedNames {
    <#
    .SYNOPSIS
      Names a node defines itself: parameters, assignment targets and foreach variables at any depth.
    .PARAMETER Node
      Function definition or parsed block.
    .EXAMPLE
      Get-DefinedNames -Node $fn
    #>
    param($Node)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) { [void]$set.Add((Get-AstVariableName $p.Name)) }
    foreach ($a in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $targets = @($a.Left)
        if ($a.Left -is [System.Management.Automation.Language.ArrayLiteralAst]) { $targets = @($a.Left.Elements) }
        foreach ($t in $targets) {
            while ($t -is [System.Management.Automation.Language.AttributedExpressionAst]) { $t = $t.Child }
            if ($t -is [System.Management.Automation.Language.VariableExpressionAst] -and -not $t.VariablePath.IsScript -and -not $t.VariablePath.IsGlobal) { [void]$set.Add((Get-AstVariableName $t)) }
        }
    }
    foreach ($f in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { [void]$set.Add((Get-AstVariableName $f.Variable)) }
    return , $set
}

function Add-FreeReads {
    <#
    .SYNOPSIS
      Add a node's reads of variables it does not define itself to Reads (name -> readers).
    .PARAMETER Node
      Function definition or parsed block.
    .PARAMETER Defined
      Names the node defines.
    .PARAMETER Reader
      Label for the node.
    .PARAMETER Reads
      Ordered dictionary to add to.
    .EXAMPLE
      Add-FreeReads -Node $fn -Defined $set -Reader 'Read-BurnState' -Reads $reads
    #>
    param($Node, $Defined, [string]$Reader, $Reads)
    foreach ($v in $Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $path = $v.VariablePath
        $name = Get-AstVariableName $v
        $key = ''
        switch ($true) {
            { $path.IsDriveQualified -and $path.DriveName -eq 'env' } { $key = 'env:' + $name.Substring(4); break }
            { $path.IsDriveQualified -and $path.DriveName -ne 'variable' } { $key = 'drive:' + $path.UserPath; break }
            { $Automatic -contains $name } { $key = ''; break }
            { $path.IsScript -or $path.IsGlobal } { $key = 'script:' + $name; break }
            { $Defined.Contains($name) } { $key = ''; break }
            default { $key = $name }
        }
        if ($key -eq '') { continue }
        $matchKey = $null
        foreach ($existing in $Reads.Keys) { if ([string]::Equals([string]$existing, $key, [StringComparison]::OrdinalIgnoreCase)) { $matchKey = $existing } }
        if ($null -eq $matchKey) { $Reads[$key] = New-Object 'System.Collections.Generic.List[string]'; $matchKey = $key }
        if (-not $Reads[$matchKey].Contains($Reader)) { [void]$Reads[$matchKey].Add($Reader) }
    }
}

function Test-BindingSource {
    <#
    .SYNOPSIS
      '' when the claimed binding source really binds the variable, otherwise why not.
    .PARAMETER Kind
      wrapper-script, wrapper-fn:<Function>, block, binding-r3:<Function>, binding-r7:<Function>, config-block or env.
    .PARAMETER Name
      Variable name (env:X for environment variables).
    .PARAMETER BlockDefined
      Names the stage's extracted statements define.
    .EXAMPLE
      Test-BindingSource -Kind 'wrapper-script' -Name 'Now' -BlockDefined $set
    #>
    param([string]$Kind, [string]$Name, $BlockDefined)
    $scriptAssigns = {
        param($Ast, [string]$Var)
        foreach ($s in $Ast.EndBlock.Statements) {
            if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and $s.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $s.Left.VariablePath.IsUnqualified -and [string]::Equals((Get-AstVariableName $s.Left), $Var, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        if ($null -ne $Ast.ParamBlock) { foreach ($p in $Ast.ParamBlock.Parameters) { if ([string]::Equals((Get-AstVariableName $p.Name), $Var, [StringComparison]::OrdinalIgnoreCase)) { return $true } } }
        return $false
    }
    $parts = $Kind.Split([string[]]@(':'), 2, [StringSplitOptions]::None)
    switch ($parts[0]) {
        'env' { if ($Name.StartsWith('env:', [StringComparison]::OrdinalIgnoreCase)) { return '' }; return 'not an environment variable' }
        'wrapper-script' { if (& $scriptAssigns $script:HWrapperAst $Name) { return '' }; return 'statusline-omp.ps1 does not assign it at script level' }
        'wrapper-fn' { if ((Get-DefinedNames (Get-FunctionNode $script:HWrapperAst $parts[1])).Contains($Name)) { return '' }; return ($parts[1] + ' does not assign it') }
        'block' { if ($BlockDefined.Contains($Name)) { return '' }; return 'the extracted statements do not assign it' }
        'binding-r3' {
            $fn = Get-FunctionNode $script:HWrapperAst $parts[1]
            if (@(Get-BoundNames $fn 'Get-StatuslineBinding') -notcontains $Name) { return ($parts[1] + ' does not bind it through Get-StatuslineBinding') }
            if (-not ($fn.Extent.Text.Contains('$ompBindingOk.' + $Name + ' = ') -or $fn.Extent.Text.Contains('$ompStateOk.' + $Name + ' = '))) { return ($parts[1] + ' binds it without a check') }
            return ''
        }
        'binding-r7' {
            $fn = Get-FunctionNode $script:HWrapperAst $parts[1]
            $call = $fn.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]$n.GetCommandName() -eq 'Get-StatuslineHomeBinding' }, $true)
            if ($Name -ne 'HomeDir' -or $null -eq $call -or -not $fn.Extent.Text.Contains('$ompBindingOk.HomeDir = ')) { return ($parts[1] + ' does not bind it through Get-StatuslineHomeBinding with a check') }
            return ''
        }
        'config-block' {
            if ($null -ne $script:HConfigBlockDefined -and $script:HConfigBlockDefined.Contains($Name)) { return '' }
            return 'not defined anywhere in the config-stage blocks'
        }
    }
    return ('unknown source kind ' + $Kind)
}

function Get-StageSpecs {
    <#
    .SYNOPSIS
      The config, state and display stages the wrapper extracts from a statusline.ps1 AST.
    .DESCRIPTION
      Each spec: Functions (extracted names), Blocks (extracted statement texts, $null
      for one that cannot be located) and Sources (variable -> binding source kind).
    .PARAMETER NativeAst
      Parsed statusline.ps1.
    .EXAMPLE
      Get-StageSpecs -NativeAst $nativeAst
    #>
    param($NativeAst)
    $ompState = Get-FunctionNode $script:HWrapperAst 'Get-OmpState'
    $configCode = Get-StatuslineConfigCode $NativeAst
    $configBlocks = @((Get-StatuslineHomeBinding $NativeAst))
    $configBound = @(Get-BoundNames $ompState 'Get-StatuslineBinding' | Where-Object { $_ -like 'Shell*' })
    $stateBound = @(Get-BoundNames $ompState 'Get-StatuslineBinding' | Where-Object { $_ -notlike 'Shell*' })
    foreach ($name in $configBound) { $configBlocks += (Get-StatuslineBinding $NativeAst $name) }
    $configBlocks += $(if ($null -ne $configCode) { $configCode.Defaults } else { $null })
    $configBlocks += $(if ($null -ne $configCode) { $configCode.Config } else { $null })
    $stateBlocks = @()
    foreach ($name in $stateBound) { $stateBlocks += (Get-StatuslineBinding $NativeAst $name) }
    $stateBlocks += (Select-StatuslineStatements $NativeAst (Get-ListLiteral $ompState '$ompGateStarts'))
    $configSources = @{
        HomeDir = 'binding-r7:Get-OmpState'; StrictUtf8 = 'wrapper-script'; Invariant = 'wrapper-script'; IntegerStyle = 'wrapper-script'
        ScriptDir = 'wrapper-fn:Get-OmpState'; ConfigKeys = 'block'; PathConfigKeys = 'block'
        'env:CLAUDE_CONFIG_DIR' = 'env'; 'env:CORALLINE_BURN_FILE' = 'env'; 'env:CORALLINE_RL5H_FILE' = 'env'; 'env:CORALLINE_RL7D_FILE' = 'env'
        'env:CORALLINE_CONFIG' = 'env'; 'env:REMORA_ACTIVE' = 'env'
    }
    foreach ($name in $configBound) { $configSources[$name] = 'binding-r3:Get-OmpState' }
    $stateSources = @{}
    foreach ($key in $configSources.Keys) { $stateSources[$key] = $configSources[$key] }
    foreach ($name in $stateBound) { $stateSources[$name] = 'binding-r3:Get-OmpState' }
    foreach ($name in @('Now', 'Utf8NoBom', 'FloatStyle')) { $stateSources[$name] = 'wrapper-script' }
    foreach ($name in @('ScriptPath', 'fhPct', 'fhRst', 'wdPct', 'wdRst')) { $stateSources[$name] = 'wrapper-fn:Get-OmpState' }
    foreach ($name in @('Cfg', 'ConfigPath', 'ConfigVisitedPaths')) { $stateSources[$name] = 'block' }
    $stateSources['env:CORALLINE_NO_SAMPLE'] = 'env'
    $configNames = Get-ListLiteral $ompState '$ompConfigNames'
    $displayCode = Select-StatuslineDisplayStage $NativeAst
    $script:HConfigBlockDefined = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($text in $configBlocks) {
        if ([string]::IsNullOrEmpty([string]$text)) { continue }
        $configBlockAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$text, [ref]$null, [ref]$null)
        foreach ($definedName in (Get-DefinedNames $configBlockAst)) { [void]$script:HConfigBlockDefined.Add($definedName) }
    }
    $displaySources = @{}
    foreach ($key in $configSources.Keys) { $displaySources[$key] = $configSources[$key] }
    foreach ($key in @('Cfg', 'ConfigAssignments', 'Defaults')) { $displaySources[$key] = 'config-block' }
    return [ordered]@{
        config = @{ Functions = $configNames; Blocks = $configBlocks; Sources = $configSources }
        state = @{ Functions = (@($configNames) + @(Get-ListLiteral $ompState '$ompStateNames')); Blocks = (@($configBlocks) + @($stateBlocks)); Sources = $stateSources }
        display = @{ Functions = @('Get-BoundedInt', 'Test-Color', 'Remove-ControlChars'); Blocks = @($displayCode); Sources = $displaySources }
    }
}

function Get-StageReport {
    <#
    .SYNOPSIS
      Enumerate one stage: functions not defined exactly once at top level, native calls outside the stage, free variables without a verified source.
    .PARAMETER NativeAst
      Parsed statusline.ps1.
    .PARAMETER Spec
      One entry of Get-StageSpecs.
    .EXAMPLE
      Get-StageReport -NativeAst $nativeAst -Spec $specs.state
    #>
    param($NativeAst, $Spec)
    $nativeFns = @{}
    foreach ($f in $NativeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $key = $f.Name.ToLowerInvariant()
        if (-not $nativeFns.ContainsKey($key)) { $nativeFns[$key] = New-Object 'System.Collections.Generic.List[object]' }
        [void]$nativeFns[$key].Add($f)
    }
    $visible = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($Spec.Functions)) { [void]$visible.Add($name) }
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $calls = New-Object 'System.Collections.Generic.List[string]'
    $reads = [ordered]@{}
    $nodes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $Spec.Functions) {
        $defs = $nativeFns[$name.ToLowerInvariant()]
        if ($null -eq $defs -or $defs.Count -ne 1 -or -not [object]::ReferenceEquals($defs[0].Parent, $NativeAst.EndBlock)) { [void]$problems.Add('function ' + $name + ' is not defined exactly once at top level'); continue }
        Add-FreeReads $defs[0] (Get-DefinedNames $defs[0]) $name $reads
        [void]$nodes.Add(@{ Node = $defs[0]; Label = $name })
    }
    $blockDefined = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $blockAsts = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    foreach ($text in $Spec.Blocks) {
        $index++
        if ([string]::IsNullOrEmpty([string]$text)) { [void]$problems.Add('extracted statements #' + $index + ' cannot be located'); continue }
        $errors = $null
        $block = [System.Management.Automation.Language.Parser]::ParseInput([string]$text, [ref]$null, [ref]$errors)
        if ($errors.Count -ne 0) { [void]$problems.Add('extracted statements #' + $index + ' do not parse'); continue }
        foreach ($name in (Get-DefinedNames $block)) { [void]$blockDefined.Add($name) }
        [void]$blockAsts.Add($block)
        [void]$nodes.Add(@{ Node = $block; Label = '<statements #' + $index + '>' })
    }
    foreach ($block in $blockAsts) { Add-FreeReads $block $blockDefined '<statements>' $reads }
    foreach ($item in $nodes) {
        foreach ($c in $item.Node.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = [string]$c.GetCommandName()
            if ($name -eq '' -or -not $nativeFns.ContainsKey($name.ToLowerInvariant()) -or $visible.Contains($name)) { continue }
            $entry = $item.Label + ' -> ' + $name
            if (-not $calls.Contains($entry)) { [void]$calls.Add($entry) }
        }
    }
    $unbound = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $reads.Keys) {
        $source = $null
        foreach ($claimed in $Spec.Sources.Keys) { if ([string]::Equals([string]$claimed, [string]$key, [StringComparison]::OrdinalIgnoreCase)) { $source = [string]$Spec.Sources[$claimed] } }
        $why = 'no binding source'
        if ($null -ne $source) { $why = Test-BindingSource $source ([string]$key) $blockDefined }
        if ($why -ne '') { [void]$unbound.Add([string]$key + ' (' + $why + '; read by ' + ($reads[$key] -join ',') + ')') }
    }
    return @{ Problems = $problems; Calls = $calls; Unbound = $unbound }
}

function Test-HCallsCommand {
    <#
    .SYNOPSIS
      True when a node holds, at any depth, a command with the given name (compared without case).
    .PARAMETER Node
      AST node.
    .PARAMETER Name
      Command name.
    .EXAMPLE
      Test-HCallsCommand -Node $statement -Name 'Get-BoundedInt'
    #>
    param($Node, [string]$Name)
    $hit = $Node.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]::Equals([string]$n.GetCommandName(), $Name, [StringComparison]::OrdinalIgnoreCase) }, $true)
    return ($null -ne $hit)
}

function Get-HBoundedStatements {
    <#
    .SYNOPSIS
      The script body's statements (function definitions aside) that call Get-BoundedInt, in order: @{ Index; Text; Key }.
    .PARAMETER Ast
      Parsed script.
    .EXAMPLE
      Get-HBoundedStatements -Ast $nativeAst
    #>
    param($Ast)
    $found = New-Object 'System.Collections.Generic.List[object]'
    $statements = $Ast.EndBlock.Statements
    for ($i = 0; $i -lt $statements.Count; $i++) {
        $s = $statements[$i]
        if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
        if (-not (Test-HCallsCommand $s 'Get-BoundedInt')) { continue }
        $text = [string]$s.Extent.Text
        $key = '<unkeyed:' + $text.Substring(0, [Math]::Min(60, $text.Length)) + '>'
        if ($s -is [System.Management.Automation.Language.AssignmentStatementAst] -and $s.Left -is [System.Management.Automation.Language.MemberExpressionAst] -and
            [string]$s.Left.Expression.Extent.Text -ceq '$Cfg' -and $s.Left.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $key = [string]$s.Left.Member.Value }
        [void]$found.Add(@{ Index = $i; Text = $text; Key = $key })
    }
    return $found.ToArray()
}

function Get-HOrder {
    <#
    .SYNOPSIS
      '' when the file has exactly one Remove-ControlChars pass over $Cfg, at script level, after every Get-BoundedInt statement and the VL_HOT_PCT / VL_WARN_PCT check and before the first Test-Color loop; otherwise why not.
    .PARAMETER Ast
      Parsed script.
    .EXAMPLE
      Get-HOrder -Ast $generatorAst
    #>
    param($Ast)
    $loops = @($Ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.ForEachStatementAst] -and (Test-HCallsCommand $n.Body 'Remove-ControlChars') -and
                $null -ne $n.Body.Find({ param($m) $m -is [System.Management.Automation.Language.AssignmentStatementAst] -and ([string]$m.Left.Extent.Text).StartsWith('$Cfg[', [StringComparison]::Ordinal) }, $true)
            }, $true))
    if ($loops.Count -ne 1) { return ('Remove-ControlChars passes over $Cfg: ' + $loops.Count + ', expected exactly one') }
    $statements = @($Ast.EndBlock.Statements)
    $strip = -1
    $hotWarn = @()
    $firstColor = -1
    for ($i = 0; $i -lt $statements.Count; $i++) {
        if ([object]::ReferenceEquals($statements[$i], $loops[0])) { $strip = $i }
        if ($statements[$i] -is [System.Management.Automation.Language.IfStatementAst] -and ([string]$statements[$i].Extent.Text).StartsWith($HHotWarnStart, [StringComparison]::Ordinal)) { $hotWarn += $i }
        if ($firstColor -lt 0 -and $statements[$i] -is [System.Management.Automation.Language.ForEachStatementAst] -and (Test-HCallsCommand $statements[$i].Body 'Test-Color')) { $firstColor = $i }
    }
    $bounded = @(Get-HBoundedStatements $Ast)
    switch ($true) {
        { $strip -lt 0 } { return 'the Remove-ControlChars pass is not a script-level statement' }
        { $bounded.Count -eq 0 } { return 'no Get-BoundedInt statement to anchor on' }
        { $hotWarn.Count -ne 1 } { return ('VL_HOT_PCT / VL_WARN_PCT checks at script level: ' + $hotWarn.Count + ', expected exactly one') }
        { $firstColor -lt 0 } { return 'no Test-Color loop to anchor on' }
        { $strip -lt $bounded[$bounded.Count - 1].Index } { return ('the Remove-ControlChars pass comes before the last Get-BoundedInt statement') }
        { $strip -lt $hotWarn[0] } { return ('the Remove-ControlChars pass comes before the VL_HOT_PCT / VL_WARN_PCT check') }
        { $strip -gt $firstColor } { return ('the Remove-ControlChars pass comes after the first Test-Color loop') }
    }
    return ''
}

function Get-HCallDiff {
    <#
    .SYNOPSIS
      '' when every Get-BoundedInt call passes exactly ParamCount positional arguments with a literal MaxLen of 1 to 9; otherwise why not.
    .PARAMETER Ast
      Parsed script.
    .PARAMETER ParamCount
      Parameters of statusline.ps1's Get-BoundedInt.
    .PARAMETER MaxLenAt
      Zero-based position of its MaxLen parameter.
    .PARAMETER Label
      File label for the reason.
    .EXAMPLE
      Get-HCallDiff -Ast $generatorAst -ParamCount 5 -MaxLenAt 4 -Label generator
    #>
    param($Ast, [int]$ParamCount, [int]$MaxLenAt, [string]$Label)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $calls = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and [string]::Equals([string]$n.GetCommandName(), 'Get-BoundedInt', [StringComparison]::OrdinalIgnoreCase) }, $true))
    foreach ($call in $calls) {
        $arguments = @($call.CommandElements | Select-Object -Skip 1)
        $where = $Label + ' line ' + $call.Extent.StartLineNumber
        $named = @($arguments | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })
        $splatted = @($arguments | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.Splatted })
        switch ($true) {
            { $named.Count -gt 0 } { [void]$problems.Add($where + ': named argument ' + $named[0].Extent.Text); break }
            { $splatted.Count -gt 0 } { [void]$problems.Add($where + ': splatted ' + $splatted[0].Extent.Text); break }
            { $arguments.Count -ne $ParamCount } { [void]$problems.Add($where + ': ' + $arguments.Count + ' arguments, statusline.ps1 defines ' + $ParamCount); break }
            default {
                $maxLen = $arguments[$MaxLenAt]
                $literal = ($maxLen -is [System.Management.Automation.Language.ConstantExpressionAst] -and $maxLen -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and $maxLen.Value -is [int])
                if (-not $literal -or [int]$maxLen.Value -lt 1 -or [int]$maxLen.Value -gt 9) { [void]$problems.Add($where + ': MaxLen ' + $maxLen.Extent.Text + ' is not a literal from 1 to 9') }
            }
        }
    }
    return ($problems -join '; ')
}

function Get-HStaticReport {
    <#
    .SYNOPSIS
      The integer-setting checks (Z2, Z3, Z4, E3) for one statusline.ps1 / generator / wrapper triple: check ID -> '' or why it fails.
    .PARAMETER NativeAst
      Parsed statusline.ps1.
    .PARAMETER GeneratorAst
      Parsed generator.
    .PARAMETER WrapperAst
      Parsed wrapper.
    .EXAMPLE
      Get-HStaticReport -NativeAst $n -GeneratorAst $g -WrapperAst $w
    #>
    param($NativeAst, $GeneratorAst, $WrapperAst)
    $out = [ordered]@{}
    $nBounded = @(Get-HBoundedStatements $NativeAst)
    $gBounded = @(Get-HBoundedStatements $GeneratorAst)
    $nTexts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($b in $nBounded) { [void]$nTexts.Add($b.Text) }
    $gTexts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($b in $gBounded) { [void]$gTexts.Add($b.Text) }
    $missing = @($gBounded | Where-Object { -not $nTexts.Contains($_.Text) } | ForEach-Object { $_.Key })
    $out['H-z2-generator-verbatim'] = $(switch ($true) {
            { $gBounded.Count -eq 0 } { 'the generator has no Get-BoundedInt statement'; break }
            { $missing.Count -gt 0 } { 'not verbatim in statusline.ps1: ' + ($missing -join ','); break }
            default { '' }
        })
    $extra = @($nBounded | Where-Object { -not $gTexts.Contains($_.Text) } | ForEach-Object { $_.Key })
    [Array]::Sort($extra, [StringComparer]::Ordinal)
    $out['H-z2-statusline-minus-generator'] = $(if (($extra -join ',') -cne ($HExempt -join ',')) { 'statusline.ps1 only: [' + ($extra -join ',') + '], exempt: [' + ($HExempt -join ',') + ']' } else { '' })
    $out['H-z3-statusline-strip-once'] = Get-HOrder $NativeAst
    $out['H-z3-generator-strip-once'] = Get-HOrder $GeneratorAst
    $nHot = @($NativeAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and ([string]$_.Extent.Text).StartsWith($HHotWarnStart, [StringComparison]::Ordinal) })
    $gHot = @($GeneratorAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and ([string]$_.Extent.Text).StartsWith($HHotWarnStart, [StringComparison]::Ordinal) })
    $out['H-z3-hot-warn-verbatim'] = $(if ($nHot.Count -ne 1 -or $gHot.Count -ne 1 -or [string]$nHot[0].Extent.Text -cne [string]$gHot[0].Extent.Text) { 'statusline.ps1 checks=' + $nHot.Count + ' generator checks=' + $gHot.Count + ' (or their text differs)' } else { '' })
    $defs = @($NativeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and [string]::Equals($n.Name, 'Get-BoundedInt', [StringComparison]::OrdinalIgnoreCase) }, $true))
    $paramCount = -1
    $maxLenAt = -1
    if ($defs.Count -eq 1 -and [object]::ReferenceEquals($defs[0].Parent, $NativeAst.EndBlock)) {
        $params = @($defs[0].Parameters)
        if ($params.Count -eq 0 -and $null -ne $defs[0].Body.ParamBlock) { $params = @($defs[0].Body.ParamBlock.Parameters) }
        $paramCount = $params.Count
        for ($i = 0; $i -lt $params.Count; $i++) { if ([string]::Equals([string]$params[$i].Name.VariablePath.UserPath, 'MaxLen', [StringComparison]::OrdinalIgnoreCase)) { $maxLenAt = $i } }
    }
    $out['H-z4-definition'] = $(if ($paramCount -lt 0 -or $maxLenAt -lt 0) { 'definitions=' + $defs.Count + ' (script level required), MaxLen parameter at ' + $maxLenAt } else { '' })
    $out['H-z4-generator-calls'] = $(if ($paramCount -lt 0 -or $maxLenAt -lt 0) { 'no usable definition' } else { Get-HCallDiff $GeneratorAst $paramCount $maxLenAt 'generator' })
    $out['H-z4-wrapper-calls'] = $(if ($paramCount -lt 0 -or $maxLenAt -lt 0) { 'no usable definition' } else { Get-HCallDiff $WrapperAst $paramCount $maxLenAt 'wrapper' })
    $e3 = ''
    $code = Get-StatuslineConfigCode $NativeAst
    switch ($true) {
        { $null -eq $code } { $e3 = 'Get-StatuslineConfigCode found no config code'; break }
        default {
            $cAst = [System.Management.Automation.Language.Parser]::ParseInput([string]$code.Config, [ref]$null, [ref]$null)
            $cStatements = @($cAst.EndBlock.Statements)
            $cBounded = @(Get-HBoundedStatements $cAst)
            $firstBounded = -1
            if ($cBounded.Count -gt 0) { $firstBounded = $cBounded[0].Index }
            $styleAt = @()
            foreach ($start in @('$Invariant = ', '$IntegerStyle = ', '$FloatStyle = ')) {
                $at = @(for ($i = 0; $i -lt $cStatements.Count; $i++) { if (([string]$cStatements[$i].Extent.Text).StartsWith($start, [StringComparison]::Ordinal)) { $i } })
                $styleAt += $(if ($at.Count -eq 1) { $at[0] } else { -1 })
            }
            $cHot = @($cStatements | Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] -and ([string]$_.Extent.Text).StartsWith($HHotWarnStart, [StringComparison]::Ordinal) })
            $cColor = @($cStatements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and (Test-HCallsCommand $_.Body 'Test-Color') })
            $reasons = @(
                $(if ((@($cBounded | ForEach-Object { $_.Text }) -join "`n") -cne (@($nBounded | ForEach-Object { $_.Text }) -join "`n")) { 'Get-BoundedInt statements differ from statusline.ps1' } else { '' }),
                $(if (@($styleAt | Where-Object { $_ -lt 0 -or $_ -gt $firstBounded }).Count -gt 0) { '$Invariant / $IntegerStyle / $FloatStyle not each once before the first Get-BoundedInt statement' } else { '' }),
                $(if ($nHot.Count -ne 1 -or $cHot.Count -ne 1 -or [string]$cHot[0].Extent.Text -cne [string]$nHot[0].Extent.Text) { 'the VL_HOT_PCT / VL_WARN_PCT check is not there verbatim' } else { '' }),
                $(if ($cStatements.Count -eq 0 -or [string]$cStatements[$cStatements.Count - 1].Extent.Text -cne $HStripText) { 'the config code does not end with the Remove-ControlChars pass' } else { '' }),
                $(if ($cColor.Count -ne 0) { 'the config code reaches a Test-Color loop' } else { '' }))
            foreach ($reason in $reasons) { if ($e3 -eq '' -and $reason -ne '') { $e3 = $reason } }
        }
    }
    $out['H-e3-config-code-integer-block'] = $e3
    return $out
}

# ============================================================================================
# Mutations (J2: applied to the copies under test in the temporary root)
# ============================================================================================
$MutationSpecs = [ordered]@{
    M1 = @{ Target = 'wrapper'; Groups = @('I'); Edits = @(
            , @('foreach ($ompForm in @($Path, $ompNative, $ompFull, $ompStripped, $ompCanonical)) {', 'foreach ($ompForm in @($Path, $ompNative, $ompFull)) {')
            , @('    if ($ompProtectedOk -ne $true) { $ompReady = $false }', '    # M1: state-layer fail-closed removed')
            , @('    if ($null -eq $Context -or $Context.ProtectedOk -ne $true) { return }', '    if ($null -eq $Context) { return }'))
        ExpectFail = @('I-unit-qC', 'I-unit-qc-lower', 'I-unit-dC', 'I-unit-dC-slash', 'I-unit-fwd-q', 'I-unit-fwd-dot', 'I-unit-nt-qq',
            'I-unit-dC-dotdot-C', 'I-unit-dC-trail-dot', 'I-unit-qC-dotdot', 'I-unit-qq-dotdot', 'I-unit-qC-trail-dot',
            'I-e2e-main-qC-burn', 'I-e2e-main-qC-float', 'I-e2e-main-dC-burn', 'I-e2e-main-dC-float',
            'I-e2e-floatcfg-qC-burn', 'I-e2e-floatcfg-qC-float', 'I-e2e-floatcfg-dC-burn', 'I-e2e-floatcfg-dC-float',
            'I-e2e-exe-qC-burn', 'I-e2e-exe-qC-float', 'I-e2e-exe-dC-burn', 'I-e2e-exe-dC-float',
            'I-e2e-f2-qC-burn', 'I-e2e-f2-qC-float', 'I-e2e-f2-dC-burn', 'I-e2e-f2-dC-float',
            'I-failclosed-volume-config', 'I-failclosed-globalroot-config', 'I-failclosed-volume-wrapper', 'I-failclosed-globalroot-wrapper')
    }
    M2 = @{ Target = 'wrapper'; Groups = @('I'); Edits = @(
            , @('    if ($ompProtectedOk -ne $true) { $ompReady = $false }', '    # M2: state-layer fail-closed removed')
            , @('    if ($null -eq $Context -or $Context.ProtectedOk -ne $true) { return }', '    if ($null -eq $Context) { return }'))
        ExpectFail = @('I-failclosed-volume-config', 'I-failclosed-globalroot-config', 'I-failclosed-volume-wrapper', 'I-failclosed-globalroot-wrapper')
    }
    M3 = @{ Target = 'wrapper'; Groups = @('I'); Edits = @(
            , @('foreach ($ompProtected in @($StatuslinePath, $WrapperPath, $GeneratorPath,', 'foreach ($ompProtected in @($WrapperPath, $GeneratorPath,'))
        ExpectFail = @('I-e2e-f2-qC-burn', 'I-e2e-f2-dC-burn')
    }
    M4 = @{ Target = 'wrapper'; Groups = @('B'); Edits = @(
            , @('$payload.model = [ordered]@{ display_name = $model }', '$payload.model = [ordered]@{ display_name = ($model + ''M4'') }'))
        ExpectFail = @('B-default-full', 'B-style-pill', 'B-style-lean', 'B-style-classic', 'B-theme-nord-pill', 'B-theme-nord-lean', 'B-nodir',
            'B-git-clean', 'B-git-dirty', 'B-types-float', 'B-types-null', 'B-types-iso', 'B-types-string', 'B-cache-warm', 'B-cache-cold')
    }
    M5 = @{ Target = 'wrapper'; Groups = @('D', 'I'); Edits = @(
            , @('    $target = Get-FloatTarget', '    $target = ConvertTo-LocalFullPath ([string]$Cfg.VL_FLOAT_FILE) ([Environment]::CurrentDirectory)')
            , @('    $protected = @($StatuslinePath, $WrapperPath, $GeneratorPath, $MainConfig, $FloatConfigPath, $AutoConfigPath, $ExePath)', '    $protected = @()'))
        ExpectFail = @('D-collide-statusline-abs', 'D-collide-statusline-rel', 'D-collide-statusline-slash', 'D-collide-main-abs', 'D-collide-main-rel', 'D-collide-main-slash',
            'D-collide-float-abs', 'D-collide-float-rel', 'D-collide-float-slash', 'D-collide-auto-abs', 'D-collide-auto-rel', 'D-collide-auto-slash',
            'I-e2e-main-qC-float', 'I-e2e-main-dC-float', 'I-e2e-floatcfg-qC-float', 'I-e2e-floatcfg-dC-float',
            'I-e2e-exe-qC-float', 'I-e2e-exe-dC-float', 'I-e2e-f2-qC-float', 'I-e2e-f2-dC-float')
    }
    M6 = @{ Target = 'wrapper'; Groups = @('E', 'I'); Edits = @(
            , @('foreach ($ompProtectedForm in $ompProtectedForms) { $ConfigVisitedPaths += [string]$ompProtectedForm }', 'foreach ($ompProtectedForm in $ompProtectedForms) { }'))
        ExpectFail = @('E-collide-auto', 'I-e2e-main-qC-burn', 'I-e2e-main-dC-burn', 'I-e2e-floatcfg-qC-burn', 'I-e2e-floatcfg-dC-burn',
            'I-e2e-exe-qC-burn', 'I-e2e-exe-dC-burn', 'I-e2e-f2-qC-burn', 'I-e2e-f2-dC-burn')
    }
    M7 = @{ Target = 'wrapper'; Groups = @('F'); Edits = @(
            , @("    try { & `$StatuslinePath '--subagent' } catch { }", '    try { } catch { }'))
        ExpectFail = @('F-subagent-bytes-equal')
    }
    M8 = @{ Target = 'wrapper'; Groups = @('G'); Edits = @(
            , @("-eq 'auto'`", [System.StringComparison]::Ordinal)", "-eq 'autoM8'`", [System.StringComparison]::Ordinal)"))
        ExpectFail = @('G-auto-pill-c80', 'G-auto-pill-c40', 'G-auto-lean-c80', 'G-auto-lean-c40')
    }
    M9 = @{ Target = 'native'; Groups = @('H'); Edits = @(
            , @("`n`$Cfg.BURN_SLACK = [string](Get-BoundedInt `$Cfg.BURN_SLACK 500 0 1000 4)`n", "`n`$Cfg.BURN_SLACK = [string](Get-BoundedInt `$Cfg.BURN_SLACK 500 0 1000 4)`n`$Cfg.VL_M9_NEW = [string](Get-BoundedInt `$Cfg.VL_M9_NEW 1 0 9 1)`n"))
        ExpectFail = @('H-z2-statusline-minus-generator', 'H-w1-38-statements', 'H-enum-display-located')
    }
}

# ============================================================================================
# Setup
# ============================================================================================
$script:ActiveGroups = @()
foreach ($item in $Group) { foreach ($piece in ([string]$item).Split(',')) { if ($piece.Trim() -ne '') { $script:ActiveGroups += $piece.Trim().ToUpperInvariant() } } }
$MutationSpec = $null
if ($Mutation -ne '') {
    if (-not $MutationSpecs.Contains($Mutation)) { throw ('unknown -Mutation ' + $Mutation + '; expected one of ' + (@($MutationSpecs.Keys) -join ', ')) }
    $MutationSpec = $MutationSpecs[$Mutation]
    if ($script:ActiveGroups.Count -eq 0) { $script:ActiveGroups = @($MutationSpec.Groups) }
}
[Console]::Out.WriteLine('host=' + $HostTag + ' (' + $PSVersionTable.PSVersion + ') repo=' + $Repo + ' temp=' + $TempRoot + ' mutation=' + $(if ($Mutation -ne '') { $Mutation } else { 'none' }) + ' groups=' + $(if ($script:ActiveGroups.Count -gt 0) { $script:ActiveGroups -join ',' } else { 'all' }))

# Oh-My-Posh on .NET Framework: a child's stdin writer must not start with a BOM.
try {
    $inputEncoding = [Console]::InputEncoding
    if ($inputEncoding.CodePage -eq 65001 -and $inputEncoding.GetPreamble().Length -gt 0) { [Console]::InputEncoding = $Utf8 }
} catch { }

# ---- J1: Oh-My-Posh source ------------------------------------------------------------------
$PathOmp = ''
$pathHit = Get-Command -Name 'oh-my-posh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $pathHit) { $PathOmp = [string]$pathHit.Source }
$OmpCandidate = ''
$OmpBlockReason = ''
switch ($true) {
    { $OmpSource -ne '' } {
        $info = $null
        try { $info = New-Object System.IO.FileInfo($OmpSource) } catch { $info = $null }
        if ($null -eq $info -or -not $info.Exists) { $OmpBlockReason = '-OmpSource is not an existing file: ' + $OmpSource; break }
        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $OmpBlockReason = '-OmpSource is a reparse point: ' + $OmpSource; break }
        $OmpCandidate = $info.FullName
        break
    }
    { $PathOmp -eq '' } { $OmpBlockReason = 'no oh-my-posh on PATH; pass -OmpSource'; break }
    default {
        $attrs = [System.IO.File]::GetAttributes($PathOmp)
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $OmpBlockReason = 'OMP on PATH is an App Execution Alias; pass -OmpSource'; break }
        $OmpCandidate = $PathOmp
    }
}
$OmpVersion = ''
if ($OmpCandidate -ne '') {
    try { $OmpVersion = ([string](& $OmpCandidate version 2>$null | Select-Object -First 1)).Trim() } catch { $OmpVersion = '' }
    $parsedVersion = $null
    if (-not [version]::TryParse($OmpVersion, [ref]$parsedVersion)) { $OmpBlockReason = 'cannot read the version of ' + $OmpCandidate + ' (got [' + $OmpVersion + '])'; $OmpCandidate = '' }
    elseif ($parsedVersion -lt [version]'31.3.0') { $OmpBlockReason = 'Oh-My-Posh ' + $OmpVersion + ' is older than 31.3.0: ' + $OmpCandidate; $OmpCandidate = '' }
}
$OmpReady = ($OmpCandidate -ne '')
[Console]::Out.WriteLine('omp source=' + $(if ($OmpReady) { $OmpCandidate + ' version=' + $OmpVersion } else { '<none>: ' + $OmpBlockReason }) + ' path-hit=' + $PathOmp + ' [' + (Get-AliasWitness $PathOmp) + ']')

# ---- integrity witness, before ------------------------------------------------------------
$WitnessFiles = @((Join-Path $Repo 'statusline.ps1'), (Join-Path $Repo 'statusline-omp.ps1'), (Join-Path $Repo 'tools\build-omp-config.ps1'))
$WitnessBefore = @{}
foreach ($file in $WitnessFiles) { $WitnessBefore[$file] = Get-Sha256 $file }
$OmpWitnessBefore = ''
if ($OmpReady) { $OmpWitnessBefore = Get-Sha256 $OmpCandidate }
$AliasWitnessBefore = Get-AliasWitness $PathOmp

# ---- sources and mutation --------------------------------------------------------------------
$NowLine = '$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()'
$NowLineSubagent = '$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()'
$NativeSource = [System.IO.File]::ReadAllText((Join-Path $Repo 'statusline.ps1'), $Utf8)
$WrapperSource = [System.IO.File]::ReadAllText((Join-Path $Repo 'statusline-omp.ps1'), $Utf8)
$GeneratorSource = [System.IO.File]::ReadAllText((Join-Path $Repo 'tools\build-omp-config.ps1'), $Utf8)
foreach ($pair in @(@('statusline.ps1', $NativeSource, $NowLine), @('statusline.ps1', $NativeSource, $NowLineSubagent), @('statusline-omp.ps1', $WrapperSource, $NowLine))) {
    if (([regex]::Matches([string]$pair[1], [regex]::Escape([string]$pair[2]))).Count -ne 1) { throw ($pair[0] + ' does not hold exactly one line ' + $pair[2] + ' to pin') }
}
if ($null -ne $MutationSpec) {
    $mutationOk = $true
    $mutationError = ''
    try {
        switch ($MutationSpec.Target) {
            'native' { $NativeSource = Get-MutatedText $NativeSource $MutationSpec.Edits }
            default { $WrapperSource = Get-MutatedText $WrapperSource $MutationSpec.Edits }
        }
    } catch { $mutationOk = $false; $mutationError = $_.Exception.Message }
    Check 'X-mutation-applied' $mutationOk $mutationError
    if (-not $mutationOk) { [Console]::Out.WriteLine('SUMMARY pass=' + $script:Pass + ' fail=' + $script:Fail + ' blocked=' + $script:Blocked); exit 1 }
}

# ---- git ----------------------------------------------------------------------------------------
$GitExe = ''
$gitHit = Get-Command -Name 'git.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -ne $gitHit) { $GitExe = [string]$gitHit.Source }
$GitDir = ''
if ($GitExe -ne '') { $GitDir = Split-Path -Path $GitExe -Parent }
$GitReady = ($GitExe -ne '')

# ---- temporary root ---------------------------------------------------------------------------------
[void][System.IO.Directory]::CreateDirectory($TempRoot)
$ChildHome = Join-Path $TempRoot 'home'
$ChildTemp = Join-Path $TempRoot 'tmp'
foreach ($dir in @($ChildHome, $ChildTemp, (Join-Path $ChildHome '.claude'), (Join-Path $ChildHome 'AppData\Local'), (Join-Path $ChildHome 'AppData\Roaming'))) { [void][System.IO.Directory]::CreateDirectory($dir) }
$Inst = Join-Path $TempRoot 'inst'
$InstThemes = Join-Path $Inst 'themes'
$Pin = Join-Path $TempRoot 'pin'
foreach ($dir in @($Inst, (Join-Path $Inst 'tools'), $InstThemes, $Pin, (Join-Path $Pin 'tools'))) { [void][System.IO.Directory]::CreateDirectory($dir) }
Write-Utf8 (Join-Path $Inst 'statusline.ps1') $NativeSource
Write-Utf8 (Join-Path $Inst 'statusline-omp.ps1') $WrapperSource
Write-Utf8 (Join-Path $Inst 'tools\build-omp-config.ps1') $GeneratorSource
Write-Utf8 (Join-Path $Pin 'tools\build-omp-config.ps1') $GeneratorSource
foreach ($theme in Get-ChildItem -LiteralPath (Join-Path $Repo 'themes') -Filter '*.conf') { [System.IO.File]::Copy($theme.FullName, (Join-Path $InstThemes $theme.Name), $true) }
$InstOmp = Join-Path $Inst 'oh-my-posh.exe'
if ($OmpReady) { [System.IO.File]::Copy($OmpCandidate, $InstOmp, $true) }
$InstWrapper = Join-Path $Inst 'statusline-omp.ps1'
$InstNative = Join-Path $Inst 'statusline.ps1'
Set-Pinned (Get-UnixNow)
$script:Layouts = [ordered]@{}

function Test-NeedOmp {
    <#
    .SYNOPSIS
      True when Oh-My-Posh is available; otherwise records the check as BLOCKED.
    .PARAMETER Name
      Check ID.
    .EXAMPLE
      if (Test-NeedOmp 'B-default-full') { ... }
    #>
    param([string]$Name)
    if ($OmpReady) { return $true }
    Blocked $Name $OmpBlockReason
    return $false
}

function Restore-File {
    <#
    .SYNOPSIS
      Put a file back to the given bytes when a render changed it; returns $true when it had changed.
    .PARAMETER Path
      File.
    .PARAMETER Bytes
      Expected content.
    .EXAMPLE
      Restore-File -Path $target -Bytes $before
    #>
    param([string]$Path, [byte[]]$Bytes)
    $now = Read-Maybe $Path
    if (Test-SameBytes $now $Bytes) { return $false }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
    return $true
}

# Git fixtures.
$GitRoot = Join-Path $TempRoot 'git'
$RepoClean = ''
$RepoDirty = ''
function Invoke-Git {
    <#
    .SYNOPSIS
      Run git in a folder and fail loudly.
    .PARAMETER Dir
      Repository folder.
    .PARAMETER Arguments
      git arguments.
    .EXAMPLE
      Invoke-Git -Dir $d -Arguments @('init', '-q')
    #>
    param([string]$Dir, [string[]]$Arguments)
    $all = @('-C', $Dir, '-c', 'user.name=omp-test', '-c', 'user.email=omp-test@example.invalid', '-c', 'core.autocrlf=false', '-c', 'commit.gpgsign=false') + $Arguments
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $GitExe @all 2>&1 } finally { $ErrorActionPreference = $saved }
    if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Arguments -join ' ') + ' failed: ' + ($output -join ' ')) }
}
if ($GitReady) {
    foreach ($name in @('clean', 'dirty')) {
        $dir = Join-Path $GitRoot $name
        [void][System.IO.Directory]::CreateDirectory($dir)
        Invoke-Git $dir @('init', '-q')
        Invoke-Git $dir @('checkout', '-q', '-b', 'main')
        Write-Utf8 (Join-Path $dir 'f.txt') "one`n"
        Invoke-Git $dir @('add', 'f.txt')
        Invoke-Git $dir @('commit', '-q', '-m', 'init')
        if ($name -eq 'dirty') { Write-Utf8 (Join-Path $dir 'f.txt') "two`n" }
    }
    $RepoClean = Join-Path $GitRoot 'clean'
    $RepoDirty = Join-Path $GitRoot 'dirty'
}
$PlainDir = Join-Path $TempRoot 'work\project'
[void][System.IO.Directory]::CreateDirectory($PlainDir)

# Volume GUID and device name of the temporary root's drive (for the R1 alias cases).
$TempDrive = $TempRoot.Substring(0, 2)
$VolumeName = ''
$DeviceName = ''
try {
    $mountvol = (& mountvol.exe ($TempDrive + '\') /L 2>$null | Out-String)
    $VolumeName = ([regex]::Match($mountvol, 'Volume\{[0-9a-fA-F-]+\}')).Value
} catch { $VolumeName = '' }
try {
    if ($null -eq ('OmpTestDos' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OmpTestDos {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint QueryDosDevice(string name, StringBuilder target, int max);
    public static string Query(string name) { StringBuilder sb = new StringBuilder(1024); return QueryDosDevice(name, sb, 1024) == 0 ? "" : sb.ToString(); }
}
'@
    }
    $DeviceName = [string]([type]'OmpTestDos')::Query($TempDrive)
} catch { $DeviceName = '' }

try {
    # ============================================================================================
    # X: isolation canary
    # ============================================================================================
    $canaryScript = Join-Path $TempRoot 'canary.ps1'
    Write-Utf8 $canaryScript ('$d = [string]$env:CLAUDE_CONFIG_DIR' + "`n" + 'if ([string]::IsNullOrEmpty($d)) { $d = [System.IO.Path]::Combine([string]$HOME, ''.claude'') }' + "`n" +
        '[Console]::Out.Write([string]$HOME + "|" + [Environment]::GetFolderPath(''UserProfile'') + "|" + [System.IO.Path]::Combine($d, ''coralline'', ''coralline.omp.json'') + "|" + [string]$env:CORALLINE_CONFIG + "|" + [string]$env:POSH_THEME)' + "`n")
    $canary = Invoke-Child -Script $canaryScript
    $canaryParts = ([string]$canary.Text).Split('|')
    $canaryOk = $canary.Exit -eq 0 -and $canaryParts.Count -eq 5
    if ($canaryOk) {
        foreach ($value in @($canaryParts[0], $canaryParts[2])) { if (-not $value.StartsWith($TempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $canaryOk = $false } }
        if ($canaryParts[3] -ne '' -or $canaryParts[4] -ne '') { $canaryOk = $false }
    }
    Check 'X-canary-home-and-default-config-in-temp' $canaryOk ('child saw ' + $canary.Text + ' ' + $canary.Err)
    if (Test-NeedOmp 'X-canary-default-config-renders-from-temp') {
        # The wrapper without -Config and CORALLINE_OMP_CONFIG must find the config under the temporary CLAUDE_CONFIG_DIR.
        $defaultDir = Join-Path $ChildHome '.claude\coralline'
        $defaultConf = New-Conf $defaultDir 'canary' @("VL_SEGMENTS='model'")
        $gen = Invoke-Generator -Conf $defaultConf -Dir $defaultDir
        $run = Invoke-Wrapper -Script $InstWrapper -Conf $defaultConf -OmpExe $InstOmp -Payload (Get-RatePayload -Model ('Canary ' + $Marker))
        Check 'X-canary-default-config-renders-from-temp' ($gen.Exit -eq 0 -and $run.Exit -eq 0 -and (Get-Plain $run.Text).Contains($Marker)) ('gen=' + $gen.Exit + ' exit=' + $run.Exit + ' out=' + (Show-Text $run.Text))
    }

    # ============================================================================================
    # H: upstream sync tripwires (static, on the copies under test; no Oh-My-Posh)
    # ============================================================================================
    if (Test-GroupOn 'H') {
        $hNativeAst = [System.Management.Automation.Language.Parser]::ParseFile($InstNative, [ref]$null, [ref]$null)
        $hGeneratorAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Inst 'tools\build-omp-config.ps1'), [ref]$null, [ref]$null)
        $script:HWrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($InstWrapper, [ref]$null, [ref]$null)
        $borrowed = @('Test-NoExitCode', 'Select-StatuslineStatements', 'Get-StatuslineConfigCode', 'Get-AstVariableName', 'Get-StatuslineWriteCount',
            'Get-StatuslineBinding', 'Get-StatuslineHomeBinding', 'Select-StatuslineDisplayStage')
        foreach ($definition in $script:HWrapperAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $borrowed -contains $n.Name }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $hMissing = @($borrowed | Where-Object { -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
        $hStageSpecs = $null
        $hSpecError = ''
        if ($hMissing.Count -eq 0) { try { $hStageSpecs = Get-StageSpecs $hNativeAst } catch { $hSpecError = $_.Exception.Message } } else { $hSpecError = 'wrapper helpers missing: ' + ($hMissing -join ',') }
        foreach ($stage in @('config', 'state', 'display')) {
            if ($null -eq $hStageSpecs) {
                foreach ($suffix in @('located', 'calls', 'free-vars')) { Check ('H-enum-' + $stage + '-' + $suffix) $false $hSpecError }
                continue
            }
            $report = $null
            try { $report = Get-StageReport $hNativeAst $hStageSpecs[$stage] } catch { $report = @{ Problems = @('report failed: ' + $_.Exception.Message); Calls = @('report failed'); Unbound = @('report failed') } }
            Check ('H-enum-' + $stage + '-located') (@($report.Problems).Count -eq 0) (@($report.Problems) -join '; ')
            Check ('H-enum-' + $stage + '-calls') (@($report.Calls).Count -eq 0) (@($report.Calls) -join '; ')
            Check ('H-enum-' + $stage + '-free-vars') (@($report.Unbound).Count -eq 0) (@($report.Unbound) -join '; ')
        }
        $w1Count = -1
        if ($hMissing.Count -eq 0) {
            $w1Code = Select-StatuslineDisplayStage $hNativeAst
            if (-not [string]::IsNullOrEmpty([string]$w1Code)) { $w1Count = @([System.Management.Automation.Language.Parser]::ParseInput([string]$w1Code, [ref]$null, [ref]$null).EndBlock.Statements).Count }
        }
        Check 'H-w1-38-statements' ($w1Count -eq 38) ('Select-StatuslineDisplayStage gave ' + $w1Count + ' statements')
        $hStatic = $null
        try { $hStatic = Get-HStaticReport $hNativeAst $hGeneratorAst $script:HWrapperAst } catch { $hStatic = $null; $hSpecError = $_.Exception.Message }
        foreach ($id in @('H-z2-generator-verbatim', 'H-z2-statusline-minus-generator', 'H-z3-statusline-strip-once', 'H-z3-generator-strip-once', 'H-z3-hot-warn-verbatim',
                'H-z4-definition', 'H-z4-generator-calls', 'H-z4-wrapper-calls', 'H-e3-config-code-integer-block')) {
            if ($null -eq $hStatic) { Check $id $false $hSpecError; continue }
            Check $id ([string]::IsNullOrEmpty([string]$hStatic[$id])) ([string]$hStatic[$id])
        }
    }

    # ============================================================================================
    # I (unit): Get-OmpProtectedForms, expected values derived from the S6b path probe
    # ============================================================================================
    if (Test-GroupOn 'I') {
        $iNativeAst = [System.Management.Automation.Language.Parser]::ParseFile($InstNative, [ref]$null, [ref]$null)
        foreach ($definition in $iNativeAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath') -contains $n.Name }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $iWrapperAst = [System.Management.Automation.Language.Parser]::ParseFile($InstWrapper, [ref]$null, [ref]$null)
        foreach ($definition in $iWrapperAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OmpProtectedForms' }, $false)) { . ([scriptblock]::Create($definition.Extent.Text)) }
        $iReady = $null -ne (Get-Command -Name 'Get-OmpProtectedForms' -CommandType Function -ErrorAction SilentlyContinue) -and $null -ne (Get-Command -Name 'ConvertTo-LocalFullPath' -CommandType Function -ErrorAction SilentlyContinue)
        # P is a drive-letter path under the temporary root; the file need not exist.
        $uP = Join-Path $TempRoot 'unit\x\f.txt'
        $uD = $uP.Substring(0, 2)
        $uR = $uP.Substring(3)
        $uRf = $uR.Replace('\', '/')
        $uDotDot = (Join-Path $TempRoot 'unit\x\..\x\f.txt')
        $uVol = 'Volume{01234567-89ab-cdef-0123-456789abcdef}'
        $uDev = '\Device\HarddiskVolume99'
        $uCwdDrive = [System.IO.Path]::GetPathRoot([Environment]::CurrentDirectory).Substring(0, 2)
        # Expected Forms and Ok per row (probe: GetFullPath normalises \\.\ forms and //?/, keeps \\?\ and \??\ as given,
        # trims a trailing dot or space, maps /c/x to <cwd drive>\c\x, and throws on ::$DATA only on 5.1).
        $uRows = @(
            , @('plain', $uP, @($uP), $true)
            , @('qC', ('\\?\' + $uP), @(('\\?\' + $uP), $uP), $true)
            , @('qc-lower', ('\\?\' + $uD.ToLowerInvariant() + '\' + $uR), @(('\\?\' + $uP), $uP), $true)
            , @('dC', ('\\.\' + $uP), @(('\\.\' + $uP), $uP), $true)
            , @('dC-slash', ('\\.\' + $uD + '/' + $uRf), @(('\\.\' + $uD + '/' + $uRf), ('\\.\' + $uP), $uP), $true)
            , @('fwd-q', ('//?/' + $uD + '/' + $uRf), @(('//?/' + $uD + '/' + $uRf), ('\\?\' + $uP), $uP), $true)
            , @('fwd-dot', ('//./' + $uD + '/' + $uRf), @(('//./' + $uD + '/' + $uRf), ('\\.\' + $uP), $uP), $true)
            , @('nt-qq', ('\??\' + $uP), @(('\??\' + $uP), $uP), $true)
            , @('dC-dotdot-volume', ('\\.\' + $uD + '\..\' + $uVol + '\' + $uR), @(('\\.\' + $uD + '\..\' + $uVol + '\' + $uR), ('\\.\' + $uVol + '\' + $uR)), $false)
            , @('dC-dotdot-C', ('\\.\' + $uD + '\..\' + $uD + '\' + $uR), @(('\\.\' + $uD + '\..\' + $uD + '\' + $uR), ('\\.\' + $uP), $uP), $true)
            , @('dC-trail-dot', ('\\.\' + $uP + '.'), @(('\\.\' + $uP + '.'), ('\\.\' + $uP), $uP), $true)
            , @('qC-dotdot', ('\\?\' + $uDotDot), @(('\\?\' + $uDotDot), $uDotDot, $uP), $false)
            , @('qq-dotdot', ('\??\' + $uDotDot), @(('\??\' + $uDotDot), $uDotDot, $uP), $false)
            , @('qC-trail-dot', ('\\?\' + $uP + '.'), @(('\\?\' + $uP + '.'), ($uP + '.')), $false)
            , @('qC-mixed', ('\\?\' + $uD + '/' + $uRf), @(('\\?\' + $uD + '/' + $uRf)), $false)
            , @('qUNC', ('\\?\UNC\localhost\' + $uD.Substring(0, 1) + '$\' + $uR), @(('\\?\UNC\localhost\' + $uD.Substring(0, 1) + '$\' + $uR)), $false)
            , @('qVolume', ('\\?\' + $uVol + '\' + $uR), @(('\\?\' + $uVol + '\' + $uR)), $false)
            , @('qGlobalroot', ('\\?\GLOBALROOT' + $uDev + '\' + $uR), @(('\\?\GLOBALROOT' + $uDev + '\' + $uR)), $false)
            , @('unc', ('\\localhost\' + $uD.Substring(0, 1) + '$\' + $uR), @(('\\localhost\' + $uD.Substring(0, 1) + '$\' + $uR)), $false)
            , @('trail-dot', ($uP + '.'), @(($uP + '.'), $uP), $true)
            , @('trail-space', ($uP + ' '), @(($uP + ' '), $uP), $true)
            , @('msys', ('/' + $uD.Substring(0, 1).ToLowerInvariant() + '/' + $uRf), @(('/' + $uD.Substring(0, 1).ToLowerInvariant() + '/' + $uRf), $uP, ($uCwdDrive + '\' + $uD.Substring(0, 1).ToLowerInvariant() + '\' + $uR)), $true)
            , @('ads', ($uP + '::$DATA'), @(($uP + '::$DATA')), $false)
        )
        $supersetProblems = New-Object 'System.Collections.Generic.List[string]'
        foreach ($row in $uRows) {
            $id = 'I-unit-' + $row[0]
            if (-not $iReady) { Check $id $false 'Get-OmpProtectedForms or ConvertTo-LocalFullPath not found in the copies under test'; continue }
            $okOut = $null
            $forms = @()
            $err = ''
            try { $forms = @(Get-OmpProtectedForms ([string]$row[1]) ([ref]$okOut)) } catch { $err = $_.Exception.Message }
            $expected = @($row[2])
            $problem = ''
            if ($err -ne '') { $problem = 'threw ' + $err }
            elseif ($forms.Count -ne $expected.Count) { $problem = 'forms count ' + $forms.Count + ' expected ' + $expected.Count }
            else {
                foreach ($want in $expected) {
                    $found = $false
                    foreach ($have in $forms) { if ([string]::Equals([string]$have, [string]$want, [StringComparison]::OrdinalIgnoreCase)) { $found = $true } }
                    if (-not $found) { $problem = 'missing form ' + $want }
                }
            }
            if ($problem -eq '' -and ($okOut -isnot [bool] -or $okOut -ne [bool]$row[3])) { $problem = 'Ok=' + [string]$okOut + ' expected ' + [string]$row[3] }
            Check $id ($problem -eq '') ($problem + ' | got [' + (@($forms) -join ' ; ') + '] Ok=' + [string]$okOut)
            # Old sets: state {as given, ConvertTo-LocalFullPath}, float {as given, GetFullPath}.
            $old = @([string]$row[1], [string](ConvertTo-LocalFullPath ([string]$row[1]) ([Environment]::CurrentDirectory)))
            try { $old += [string][System.IO.Path]::GetFullPath([string]$row[1]) } catch { }
            foreach ($form in $old) {
                if ([string]::IsNullOrEmpty($form)) { continue }
                $found = $false
                foreach ($have in $forms) { if ([string]::Equals([string]$have, $form, [StringComparison]::OrdinalIgnoreCase)) { $found = $true } }
                if (-not $found) { [void]$supersetProblems.Add($row[0] + ': ' + $form) }
            }
        }
        if ($iReady) { Check 'I-unit-superset-of-old-sets' ($supersetProblems.Count -eq 0) ($supersetProblems -join '; ') }
    }

    # ============================================================================================
    # Shared layouts
    # ============================================================================================
    $BSeg1 = "VL_SEGMENTS='dir git model effort ctx limit5h limit7d cost'"
    $BSeg2 = "VL_SEGMENTS2='lines style duration'"
    $Styles = @('pill', 'lean', 'classic')
    $ThemesUsed = @('claude-coral', 'nord')
    function Get-StyleLayout {
        <#
        .SYNOPSIS
          The style x theme layout shared by A and B.
        .PARAMETER Style
          pill, lean or classic.
        .PARAMETER Theme
          Theme name.
        .EXAMPLE
          Get-StyleLayout -Style pill -Theme claude-coral
        #>
        param([string]$Style, [string]$Theme)
        return Get-Layout -Name ('s-' + $Style + '-' + $Theme) -Lines @(("VL_STYLE='" + $Style + "'"), $BSeg1, $BSeg2) -Theme $Theme
    }

    # ============================================================================================
    # A: generator
    # ============================================================================================
    if (Test-GroupOn 'A') {
        foreach ($style in $Styles) {
            foreach ($theme in $ThemesUsed) {
                $layout = Get-StyleLayout $style $theme
                $tag = 'A-gen-' + $style + '-' + $theme
                Check ($tag + '-runs') ($layout.Exit -eq 0 -and [System.IO.File]::Exists($layout.Omp) -and [System.IO.File]::Exists($layout.Float)) ('exit ' + $layout.Exit + ' ' + $layout.Err)
                $bytes = Read-Maybe $layout.Omp
                $shape = ''
                if ($null -eq $bytes) { $shape = 'no output' }
                else {
                    foreach ($b in $bytes) { if ($b -gt 0x7E -or ($b -lt 0x20 -and $b -ne 0x0A)) { $shape = 'byte 0x' + $b.ToString('X2') + ' is not printable ASCII or LF'; break } }
                    $text = $Utf8.GetString($bytes)
                    if ($shape -eq '' -and -not $text.Contains('coralline-omp/')) { $shape = 'no coralline-omp/ marker' }
                    if ($shape -eq '' -and $text -match '"upgrade"') { $shape = 'holds an upgrade key' }
                    if ($shape -eq '' -and -not $text.EndsWith("`n")) { $shape = 'does not end with LF' }
                }
                Check ($tag + '-shape') ($shape -eq '') $shape
            }
        }
        $first = Get-StyleLayout 'pill' 'claude-coral'
        $again = Invoke-Generator -Conf $first.Conf -Dir (Join-Path $TempRoot 'layouts\s-pill-again')
        Check 'A-gen-deterministic' ($again.Exit -eq 0 -and (Test-SameBytes (Read-Maybe $first.Omp) (Read-Maybe $again.Omp)) -and (Test-SameBytes (Read-Maybe $first.Float) (Read-Maybe $again.Float))) ('second run differs or failed: exit ' + $again.Exit)
        foreach ($case in @(@('nocolor', @('VL_LAYOUT=auto', 'VL_NOCOLOR=1'), 'VL_NOCOLOR=1'), @('maxlines', @('VL_LAYOUT=auto', 'VL_MAX_LINES=1'), 'VL_MAX_LINES<=1'),
                @('emptybg', @('VL_LAYOUT=auto', "VL_SEGMENTS='model'", "VL_BG_MODEL=''"), 'a required background is empty'))) {
            $layout = Get-Layout -Name ('a-ph-' + $case[0]) -Lines $case[1] -Theme 'claude-coral' -Placeholder
            $reason = '<none>'
            $hasTokens = $true
            try {
                $parsed = $Utf8.GetString([System.IO.File]::ReadAllBytes($layout.Auto)) | ConvertFrom-Json
                $reason = [string]$parsed.var.CorallineAutoDisabled
                $hasTokens = $null -ne $parsed.var.CorallineAutoTokens -or $null -ne $parsed.blocks
            } catch { $reason = 'unreadable: ' + $_.Exception.Message }
            Check ('A-placeholder-' + $case[0]) ($layout.Exit -eq 0 -and $reason -ceq $case[2] -and -not $hasTokens) ('reason [' + $reason + '] expected [' + $case[2] + '] tokens/blocks=' + $hasTokens)
        }
    }

    # ============================================================================================
    # C: failure semantics (no Oh-My-Posh needed: each exits before or at the Oh-My-Posh lookup)
    # ============================================================================================
    if (Test-GroupOn 'C') {
        $cLayout = Get-StyleLayout 'pill' 'claude-coral'
        $cDir = Join-Path $TempRoot 'c'
        [void][System.IO.Directory]::CreateDirectory($cDir)
        $full = [System.IO.File]::ReadAllBytes($cLayout.Omp)
        $truncated = Join-Path $cDir 'truncated.omp.json'
        [System.IO.File]::WriteAllBytes($truncated, $full[0..([int]($full.Length / 2))])
        $foreign = Join-Path $cDir 'foreign.omp.json'
        Write-Utf8 $foreign "{`"version`":4,`"blocks`":[]}`n"
        $missingOmp = Join-Path $cDir 'nope\oh-my-posh.exe'
        $cOmp = $missingOmp
        if ($OmpReady) { $cOmp = $InstOmp }
        $cPayload = Get-RatePayload -Model ('Opus ' + $Marker)
        $cases = @(
            , @('C-truncated-config', $truncated, $cOmp, @())
            , @('C-foreign-config', $foreign, $cOmp, @())
            , @('C-omp-missing', $cLayout.Omp, $missingOmp, @())
            , @('C-extra-argument', $cLayout.Omp, $cOmp, @('extra'))
        )
        foreach ($case in $cases) {
            $run = Invoke-Wrapper -Script $InstWrapper -Conf $cLayout.Conf -Config $case[1] -OmpExe $case[2] -Payload $cPayload -Arguments $case[3]
            Check $case[0] ($run.Exit -eq 0 -and (Test-SameBytes $run.Bytes ([byte[]](10)))) ('exit ' + $run.Exit + ' out=' + (Show-Text $run.Text) + ' err=' + (Show-Text $run.Err))
        }
    }

    # ============================================================================================
    # F: --subagent (delegated to statusline.ps1; no Oh-My-Posh)
    # ============================================================================================
    if (Test-GroupOn 'F') {
        $fLayout = Get-StyleLayout 'pill' 'claude-coral'
        $fPayload = [System.IO.File]::ReadAllText((Join-Path $Here 'sample-subagent-input.json'), $Utf8)
        Set-Pinned 1784000000
        $native = Invoke-Native -Dir $Pin -Conf $fLayout.Conf -Payload $fPayload -Arguments @('--subagent')
        $wrapped = Invoke-Wrapper -Script (Join-Path $Pin 'statusline-omp.ps1') -Conf $fLayout.Conf -Payload $fPayload -Arguments @('--subagent')
        Check 'F-subagent-bytes-equal' ($native.Exit -eq 0 -and $wrapped.Exit -eq 0 -and $native.Bytes.Length -gt 1 -and (Test-SameBytes $native.Bytes $wrapped.Bytes)) ('native=' + (Show-Text $native.Text) + ' | wrapper=' + (Show-Text $wrapped.Text))
        foreach ($case in @(@('F-subagent-wrong-case-blank', @('--Subagent')), @('F-subagent-extra-token-blank', @('--subagent', 'x')))) {
            $run = Invoke-Wrapper -Script (Join-Path $Pin 'statusline-omp.ps1') -Conf $fLayout.Conf -Payload $fPayload -Arguments $case[1]
            Check $case[0] ($run.Exit -eq 0 -and (Test-SameBytes $run.Bytes ([byte[]](10)))) ('exit ' + $run.Exit + ' out=' + (Show-Text $run.Text))
        }
    }

    # ============================================================================================
    # B: main-line cell parity, wrapper against native
    # ============================================================================================
    function Invoke-MainPair {
        <#
        .SYNOPSIS
          Render one payload natively and through the wrapper from one install folder; returns @{ Diff; Native; Wrapper }.
        .PARAMETER Layout
          Layout (Conf, Omp).
        .PARAMETER Payload
          stdin text.
        .PARAMETER Extra
          More environment for both.
        .PARAMETER Dir
          Install folder holding both copies.
        .PARAMETER AllowBlank
          Do not require a non-blank native render.
        .EXAMPLE
          Invoke-MainPair -Layout $layout -Payload '{}'
        #>
        param($Layout, [string]$Payload, [hashtable]$Extra = @{}, [string]$Dir = $Inst, [switch]$AllowBlank)
        $native = Invoke-Native -Dir $Dir -Conf $Layout.Conf -Payload $Payload -Extra $Extra
        $wrapped = Invoke-Wrapper -Script (Join-Path $Dir 'statusline-omp.ps1') -Conf $Layout.Conf -Config $Layout.Omp -OmpExe $InstOmp -Payload $Payload -Extra $Extra
        $diff = ''
        switch ($true) {
            { $native.Exit -ne 0 -or $wrapped.Exit -ne 0 } { $diff = 'exit native=' + $native.Exit + ' wrapper=' + $wrapped.Exit + ' ' + (Show-Text $wrapped.Err); break }
            { -not $AllowBlank -and [string]::IsNullOrWhiteSpace((Get-Plain $native.Text)) } { $diff = 'native rendered blank'; break }
            default { $diff = Compare-Render $native.Text $wrapped.Text }
        }
        return @{ Diff = $diff; Native = $native; Wrapper = $wrapped }
    }

    if (Test-GroupOn 'B') {
        $bModel = '"model":{"display_name":"Opus ' + $Marker + '"}'
        $bRich = '"output_style":{"name":"Explanatory"},"effort":{"level":"high"},' +
            '"context_window":{"used_percentage":42,"total_input_tokens":1234,"total_output_tokens":56,"current_usage":{"cache_read_input_tokens":98765,"cache_creation_input_tokens":4321}},' +
            '"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":{T+9030}},"seven_day":{"used_percentage":80,"resets_at":{T+300630}}},' +
            '"cost":{"total_cost_usd":1.5,"total_lines_added":12,"total_lines_removed":3,"total_duration_ms":61000}'
        $bFull = '{' + $bModel + ',"workspace":{"current_dir":' + (ConvertTo-JsonLiteral $PlainDir) + '},' + $bRich + '}'
        $bPill = Get-StyleLayout 'pill' 'claude-coral'
        $bDefault = Get-Layout -Name 'b-default' -Lines @() -Theme 'claude-coral'
        $bCases = New-Object 'System.Collections.Generic.List[object]'
        [void]$bCases.Add(@('B-default-full', $bDefault, $bFull, ''))
        foreach ($style in $Styles) { [void]$bCases.Add(@(('B-style-' + $style), (Get-StyleLayout $style 'claude-coral'), $bFull, '')) }
        [void]$bCases.Add(@('B-theme-nord-pill', (Get-StyleLayout 'pill' 'nord'), $bFull, ''))
        [void]$bCases.Add(@('B-theme-nord-lean', (Get-StyleLayout 'lean' 'nord'), $bFull, ''))
        [void]$bCases.Add(@('B-nodir', $bPill, ('{' + $bModel + ',' + $bRich + '}'), ''))
        foreach ($pair in @(@('B-git-clean', $RepoClean), @('B-git-dirty', $RepoDirty))) {
            $payload = ''
            if ($GitReady) { $payload = '{' + $bModel + ',"workspace":{"current_dir":' + (ConvertTo-JsonLiteral $pair[1]) + '},' + $bRich + '}' }
            [void]$bCases.Add(@($pair[0], $bPill, $payload, 'git'))
        }
        [void]$bCases.Add(@('B-types-float', $bPill, ('{' + $bModel + ',"context_window":{"used_percentage":42.7},"rate_limits":{"five_hour":{"used_percentage":37.25,"resets_at":{T+9030}}},"cost":{"total_cost_usd":1.5,"total_duration_ms":61000.9}}'), ''))
        [void]$bCases.Add(@('B-types-null', $bPill, ('{' + $bModel + ',"context_window":{"used_percentage":null},"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":null}},"cost":{"total_cost_usd":null}}'), ''))
        [void]$bCases.Add(@('B-types-iso', $bPill, ('{' + $bModel + ',"rate_limits":{"five_hour":{"used_percentage":37,"resets_at":"{ISO+9030}"},"seven_day":{"used_percentage":80,"resets_at":"{ISO+300630}"}}}'), ''))
        [void]$bCases.Add(@('B-types-string', $bPill, ('{' + $bModel + ',"context_window":{"used_percentage":"42"},"rate_limits":{"five_hour":{"used_percentage":"37","resets_at":"{T+9030}"}},"cost":{"total_cost_usd":"1.5"}}'), ''))
        [void]$bCases.Add(@('B-stdin-badjson', $bPill, '{"model":', 'blankok'))
        [void]$bCases.Add(@('B-stdin-empty', $bPill, '', 'blankok'))
        [void]$bCases.Add(@('B-stdin-array', $bPill, '[1,2]', 'blankok'))
        foreach ($case in $bCases) {
            $id = [string]$case[0]
            if ($case[3] -eq 'git' -and -not $GitReady) { Blocked $id 'ALLOWED git-missing: git.exe is not on PATH'; continue }
            if (-not (Test-NeedOmp $id)) { continue }
            if ($case[1].Exit -ne 0) { Check $id $false ('generator failed: ' + $case[1].Err); continue }
            $payload = Resolve-TimeTokens ([string]$case[2]) (Get-UnixNow)
            $pair = Invoke-MainPair -Layout $case[1] -Payload $payload -Extra @{ CORALLINE_NO_SAMPLE = '1' } -AllowBlank:($case[3] -eq 'blankok')
            Check $id ($pair.Diff -eq '') $pair.Diff
        }
        $bCache = Get-Layout -Name 'b-cache' -Lines @("VL_SEGMENTS='model cache ctx'")
        foreach ($case in @(@('B-cache-warm', 125), @('B-cache-cold', -10))) {
            if (-not (Test-NeedOmp $case[0])) { continue }
            $second = Get-UnixNow
            Set-Pinned $second
            $payload = '{' + $bModel + ',"context_window":{"used_percentage":42},"prompt_cache":{"hit_ratio":0.9,"expires_at":' + ($second + [long]$case[1]).ToString($Invariant) + '}}'
            $pair = Invoke-MainPair -Layout $bCache -Payload $payload -Extra @{ CORALLINE_NO_SAMPLE = '1' } -Dir $Pin
            Check $case[0] ($pair.Diff -eq '') $pair.Diff
        }
    }

    # ============================================================================================
    # D: float (replaces spike S5 F2 and the /relative gap)
    # ============================================================================================
    if (Test-GroupOn 'D') {
        $dDir = Join-Path $TempRoot 'd\cfg'
        $dOut = Join-Path $TempRoot 'd\out'
        [void][System.IO.Directory]::CreateDirectory($dOut)
        $dLines = @("VL_SEGMENTS='model'", 'VL_FLOAT=1', "VL_FLOAT_SEGMENTS='model ctx'", "VL_FLOAT_SEP=' | '")
        $dConf = New-Conf $dDir 'coralline' $dLines
        $dLayout = Invoke-Generator -Conf $dConf -Dir $dDir -Placeholder
        function Set-DConf {
            <#
            .SYNOPSIS
              Rewrite the D coralline.conf with a VL_FLOAT_FILE value.
            .PARAMETER FloatFile
              VL_FLOAT_FILE as written into the conf.
            .EXAMPLE
              Set-DConf -FloatFile 'x.txt'
            #>
            param([string]$FloatFile)
            [void](New-Conf $dDir 'coralline' ($dLines + @("VL_FLOAT_FILE='" + $FloatFile + "'")))
        }
        $dPayload = '{"model":{"display_name":"Opus ' + $Marker + '"},"context_window":{"used_percentage":42}}'
        if (Test-NeedOmp 'D-normal-native-wrote') {
            $target = Join-Path $dOut 'float.txt'
            Set-DConf $target
            Remove-TestTree $target
            $native = Invoke-Native -Dir $Inst -Conf $dConf -Payload $dPayload
            $nativeBytes = Read-Maybe $target
            Remove-TestTree $target
            $wrapped = Invoke-Wrapper -Script $InstWrapper -Conf $dConf -Config $dLayout.Omp -OmpExe $InstOmp -Payload $dPayload
            $wrapperBytes = Read-Maybe $target
            Check 'D-normal-native-wrote' ($native.Exit -eq 0 -and $null -ne $nativeBytes -and $nativeBytes.Length -gt 1) ('exit ' + $native.Exit)
            Check 'D-normal-bytes-equal' ($wrapped.Exit -eq 0 -and (Test-SameBytes $nativeBytes $wrapperBytes)) ('native=[' + $(if ($null -ne $nativeBytes) { Show-Text $Utf8.GetString($nativeBytes) }) + '] wrapper=[' + $(if ($null -ne $wrapperBytes) { Show-Text $Utf8.GetString($wrapperBytes) }) + ']')
        } else { Blocked 'D-normal-bytes-equal' $OmpBlockReason }

        # Control characters: a statusline.ps1 copy whose strip pass appends BEL to VL_FLOAT_SEP afterwards
        # (config values lose their controls at load); two visible pieces put BEL into the line.
        $ctl = Join-Path $TempRoot 'ctl'
        Write-Utf8 (Join-Path $ctl 'statusline.ps1') ($NativeSource.Replace($HStripText, $HStripText.TrimEnd('}').TrimEnd() + "; if (`$key -ceq 'VL_FLOAT_SEP') { `$Cfg[`$key] = [string]`$Cfg[`$key] + [char]7 } }"))
        Write-Utf8 (Join-Path $ctl 'statusline-omp.ps1') $WrapperSource
        Write-Utf8 (Join-Path $ctl 'tools\build-omp-config.ps1') $GeneratorSource
        $ctlTarget = Join-Path $ctl 'out\float.txt'
        $ctlConf = New-Conf (Join-Path $ctl 'cfg') 'coralline' ($dLines + @("VL_FLOAT_FILE='" + $ctlTarget + "'"))
        $ctlLayout = Invoke-Generator -Conf $ctlConf -Dir (Join-Path $ctl 'cfg') -GeneratorDir $ctl
        if ($OmpReady) {
            $ctlRuns = @{}
            foreach ($kind in @('one', 'two')) {
                $payload = '{"model":{"display_name":"Opus"}}'
                if ($kind -eq 'two') { $payload = $dPayload }
                Remove-TestTree $ctlTarget
                $native = Invoke-Native -Dir $ctl -Conf $ctlConf -Payload $payload
                $nativeBytes = Read-Maybe $ctlTarget
                Remove-TestTree $ctlTarget
                $wrapped = Invoke-Wrapper -Script (Join-Path $ctl 'statusline-omp.ps1') -Conf $ctlConf -Config $ctlLayout.Omp -OmpExe $InstOmp -Payload $payload
                $ctlRuns[$kind] = @{ Native = $nativeBytes; Wrapper = (Read-Maybe $ctlTarget); NativeExit = $native.Exit; WrapperExit = $wrapped.Exit; WrapperText = $wrapped.Text }
            }
            $controlWrote = $null -ne $ctlRuns.one.Native -and (Test-SameBytes $ctlRuns.one.Native $ctlRuns.one.Wrapper)
            switch ($controlWrote) {
                $true {
                    Check 'D-ctrl-native-nowrite' ($ctlRuns.two.NativeExit -eq 0 -and $null -eq $ctlRuns.two.Native) 'native wrote a line holding BEL'
                    Check 'D-ctrl-wrapper-nowrite' ($ctlRuns.two.WrapperExit -eq 0 -and $null -eq $ctlRuns.two.Wrapper -and -not [string]::IsNullOrWhiteSpace((Get-Plain $ctlRuns.two.WrapperText))) 'wrapper wrote a line holding BEL or lost its main line'
                }
                default {
                    Blocked 'D-ctrl-native-nowrite' 'reachability control (one piece) did not write equal files'
                    Blocked 'D-ctrl-wrapper-nowrite' 'reachability control (one piece) did not write equal files'
                }
            }
        } else { Blocked 'D-ctrl-native-nowrite' $OmpBlockReason; Blocked 'D-ctrl-wrapper-nowrite' $OmpBlockReason }

        # Collisions: VL_FLOAT_FILE naming a file this wrapper owns, absolute, relative and with slashes.
        $dTargets = [ordered]@{ statusline = $InstNative; main = $dLayout.Omp; float = $dLayout.Float; auto = $dLayout.Auto }
        $dControls = @{}
        if ($OmpReady) {
            foreach ($control in @(@('abs', (Join-Path $dOut 'ctl-abs.txt'), $TempRoot), @('slash', (Join-Path $dOut 'ctl-slash.txt').Replace('\', '/'), $TempRoot),
                    @('rel-inst', 'd-ctl-rel.txt', $Inst), @('rel-cfg', 'd-ctl-rel.txt', $dDir))) {
                $written = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($control[2], $control[1]))
                Remove-TestTree $written
                Set-DConf $control[1]
                $run = Invoke-Wrapper -Script $InstWrapper -Conf $dConf -Config $dLayout.Omp -OmpExe $InstOmp -Payload $dPayload -Cwd $control[2]
                $dControls[$control[0]] = ($run.Exit -eq 0 -and [System.IO.File]::Exists($written))
                Remove-TestTree $written
            }
        }
        foreach ($name in $dTargets.Keys) {
            $target = [string]$dTargets[$name]
            $targetDir = [System.IO.Path]::GetDirectoryName($target)
            foreach ($form in @('abs', 'rel', 'slash')) {
                $id = 'D-collide-' + $name + '-' + $form
                if (-not (Test-NeedOmp $id)) { continue }
                $value = $target
                $cwd = $TempRoot
                $controlKey = $form
                switch ($form) {
                    'rel' { $value = [System.IO.Path]::GetFileName($target); $cwd = $targetDir; $controlKey = $(if ($targetDir -eq $Inst) { 'rel-inst' } else { 'rel-cfg' }) }
                    'slash' { $value = $target.Replace('\', '/') }
                }
                Assert-InsideTemp $target
                $before = Read-Maybe $target
                Set-DConf $value
                $run = Invoke-Wrapper -Script $InstWrapper -Conf $dConf -Config $dLayout.Omp -OmpExe $InstOmp -Payload $dPayload -Cwd $cwd
                $changed = Restore-File $target $before
                if ($dControls[$controlKey] -ne $true) { Blocked $id ('reachability control ' + $controlKey + ' did not write'); continue }
                Check $id ($run.Exit -eq 0 -and -not $changed) ('exit ' + $run.Exit + ' target changed=' + $changed)
            }
        }
    }

    # ============================================================================================
    # E: burn and VL_LIMIT_SYNC, replayed on pinned copies
    # ============================================================================================
    if (Test-GroupOn 'E') {
        $eRoot = Join-Path $TempRoot 'e'
        $eLayoutDir = Join-Path $eRoot 'layout'
        $eBase = @("VL_SEGMENTS='model burn'", 'VL_LIMIT_SYNC=1')
        $storeA = Join-Path $eRoot 'store-a'
        $storeB = Join-Path $eRoot 'store-b'
        $storeC = Join-Path $eRoot 'store-c'
        $confA = New-Conf $eLayoutDir 'coralline' ($eBase + (Get-StoreLines $storeA))
        $confB = New-Conf $eLayoutDir 'coralline-b' ($eBase + (Get-StoreLines $storeB))
        $eLayout = Invoke-Generator -Conf $confA -Dir $eLayoutDir -Placeholder
        $T = [long][Math]::Floor((Get-UnixNow) / 60.0) * 60L
        $steps = @(
            @{ Name = 'first-sample-warming'; At = 0; P5 = '10'; R5 = 9000 }
            @{ Name = 'one-crossing-warming'; At = 60; P5 = '11'; R5 = 9000 }
            @{ Name = 'rising-5h-active'; At = 120; P5 = '12'; R5 = 9000 }
            @{ Name = 'flat-5h-active'; At = 180; P5 = '12'; R5 = 9000 }
            @{ Name = 'idle-crossings-aged-out'; At = 1000; P5 = '12.5'; R5 = 9000 }
            @{ Name = 'window-reset-warming'; At = 9100; P5 = '3'; R5 = 27000 }
            @{ Name = 'eta-beyond-window-done'; At = 9460; P5 = '5'; R5 = 27000 }
            @{ Name = 'new-window-active'; At = 9520; P5 = '6'; R5 = 27000 }
        )
        $eControl = $false
        for ($k = 0; $k -lt $steps.Count; $k++) {
            $id = 'E-replay-' + ('{0:00}' -f ($k + 1)) + '-' + $steps[$k].Name
            if (-not (Test-NeedOmp $id)) { continue }
            Set-Pinned ($T + [long]$steps[$k].At)
            $payload = Get-RatePayload -P5 $steps[$k].P5 -R5 ($T + [long]$steps[$k].R5)
            $native = Invoke-Native -Dir $Pin -Conf $confA -Payload $payload
            $wrapped = Invoke-Wrapper -Script (Join-Path $Pin 'statusline-omp.ps1') -Conf $confB -Config $eLayout.Omp -OmpExe $InstOmp -Payload $payload
            $diff = ''
            switch ($true) {
                { $native.Exit -ne 0 -or $wrapped.Exit -ne 0 } { $diff = 'exit native=' + $native.Exit + ' wrapper=' + $wrapped.Exit; break }
                default { $diff = Compare-Render $native.Text $wrapped.Text }
            }
            $snapA = Get-StoreSnapshot $storeA
            $snapB = Get-StoreSnapshot $storeB
            if ($diff -eq '' -and $snapA -cne $snapB) { $diff = 'store A=' + $snapA + ' | store B=' + $snapB }
            if ($k -eq 0) { $eControl = [System.IO.File]::Exists((Join-Path $storeB 'burn.tsv')) }
            Check $id ($diff -eq '') $diff
        }
        if (Test-NeedOmp 'E-nosample-store-unchanged') {
            Set-Pinned ($T + 9580)
            $before = Get-StoreSnapshot $storeB
            $run = Invoke-Wrapper -Script (Join-Path $Pin 'statusline-omp.ps1') -Conf $confB -Config $eLayout.Omp -OmpExe $InstOmp -Payload (Get-RatePayload -P5 '7' -R5 ($T + 27000)) -Extra @{ CORALLINE_NO_SAMPLE = '1' }
            $after = Get-StoreSnapshot $storeB
            Check 'E-nosample-store-unchanged' ($run.Exit -eq 0 -and $before -ceq $after -and $before -notlike '<no store folder>*') ('before=' + $before + ' after=' + $after)
        }
        foreach ($case in @(@('E-collide-auto', $eLayout.Auto), @('E-collide-statusline', (Join-Path $Pin 'statusline.ps1')))) {
            if (-not (Test-NeedOmp $case[0])) { continue }
            $target = [string]$case[1]
            Assert-InsideTemp $target
            Set-Pinned ($T + 9640)
            $confC = New-Conf $eLayoutDir 'coralline-c' ($eBase + (Get-StoreLines $storeC $target))
            $before = Read-Maybe $target
            $run = Invoke-Wrapper -Script (Join-Path $Pin 'statusline-omp.ps1') -Conf $confC -Config $eLayout.Omp -OmpExe $InstOmp -Payload (Get-RatePayload -P5 '7' -R5 ($T + 27000))
            $changed = Restore-File $target $before
            if (-not $eControl) { Blocked $case[0] 'reachability control (replay step 1) did not write the burn store'; continue }
            Check $case[0] ($run.Exit -eq 0 -and -not $changed) ('exit ' + $run.Exit + ' target changed=' + $changed)
        }
    }

    # ============================================================================================
    # G: VL_LAYOUT=auto
    # ============================================================================================
    if (Test-GroupOn 'G') {
        $gSegments = "VL_SEGMENTS='model dir project git ctx cache limit5h limit7d cost'"
        $gCwd = $PlainDir
        if ($GitReady) { $gCwd = $RepoClean }
        $gPayloadTemplate = '{"model":{"display_name":"Claude Sonnet 5"},"workspace":{"current_dir":' + (ConvertTo-JsonLiteral $gCwd) + '},' +
            '"context_window":{"used_percentage":42,"total_input_tokens":5000,"total_output_tokens":800,"current_usage":{"cache_read_input_tokens":1200,"cache_creation_input_tokens":300}},' +
            '"prompt_cache":{"hit_ratio":0.9,"expires_at":{T+7230}},' +
            '"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":{T+9030}},"seven_day":{"used_percentage":10,"resets_at":{T+300630}}},"cost":{"total_cost_usd":0.42}}'
        foreach ($style in @('pill', 'lean')) {
            $layout = Get-Layout -Name ('g-' + $style) -Lines @('VL_LAYOUT=auto', ("VL_STYLE='" + $style + "'"), $gSegments) -Theme 'claude-coral'
            foreach ($columns in @('200', '80', '40')) {
                $id = 'G-auto-' + $style + '-c' + $columns
                if (-not (Test-NeedOmp $id)) { continue }
                if ($layout.Exit -ne 0 -or -not [System.IO.File]::Exists($layout.Auto)) { Check $id $false ('auto config not generated: ' + $layout.Err); continue }
                $pair = Invoke-MainPair -Layout $layout -Payload (Resolve-TimeTokens $gPayloadTemplate (Get-UnixNow)) -Extra @{ COLUMNS = $columns }
                Add-Note ($id + ': native rows=' + (Get-RowCount $pair.Native.Text) + ' wrapper rows=' + (Get-RowCount $pair.Wrapper.Text))
                Check $id ($pair.Diff -eq '') $pair.Diff
            }
        }
        if (Test-NeedOmp 'G-placeholder-single-row') {
            $ph = Get-Layout -Name 'g-placeholder' -Lines @('VL_LAYOUT=auto', "VL_STYLE='pill'", $gSegments) -Theme 'claude-coral'
            Write-Utf8 $ph.Auto "{`"var`":{`"CorallineGenerator`":`"coralline-omp/1`",`"CorallineAutoDisabled`":`"a required background is empty`"}}`n"
            $pair = Invoke-MainPair -Layout $ph -Payload (Resolve-TimeTokens $gPayloadTemplate (Get-UnixNow)) -Extra @{ COLUMNS = '40' }
            $nativeRows = Get-RowCount $pair.Native.Text
            $wrapperRows = Get-RowCount $pair.Wrapper.Text
            Check 'G-placeholder-single-row' ($pair.Wrapper.Exit -eq 0 -and $nativeRows -ge 2 -and $wrapperRows -eq 1) ('native rows=' + $nativeRows + ' wrapper rows=' + $wrapperRows)
        }
        if (Test-NeedOmp 'G-forged-marker-single-row') {
            $layout = Get-Layout -Name 'g-pill' -Lines @()
            $forged = (Resolve-TimeTokens $gPayloadTemplate (Get-UnixNow)).Replace('"Claude Sonnet 5"', '"Sonnet \ufdd0' + '1\ufdd1 x"')
            $pair = Invoke-MainPair -Layout $layout -Payload $forged -Extra @{ COLUMNS = '40' }
            $nativeRows = Get-RowCount $pair.Native.Text
            $wrapperRows = Get-RowCount $pair.Wrapper.Text
            Check 'G-forged-marker-single-row' ($pair.Wrapper.Exit -eq 0 -and $nativeRows -ge 2 -and $wrapperRows -eq 1) ('native rows=' + $nativeRows + ' wrapper rows=' + $wrapperRows)
        }
    }

    # ============================================================================================
    # I (end to end): R1 on the wrapper's protected paths
    # ============================================================================================
    if (Test-GroupOn 'I') {
        $iDir = Join-Path $TempRoot 'i\cfg'
        $iLines = @("VL_SEGMENTS='model burn limit5h'", 'VL_LIMIT_SYNC=1', 'VL_FLOAT=1', "VL_FLOAT_SEGMENTS='model'", "VL_BURN_GLYPH='BRN'")
        $iConf = New-Conf $iDir 'coralline' $iLines
        $iLayout = Invoke-Generator -Conf $iConf -Dir $iDir -Placeholder
        $script:IStoreCount = 0
        function New-IStore {
            <#
            .SYNOPSIS
              A fresh store folder name and the I conf rewritten for it; returns the folder.
            .PARAMETER BurnFile
              BURN_FILE, or '' for <store>\burn.tsv.
            .PARAMETER FloatFile
              VL_FLOAT_FILE, or '' for <store>\float.txt.
            .EXAMPLE
              New-IStore -BurnFile $target
            #>
            param([string]$BurnFile = '', [string]$FloatFile = '')
            $script:IStoreCount++
            $store = Join-Path $TempRoot ('i\st-' + $script:IStoreCount)
            if ($FloatFile -eq '') { $FloatFile = Join-Path $store 'float.txt' }
            [void](New-Conf $iDir 'coralline' ($iLines + (Get-StoreLines $store $BurnFile) + @("VL_FLOAT_FILE='" + $FloatFile + "'")))
            return $store
        }
        function Get-IPayload {
            <#
            .SYNOPSIS
              The I payload: model with the run marker, 5h window at 37%.
            .EXAMPLE
              Get-IPayload
            #>
            return Get-RatePayload -P5 '37' -R5 ((Get-UnixNow) + 9030) -Model ('Opus ' + $Marker)
        }
        $subjects = [ordered]@{
            main = @{ Target = $iLayout.Omp }
            floatcfg = @{ Target = $iLayout.Float }
            exe = @{ Target = $InstOmp }
            f2 = @{ Target = $InstNative }
        }
        foreach ($subjectName in $subjects.Keys) {
            foreach ($prefixPair in @(@('qC', '\\?\'), @('dC', '\\.\'))) {
                $prefix = [string]$prefixPair[1]
                $wrapperScript = $InstWrapper
                $config = $iLayout.Omp
                $floatConfig = ''
                $omp = $InstOmp
                switch ($subjectName) {
                    'main' { $config = $prefix + $iLayout.Omp }
                    'floatcfg' { $floatConfig = $prefix + $iLayout.Float }
                    'exe' { $omp = $prefix + $InstOmp }
                    'f2' { $wrapperScript = $prefix + $InstWrapper }
                }
                $base = 'I-e2e-' + $subjectName + '-' + $prefixPair[0]
                if (-not $OmpReady) { Blocked ($base + '-burn') $OmpBlockReason; Blocked ($base + '-float') $OmpBlockReason; continue }
                $store = New-IStore
                $run = Invoke-Wrapper -Script $wrapperScript -Conf $iConf -Config $config -OmpExe $omp -FloatConfig $floatConfig -Payload (Get-IPayload)
                $control = $run.Exit -eq 0 -and [System.IO.File]::Exists((Join-Path $store 'burn.tsv')) -and [System.IO.File]::Exists((Join-Path $store 'float.txt'))
                if (-not $control) { Add-Note ($base + ' control: exit=' + $run.Exit + ' out=' + (Show-Text $run.Text) + ' err=' + (Show-Text $run.Err)) }
                $target = [string]$subjects[$subjectName].Target
                foreach ($variant in @('burn', 'float')) {
                    $id = $base + '-' + $variant
                    Assert-InsideTemp $target
                    $before = Read-Maybe $target
                    switch ($variant) {
                        'burn' { [void](New-IStore -BurnFile $target) }
                        default { [void](New-IStore -FloatFile $target) }
                    }
                    $run = Invoke-Wrapper -Script $wrapperScript -Conf $iConf -Config $config -OmpExe $omp -FloatConfig $floatConfig -Payload (Get-IPayload)
                    $changed = Restore-File $target $before
                    if (-not $control) { Blocked $id 'reachability control (same prefix, non-colliding store and float file) did not write both'; continue }
                    Check $id ($run.Exit -eq 0 -and -not $changed) ('exit ' + $run.Exit + ' target changed=' + $changed)
                }
            }
        }

        # Fail-closed: \\?\Volume{GUID}\ and \\?\GLOBALROOT\Device\... aliases, with a plain drive-letter control (F7).
        $f7Ok = $false
        if (Test-NeedOmp 'I-f7-plain-not-failclosed') {
            $store = New-IStore
            $run = Invoke-Wrapper -Script $InstWrapper -Conf $iConf -Config $iLayout.Omp -OmpExe $InstOmp -Payload (Get-IPayload)
            $plain = Get-Plain $run.Text
            $f7Ok = $run.Exit -eq 0 -and $plain.Contains($Marker) -and $plain.Contains('BRN') -and $plain.Contains('37%') -and
                [System.IO.File]::Exists((Join-Path $store 'burn.tsv')) -and [System.IO.File]::Exists((Join-Path $store 'float.txt'))
            Check 'I-f7-plain-not-failclosed' $f7Ok ('exit ' + $run.Exit + ' out=' + (Show-Text $plain) + ' store=' + (Get-StoreSnapshot $store))
        }
        $aliases = @(
            , @('I-failclosed-volume-config', 'config', 'volume')
            , @('I-failclosed-globalroot-config', 'config', 'globalroot')
            , @('I-failclosed-volume-wrapper', 'wrapper', 'volume')
            , @('I-failclosed-globalroot-wrapper', 'wrapper', 'globalroot')
        )
        foreach ($alias in $aliases) {
            $id = [string]$alias[0]
            if (-not (Test-NeedOmp $id)) { continue }
            $root = ''
            switch ($alias[2]) {
                'volume' { if ($VolumeName -ne '') { $root = '\\?\' + $VolumeName } }
                default { if ($DeviceName -ne '') { $root = '\\?\GLOBALROOT' + $DeviceName } }
            }
            if ($root -eq '') { Blocked $id ('cannot name the ' + $alias[2] + ' of ' + $TempDrive + ' (mountvol / QueryDosDevice failed)'); continue }
            $plainPath = $iLayout.Omp
            if ($alias[1] -eq 'wrapper') { $plainPath = $InstWrapper }
            $aliasPath = $root + '\' + $plainPath.Substring(3)
            $same = $false
            try { $same = Test-SameBytes ([System.IO.File]::ReadAllBytes($aliasPath)) ([System.IO.File]::ReadAllBytes($plainPath)) } catch { $same = $false }
            if (-not $same) { Blocked $id ('alias does not resolve to the same file: ' + $aliasPath); continue }
            $store = New-IStore
            $wrapperScript = $InstWrapper
            $config = $iLayout.Omp
            switch ($alias[1]) {
                'config' { $config = $aliasPath }
                default { $wrapperScript = $aliasPath }
            }
            $run = Invoke-Wrapper -Script $wrapperScript -Conf $iConf -Config $config -OmpExe $InstOmp -Payload (Get-IPayload)
            $plain = Get-Plain $run.Text
            $closed = $run.Exit -eq 0 -and $plain.Contains($Marker) -and -not $plain.Contains('BRN') -and -not $plain.Contains('37%') -and
                -not [System.IO.File]::Exists((Join-Path $store 'burn.tsv')) -and -not [System.IO.File]::Exists((Join-Path $store 'float.txt')) -and -not [System.IO.Directory]::Exists((Join-Path $store 'rl5.d'))
            if (-not $f7Ok) { Blocked $id 'reachability control I-f7-plain-not-failclosed did not write'; continue }
            Check $id $closed ('exit ' + $run.Exit + ' out=' + (Show-Text $plain) + ' store=' + (Get-StoreSnapshot $store))
        }
    }
} catch {
    Check 'X-run-completed' $false ($_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
}

# ============================================================================================
# Witnesses, marker scan, cleanup
# ============================================================================================
$witnessDiff = @($WitnessFiles | Where-Object { (Get-Sha256 $_) -ne $WitnessBefore[$_] })
Check 'X-witness-repo-files-unchanged' ($witnessDiff.Count -eq 0) ('changed: ' + ($witnessDiff -join ', '))
if ($OmpReady) { Check 'X-witness-omp-source-unchanged' ((Get-Sha256 $OmpCandidate) -eq $OmpWitnessBefore) $OmpCandidate }
Check 'X-witness-path-alias-unchanged' ((Get-AliasWitness $PathOmp) -ceq $AliasWitnessBefore) ('before=' + $AliasWitnessBefore + ' after=' + (Get-AliasWitness $PathOmp))
$realCoralline = [System.IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.claude\coralline')
$markerHits = New-Object 'System.Collections.Generic.List[string]'
if ([System.IO.Directory]::Exists($realCoralline)) {
    foreach ($file in @(Get-ChildItem -LiteralPath $realCoralline -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $StartUtc.AddSeconds(-2) -and $_.Length -le 8388608 })) {
        try {
            $text = $Utf8.GetString([System.IO.File]::ReadAllBytes($file.FullName))
            if ($text.IndexOf($RunId, [StringComparison]::Ordinal) -ge 0 -or $text.IndexOf($Marker, [StringComparison]::Ordinal) -ge 0) { [void]$markerHits.Add($file.FullName) }
        } catch { }
    }
}
Check 'X-marker-absent-from-real-coralline' ($markerHits.Count -eq 0) ($markerHits -join ', ')
$keep = $script:Fail -gt 0 -and $Mutation -eq ''
if ($keep) { Add-Note ('temporary root kept for inspection: ' + $TempRoot) }
else {
    $cleanupError = ''
    try { Remove-TestTree $TempRoot } catch { $cleanupError = $_.Exception.Message }
    Check 'X-cleanup' (-not [System.IO.Directory]::Exists($TempRoot)) $cleanupError
}

# ============================================================================================
# Verdicts
# ============================================================================================
$exitCode = 0
if ($script:Fail -gt 0) { $exitCode = 1 }
$strictProblems = New-Object 'System.Collections.Generic.List[string]'
foreach ($letter in $MinimumPass.Keys) {
    if (-not (Test-GroupOn $letter)) { continue }
    $passed = @($script:Results | Where-Object { $_.Group -eq $letter -and $_.Status -eq 'PASS' }).Count
    $state = 'ok'
    if ($passed -lt $MinimumPass[$letter]) { $state = 'BELOW'; [void]$strictProblems.Add('group ' + $letter + ' pass=' + $passed + ' < ' + $MinimumPass[$letter]) }
    [Console]::Out.WriteLine('GROUP ' + $letter + ' pass=' + $passed + ' min=' + $MinimumPass[$letter] + ' ' + $state)
}
foreach ($result in $script:Results) {
    if ($result.Status -ne 'BLOCKED') { continue }
    $allowed = $false
    foreach ($prefix in $AllowedBlockedPrefixes) { if (([string]$result.Detail).StartsWith($prefix, [StringComparison]::Ordinal)) { $allowed = $true } }
    if (-not $allowed) { [void]$strictProblems.Add('blocked outside the allow-list: ' + $result.Id) }
}
if ($null -ne $MutationSpec) {
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $MutationSpec.ExpectFail) {
        $hit = @($script:Results | Where-Object { $_.Id -eq $id -and $_.Status -eq 'FAIL' }).Count
        if ($hit -eq 0) { [void]$missing.Add($id) }
    }
    $extra = @($script:Results | Where-Object { $_.Status -eq 'FAIL' -and $MutationSpec.ExpectFail -notcontains $_.Id } | ForEach-Object { $_.Id })
    [Console]::Out.WriteLine('MUTATION ' + $Mutation + ' expected=' + $MutationSpec.ExpectFail.Count + ' failed-as-expected=' + ($MutationSpec.ExpectFail.Count - $missing.Count) +
        ' missing=[' + ($missing -join ',') + '] other-fails=[' + ($extra -join ',') + ']')
    $exitCode = $(if ($missing.Count -eq 0) { 0 } else { 1 })
} elseif ($Strict -and $exitCode -eq 0 -and $strictProblems.Count -gt 0) {
    foreach ($problem in $strictProblems) { [Console]::Out.WriteLine('STRICT  ' + $problem) }
    $exitCode = 2
}
[Console]::Out.WriteLine('SUMMARY pass=' + $script:Pass + ' fail=' + $script:Fail + ' blocked=' + $script:Blocked + ' seconds=' + [int]$Clock.Elapsed.TotalSeconds + ' host=' + $HostTag)
exit $exitCode
