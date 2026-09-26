#Requires -Version 5.1
<#
  Hermetic native installer regression tests.

  Run with Windows PowerShell 5.1:
    powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File test\test-install-ps1.ps1
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$Installer = Join-Path $Repo 'install.ps1'
$PowerShellExe = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('c 雪&(p)-' + [guid]::NewGuid().ToString('N'))
$script:Pass = 0
$script:Fail = 0
$script:Blocked = 0

$ExpectedThemes = @(
    'catppuccin-mocha.conf',
    'claude-coral.conf',
    'dracula.conf',
    'gruvbox-dark.conf',
    'lunar-pink.conf',
    'mono.conf',
    'morning-haze.conf',
    'nord.conf',
    'reverie.conf',
    'tokyo-night.conf'
)
$ExpectedManaged = @('statusline.ps1') + @($ExpectedThemes | ForEach-Object { 'themes\' + $_ })

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) {
        [Console]::Out.WriteLine("PASS  $Name")
        $script:Pass++
    } else {
        [Console]::Out.WriteLine("FAIL  $Name")
        $script:Fail++
    }
}

function Blocked([string]$Name, [string]$Reason) {
    [Console]::Out.WriteLine("BLOCKED  ${Name}: $Reason")
    $script:Blocked++
}

function Write-Utf8([string]$Path, [string]$Text) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Write-Utf8Bom([string]$Path, [string]$Text) {
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    $content = $Utf8NoBom.GetBytes($Text)
    $bytes = New-Object byte[] ($content.Length + 3)
    $bytes[0] = 0xef
    $bytes[1] = 0xbb
    $bytes[2] = 0xbf
    [Array]::Copy($content, 0, $bytes, 3, $content.Length)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value.IndexOf('"') -ge 0) { throw 'test process arguments may not contain quotes' }
    return '"' + $Value + '"'
}

function Invoke-CapturedProcess(
    [string]$FileName,
    [string]$Arguments,
    [string]$InputText,
    [hashtable]$Environment,
    [string]$WorkingDirectory,
    [int]$TimeoutMs
) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $FileName
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $start.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$start.EnvironmentVariables.Remove($key) }
        else { $start.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'process did not start' }
        $stdout = New-Object System.IO.MemoryStream
        $stderr = New-Object System.IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $inputBytes = $Utf8NoBom.GetBytes($InputText)
        if ($inputBytes.Length -gt 0) {
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
        }
        $process.StandardInput.Close()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
        }
        [void]$outTask.Wait(2000)
        [void]$errTask.Wait(2000)
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
        try { $outText = $StrictUtf8.GetString($outBytes) } catch { $outText = $null }
        try { $errText = $StrictUtf8.GetString($errBytes) } catch { $errText = $null }
        $exitCode = -1
        if (-not $timedOut -and $process.HasExited) { $exitCode = $process.ExitCode }
        $stdout.Dispose()
        $stderr.Dispose()
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            Stdout = $outText
            Stderr = $errText
            StdoutBytes = $outBytes
            StderrBytes = $errBytes
        }
    } catch {
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Stdout = ''
            Stderr = $_.Exception.Message
            StdoutBytes = [byte[]]@()
            StderrBytes = $Utf8NoBom.GetBytes($_.Exception.Message)
        }
    } finally {
        $process.Dispose()
    }
}

function Invoke-Installer(
    [string]$Source,
    [string]$Install,
    [string]$Settings,
    [string]$SubagentRows = '',
    # native keeps every case deterministic whether or not this host has Git
    # Bash; 'default' omits the flag to exercise the installer default (auto).
    [string]$Runtime = 'native',
    [string]$InstallerPath = $Installer,
    [hashtable]$ExtraEnvironment = @{}
) {
    $argumentParts = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy Bypass',
        '-File ' + (Quote-ProcessArgument $InstallerPath),
        '-SourceDirectory ' + (Quote-ProcessArgument $Source),
        '-InstallRoot ' + (Quote-ProcessArgument $Install),
        '-SettingsPath ' + (Quote-ProcessArgument $Settings)
    )
    if (-not [string]::IsNullOrEmpty($SubagentRows)) {
        $argumentParts += '-SubagentRows ' + (Quote-ProcessArgument $SubagentRows)
    }
    if ($Runtime -cne 'default') {
        $argumentParts += '-Runtime ' + (Quote-ProcessArgument $Runtime)
    }
    $arguments = $argumentParts -join ' '
    $environment = @{
        CORALLINE_REPO = 'must-not-be-read'
        CORALLINE_REF = 'must-not-be-read'
        CORALLINE_BASE_URL = 'https://127.0.0.1:1/must-not-be-read'
    }
    foreach ($key in $ExtraEnvironment.Keys) { $environment[$key] = $ExtraEnvironment[$key] }
    return Invoke-CapturedProcess $PowerShellExe $arguments '' $environment $Repo 30000
}

# Installer errors can carry a non-ASCII path in the console code page, which
# is not strict UTF-8; ASCII decoding keeps every ASCII needle intact.
function Get-ErrorText($Run) {
    return [Text.Encoding]::ASCII.GetString($Run.StderrBytes)
}

function Get-OutputText($Run) {
    return [Text.Encoding]::ASCII.GetString($Run.StdoutBytes)
}

# Test oracle for install.ps1's Git Bash resolution: the 64-bit HKLM
# GitForWindows InstallPath, else Program Files\Git. $null when absent.
function Get-ExpectedGitBash {
    $candidate = $null
    $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $key = $hive.OpenSubKey('SOFTWARE\GitForWindows')
        if ($null -ne $key) {
            try { $value = $key.GetValue('InstallPath') } finally { $key.Dispose() }
            if ($value -is [string] -and $value.Length -gt 0) {
                $candidate = Join-Path $value 'bin\bash.exe'
            }
        }
    } finally {
        $hive.Dispose()
    }
    if ($null -eq $candidate) {
        $candidate = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Git\bin\bash.exe'
    }
    $candidate = [IO.Path]::GetFullPath($candidate)
    if ([IO.File]::Exists($candidate)) { return $candidate }
    return $null
}

# Windows argv quoting (CommandLineToArgvW / MSYS rules) for one argument.
function ConvertTo-ProcessArgument([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append([char]'\', 2 * $slashes + 1)
        } elseif ($slashes -gt 0) {
            [void]$builder.Append([char]'\', $slashes)
        }
        $slashes = 0
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append([char]'\', 2 * $slashes) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# A copy of install.ps1 whose Git Bash lookup is replaced, to simulate a
# machine without Git for Windows or jq. The shipped installer is unchanged.
function New-StubInstaller([string]$Name, [string]$StubFunction) {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'cannot parse installer for stub copy' }
    $entry = $ast.EndBlock.Statements[$ast.EndBlock.Statements.Count - 1]
    $text = $ast.Extent.Text
    $stubbed = $text.Substring(0, $entry.Extent.StartOffset) + $StubFunction + "`r`n" +
        $text.Substring($entry.Extent.StartOffset)
    $path = Join-Path $TempRoot ($Name + '.ps1')
    Write-Utf8Bom $path $stubbed
    return $path
}

function New-Paths([string]$Name) {
    $fixtureHome = Join-Path $TempRoot $Name
    $claude = Join-Path $fixtureHome '.claude'
    return [pscustomobject]@{
        Home = $fixtureHome
        Claude = $claude
        Install = (Join-Path $claude 'coralline')
        Settings = (Join-Path $claude 'settings.json')
        Config = (Join-Path $claude 'coralline.conf')
    }
}

function ConvertTo-TestJsonString([string]$Value) {
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            8 { [void]$builder.Append('\b') }
            9 { [void]$builder.Append('\t') }
            10 { [void]$builder.Append('\n') }
            12 { [void]$builder.Append('\f') }
            13 { [void]$builder.Append('\r') }
            34 { [void]$builder.Append('\"') }
            92 { [void]$builder.Append('\\') }
            default {
                if ([int]$character -lt 0x20) {
                    [void]$builder.Append(('\u{0:x4}' -f [int]$character))
                } else {
                    [void]$builder.Append($character)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-DesiredCommand([string]$Install) {
    $exe = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
    $runtime = [IO.Path]::GetFullPath((Join-Path $Install 'statusline.ps1'))
    return '"' + $exe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runtime + '"'
}

function Get-DesiredValue([string]$Install) {
    return '{"type":"command","command":' +
        (ConvertTo-TestJsonString (Get-DesiredCommand $Install)) +
        ',"refreshInterval":2}'
}

function Get-DesiredSubagentCommand([string]$Install) {
    return (Get-DesiredCommand $Install) + ' --subagent'
}

function Get-DesiredSubagentValue([string]$Install) {
    return '{"type":"command","command":' +
        (ConvertTo-TestJsonString (Get-DesiredSubagentCommand $Install)) +
        '}'
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-ManagedSnapshot([string]$Install, [string]$Settings) {
    $snapshot = [ordered]@{}
    foreach ($relative in $ExpectedManaged) {
        $path = Join-Path $Install $relative
        $item = Get-Item -LiteralPath $path
        $snapshot["file:$relative"] = (Get-FileSha256 $path) + ':' + $item.LastWriteTimeUtc.Ticks
    }
    $installItem = Get-Item -LiteralPath $Install
    $settingsItem = Get-Item -LiteralPath $Settings
    $snapshot['install-times'] = "$($installItem.CreationTimeUtc.Ticks):$($installItem.LastWriteTimeUtc.Ticks)"
    $snapshot['settings'] = (Get-FileSha256 $Settings) + ':' + $settingsItem.LastWriteTimeUtc.Ticks
    return ,$snapshot
}

function Test-SnapshotsEqual($First, $Second) {
    if ($First.Count -ne $Second.Count) { return $false }
    foreach ($key in $First.Keys) {
        if (-not $Second.Contains($key) -or $First[$key] -cne $Second[$key]) { return $false }
    }
    return $true
}

function Get-RelativeFileSnapshot(
    [string]$Root,
    [string[]]$RelativePaths,
    [bool]$IncludeTimestamps
) {
    $snapshot = [ordered]@{}
    foreach ($relative in $RelativePaths) {
        $path = Join-Path $Root $relative
        $value = Get-FileSha256 $path
        if ($IncludeTimestamps) {
            $value += ':' + (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
        }
        $snapshot[$relative] = $value
    }
    return ,$snapshot
}

function Get-BackupCount([string]$Directory, [string]$Pattern) {
    if (-not [IO.Directory]::Exists($Directory)) { return 0 }
    return @([IO.Directory]::GetFileSystemEntries($Directory, $Pattern)).Count
}

function Test-InvalidSettings(
    [string]$Name,
    [string]$Text,
    [string]$SubagentRows = ''
) {
    $paths = New-Paths ('invalid-' + $Name)
    [void][IO.Directory]::CreateDirectory($paths.Claude)
    Write-Utf8 $paths.Settings $Text
    $before = [IO.File]::ReadAllBytes($paths.Settings)
    $run = Invoke-Installer $Repo $paths.Install $paths.Settings $SubagentRows
    Check "$Name rejected" (-not $run.TimedOut -and $run.ExitCode -ne 0)
    Check "$Name settings unchanged" (
        [Convert]::ToBase64String($before) -ceq
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.Settings))
    )
    Check "$Name runtime not installed" (-not [IO.Directory]::Exists($paths.Install))
    Check "$Name no settings backup" ((Get-BackupCount $paths.Claude 'settings.json.bak.*') -eq 0)
}

function Copy-ManagedSource([string]$Destination, [bool]$WithShellRuntime = $false) {
    $relatives = $ExpectedManaged
    if ($WithShellRuntime) { $relatives = @($ExpectedManaged) + 'statusline.sh' }
    foreach ($relative in $relatives) {
        $source = Join-Path $Repo $relative
        $target = Join-Path $Destination $relative
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::Copy($source, $target, $false)
    }
}

function Get-InstallerTransactionFunctions {
    $wanted = @(
        'Test-HasControlCharacter',
        'Assert-SafePathSegments',
        'Resolve-CanonicalLocalPath',
        'Assert-NoReparsePath',
        'Assert-SafeExistingFile',
        'Ensure-SafeDirectory',
        'Remove-SafeInstallerFile',
        'Test-FilesEqual',
        'Test-ByteArraysEqual',
        'Read-BoundedSharedFileBytes',
        'Write-BytesCreateNew',
        'Assert-SettingsBytes',
        'Restore-SettingsOriginal',
        'Commit-Settings',
        'Test-DirectoryEmpty',
        'Remove-EmptyCreatedRuntime',
        'Restore-ManagedRuntime',
        'Assert-ManagedPayloadBytes',
        'Get-ManagedFileLimit'
    )
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $Installer,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) { throw 'cannot parse installer functions for regression test' }
    $functions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name })
    if ($functions.Count -ne $wanted.Count) { throw 'installer commit function set is incomplete' }
    return ($functions | ForEach-Object { $_.Extent.Text }) -join "`r`n"
}

if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
    [Console]::Error.WriteLine('error: run this suite on native Windows PowerShell 5.1 Desktop')
    exit 1
}

[void][IO.Directory]::CreateDirectory($TempRoot)
try {
    $repoThemes = @(
        Get-ChildItem -LiteralPath (Join-Path $Repo 'themes') -File -Filter '*.conf' |
            Select-Object -ExpandProperty Name |
            Sort-Object
    )
    Check 'allowlist has exactly ten themes' ($ExpectedThemes.Count -eq 10)
    Check 'allowlist equals shipped themes' (
        (($ExpectedThemes | Sort-Object) -join "`n") -ceq ($repoThemes -join "`n")
    )

    $main = New-Paths 'home Ω & (accepted)'
    [void][IO.Directory]::CreateDirectory($main.Claude)
    $configText = '# preserved config' + "`n" + 'VL_STYLE="lean"' + "`n" + '# 雪' + "`n"
    Write-Utf8 $main.Config $configText
    $configHash = Get-FileSha256 $main.Config

    $prefix = '{' + "`r`n" +
        '  "deep": {"非ASCII":"雪","items":[1,{"x":[true,false,null]}]},' + "`r`n" +
        '  "maximum": 9223372036854775807,' + "`r`n" +
        '  "minimum": -9223372036854775808,' + "`r`n" +
        '  "precise": 123456789012345678901234567890.0000000000000000001e+999,' + "`r`n" +
        '  "StatusLine": {"keep":true},' + "`r`n" +
        '  "statusline": "lower-case stays",' + "`r`n" +
        '  "statusLine": '
    $oldManaged = '{ "old": true, "refreshInterval": 99 }'
    $suffix = ',' + "`r`n" + '  "tail": "unchanged\\value"' + "`r`n" + '}' + "`r`n"
    Write-Utf8 $main.Settings ($prefix + $oldManaged + $suffix)

    $fresh = Invoke-Installer $Repo $main.Install $main.Settings
    Check 'fresh install no timeout' (-not $fresh.TimedOut)
    Check 'fresh install exit 0' ($fresh.ExitCode -eq 0)
    Check 'fresh install no stderr' ($fresh.StderrBytes.Length -eq 0)
    if ($fresh.ExitCode -ne 0) {
        [Console]::Out.WriteLine('DIAG  fresh stderr=' + [Convert]::ToBase64String($fresh.StderrBytes))
    }

    $installedFiles = @(
        Get-ChildItem -LiteralPath $main.Install -File -Recurse |
            ForEach-Object { $_.FullName.Substring($main.Install.Length + 1).Replace('/', '\') } |
            Sort-Object
    )
    Check 'installed exact 11-file inventory' (
        (($ExpectedManaged | Sort-Object) -join "`n") -ceq ($installedFiles -join "`n")
    )
    Check 'installed exact ten-theme inventory' (
        @(Get-ChildItem -LiteralPath (Join-Path $main.Install 'themes') -File).Count -eq 10
    )

    $desiredCommand = Get-DesiredCommand $main.Install
    $desiredSubagentCommand = Get-DesiredSubagentCommand $main.Install
    $desiredValue = Get-DesiredValue $main.Install
    $settingsText = $StrictUtf8.GetString([IO.File]::ReadAllBytes($main.Settings))
    Check 'lossless raw settings merge' ($settingsText -ceq ($prefix + $desiredValue + $suffix))
    Check 'numeric lexemes preserved' (
        $settingsText.Contains('9223372036854775807') -and
        $settingsText.Contains('-9223372036854775808') -and
        $settingsText.Contains('123456789012345678901234567890.0000000000000000001e+999')
    )
    Check 'case-distinct and non-ASCII members preserved' (
        $settingsText.Contains('"StatusLine": {"keep":true}') -and
        $settingsText.Contains('"statusline": "lower-case stays"') -and
        $settingsText.Contains('"非ASCII":"雪"')
    )
    $managedObject = $desiredValue | ConvertFrom-Json
    Check 'settings type command' ($managedObject.type -ceq 'command')
    Check 'settings command exact absolute trusted executable' ($managedObject.command -ceq $desiredCommand)
    Check 'settings command contains Bypass' ($managedObject.command.Contains('-ExecutionPolicy Bypass'))
    Check 'settings refreshInterval 2' ($managedObject.refreshInterval -eq 2)
    Check 'ordinary install preserves missing subagent target' (
        -not $settingsText.Contains('"subagentStatusLine"')
    )
    Check 'config hash preserved' ((Get-FileSha256 $main.Config) -ceq $configHash)

    $preservedFiles = @(
        'burn-5h.tsv',
        'burn-5h.d\1710000000.010.000.host.1.0001',
        'limit-5h.d\1710000000.020.000.host.1.0001',
        'limit-7d.d\1710000000.030.000.host.1.0001',
        'float.txt',
        'themes\custom-local.conf',
        'custom-state\nested\keep.txt'
    )
    foreach ($relative in $preservedFiles) {
        Write-Utf8 (Join-Path $main.Install $relative) ("preserve:$relative`n")
    }
    $preservedTimedBefore = Get-RelativeFileSnapshot $main.Install $preservedFiles $true

    $snapshotBefore = Get-ManagedSnapshot $main.Install $main.Settings
    $runtimeBackupsBefore = Get-BackupCount $main.Claude 'coralline.bak.*'
    $settingsBackupsBefore = Get-BackupCount $main.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $second = Invoke-Installer $Repo $main.Install $main.Settings
    $snapshotAfter = Get-ManagedSnapshot $main.Install $main.Settings
    Check 'identical rerun exit 0' ($second.ExitCode -eq 0)
    Check 'identical rerun reports no-op' ($second.Stdout -ceq "coralline is already up to date.`r`n")
    Check 'identical rerun preserves hashes and timestamps' (Test-SnapshotsEqual $snapshotBefore $snapshotAfter)
    Check 'identical rerun creates no runtime backup' (
        (Get-BackupCount $main.Claude 'coralline.bak.*') -eq $runtimeBackupsBefore
    )
    Check 'identical rerun creates no settings backup' (
        (Get-BackupCount $main.Claude 'settings.json.bak.*') -eq $settingsBackupsBefore
    )
    Check 'identical rerun preserves config' ((Get-FileSha256 $main.Config) -ceq $configHash)
    Check 'identical rerun preserves runtime state and custom files' (
        Test-SnapshotsEqual $preservedTimedBefore (
            Get-RelativeFileSnapshot $main.Install $preservedFiles $true
        )
    )

    $updateSource = Join-Path $TempRoot 'state-update-source'
    Copy-ManagedSource $updateSource
    [IO.File]::AppendAllText(
        (Join-Path $updateSource 'themes\mono.conf'),
        ("`n" + '# state-preserving update' + "`n"),
        $Utf8NoBom
    )
    $preservedSnapshotBeforeUpdate = Get-RelativeFileSnapshot $main.Install $preservedFiles $true
    $stateUpdate = Invoke-Installer $updateSource $main.Install $main.Settings
    Check 'changed runtime update exit 0' ($stateUpdate.ExitCode -eq 0)
    Check 'changed runtime update does not touch runtime state and custom files' (
        Test-SnapshotsEqual $preservedSnapshotBeforeUpdate (
            Get-RelativeFileSnapshot $main.Install $preservedFiles $true
        )
    )

    $oversized = New-Paths 'oversized-unmanaged'
    $oversizedFresh = Invoke-Installer $Repo $oversized.Install $oversized.Settings
    Check 'oversized fixture fresh install' ($oversizedFresh.ExitCode -eq 0)
    $oversizedFile = Join-Path $oversized.Install 'oversized-state.bin'
    [IO.File]::WriteAllBytes($oversizedFile, (New-Object byte[] (2MB + 1)))
    $oversizedHash = Get-FileSha256 $oversizedFile
    $oversizedBackups = Get-BackupCount $oversized.Claude 'coralline.bak.*'
    $oversizedSource = Join-Path $TempRoot 'oversized-source'
    Copy-ManagedSource $oversizedSource
    [IO.File]::AppendAllText(
        (Join-Path $oversizedSource 'themes\mono.conf'),
        ("`n" + '# oversized preservation rejection' + "`n"),
        $Utf8NoBom
    )
    $oversizedRun = Invoke-Installer $oversizedSource $oversized.Install $oversized.Settings
    Check 'oversized unmanaged content does not block update' ($oversizedRun.ExitCode -eq 0)
    Check 'oversized unmanaged update installs changed runtime' (
        (Get-FileSha256 (Join-Path $oversized.Install 'themes\mono.conf')) -ceq
        (Get-FileSha256 (Join-Path $oversizedSource 'themes\mono.conf'))
    )
    Check 'oversized unmanaged update preserves unmanaged bytes' (
        (Get-FileSha256 $oversizedFile) -ceq $oversizedHash
    )
    Check 'oversized unmanaged update creates one runtime backup' (
        (Get-BackupCount $oversized.Claude 'coralline.bak.*') -eq ($oversizedBackups + 1)
    )

    $unmanagedTarget = Join-Path $oversized.Home 'unmanaged-junction-target'
    $unmanagedJunction = Join-Path $oversized.Install 'unmanaged-junction'
    [void][IO.Directory]::CreateDirectory($unmanagedTarget)
    Write-Utf8 (Join-Path $unmanagedTarget 'canary.txt') 'keep'
    $unmanagedJunctionCreate = Invoke-CapturedProcess $env:ComSpec (
        '/d /s /c "mklink /J ' + (Quote-ProcessArgument $unmanagedJunction) + ' ' +
        (Quote-ProcessArgument $unmanagedTarget) + '"'
    ) '' @{} $TempRoot 10000
    if ($unmanagedJunctionCreate.ExitCode -eq 0 -and
        [IO.Directory]::Exists($unmanagedJunction)) {
        $unmanagedJunctionRun = Invoke-Installer (
            $oversizedSource
        ) $oversized.Install $oversized.Settings
        Check 'unmanaged reparse entry does not block no-op' (
            $unmanagedJunctionRun.ExitCode -eq 0 -and
            $unmanagedJunctionRun.Stdout -ceq "coralline is already up to date.`r`n"
        )
        Check 'unmanaged reparse entry remains in place' (
            [IO.Directory]::Exists($unmanagedJunction)
        )
        Check 'unmanaged reparse canary preserved' (
            [IO.File]::ReadAllText(
                (Join-Path $unmanagedTarget 'canary.txt'),
                $StrictUtf8
            ) -ceq 'keep'
        )
        [void](Invoke-CapturedProcess $env:ComSpec (
            '/d /s /c "rmdir ' + (Quote-ProcessArgument $unmanagedJunction) + '"'
        ) '' @{} $TempRoot 10000)
    } else {
        Blocked 'unmanaged reparse no-op' 'mklink /J was unavailable in this Windows environment'
    }

    $noConfig = New-Paths 'no-config'
    $noConfigRun = Invoke-Installer $Repo $noConfig.Install $noConfig.Settings
    Check 'fresh missing-settings install exit 0' ($noConfigRun.ExitCode -eq 0)
    Check 'installer never creates config' (-not [IO.File]::Exists($noConfig.Config))
    Check 'new settings has no backup' ((Get-BackupCount $noConfig.Claude 'settings.json.bak.*') -eq 0)
    Check 'missing-settings default creates only main statusLine' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($noConfig.Settings)) -ceq
        ('{"statusLine":' + (Get-DesiredValue $noConfig.Install) + '}')
    )

    $refresh1 = New-Paths 'refresh-rewrite-from-1'
    [void][IO.Directory]::CreateDirectory($refresh1.Claude)
    $refresh1Old = '{"type":"command","command":' +
        (ConvertTo-TestJsonString (Get-DesiredCommand $refresh1.Install)) +
        ',"refreshInterval":1}'
    Write-Utf8 $refresh1.Settings ('{"statusLine":' + $refresh1Old + '}')
    $refresh1Run = Invoke-Installer $Repo $refresh1.Install $refresh1.Settings
    Check 'refreshInterval 1 rewrite exit 0' ($refresh1Run.ExitCode -eq 0)
    Check 'existing refreshInterval 1 rewritten to 2' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($refresh1.Settings)) -ceq
        ('{"statusLine":' + (Get-DesiredValue $refresh1.Install) + '}')
    )

    $refresh5 = New-Paths 'refresh-rewrite-from-5'
    [void][IO.Directory]::CreateDirectory($refresh5.Claude)
    $refresh5Old = '{"type":"command","command":' +
        (ConvertTo-TestJsonString (Get-DesiredCommand $refresh5.Install)) +
        ',"refreshInterval":5}'
    Write-Utf8 $refresh5.Settings ('{"statusLine":' + $refresh5Old + '}')
    $refresh5Run = Invoke-Installer $Repo $refresh5.Install $refresh5.Settings
    Check 'refreshInterval 5 rewrite exit 0' ($refresh5Run.ExitCode -eq 0)
    Check 'existing refreshInterval 5 rewritten to 2' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($refresh5.Settings)) -ceq
        ('{"statusLine":' + (Get-DesiredValue $refresh5.Install) + '}')
    )

    $preserve = New-Paths 'subagent-preserve'
    [void][IO.Directory]::CreateDirectory($preserve.Claude)
    $preserveCustom = '{"owner":"user","refreshInterval":17}'
    $preserveText = (
        '{"statusLine":' + (Get-DesiredValue $preserve.Install) +
        ',"subagentStatusLine":' + $preserveCustom +
        ',"nested":{"subagentStatusLine":{"keep":"nested"}}}'
    )
    Write-Utf8 $preserve.Settings $preserveText
    $preserveFirst = Invoke-Installer $Repo $preserve.Install $preserve.Settings
    Check 'default preserve installs runtime' ($preserveFirst.ExitCode -eq 0)
    Check 'default preserve keeps exact custom and nested subagent bytes' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($preserve.Settings)) -ceq $preserveText
    )
    Check 'runtime-only preserve creates no settings backup' (
        (Get-BackupCount $preserve.Claude 'settings.json.bak.*') -eq 0
    )
    $preserveSnapshot = Get-ManagedSnapshot $preserve.Install $preserve.Settings
    $preserveBackups = Get-BackupCount $preserve.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $preserveSecond = Invoke-Installer (
        $Repo
    ) $preserve.Install $preserve.Settings 'preserve'
    Check 'explicit preserve idempotent rerun reports no-op' (
        $preserveSecond.ExitCode -eq 0 -and
        $preserveSecond.Stdout -ceq "coralline is already up to date.`r`n"
    )
    Check 'explicit preserve rerun keeps settings and runtime timestamps' (
        Test-SnapshotsEqual $preserveSnapshot (
            Get-ManagedSnapshot $preserve.Install $preserve.Settings
        )
    )
    Check 'explicit preserve rerun creates no backup' (
        (Get-BackupCount $preserve.Claude 'settings.json.bak.*') -eq $preserveBackups
    )

    $variant = New-Paths 'subagent-case-variant'
    [void][IO.Directory]::CreateDirectory($variant.Claude)
    $variantText = (
        '{"statusLine":' + (Get-DesiredValue $variant.Install) +
        ',"SubagentStatus\u004cine":{"variant":"keep"},' +
        '"nested":{"subagentStatusLine":{"keep":"nested"}}}'
    )
    Write-Utf8 $variant.Settings $variantText
    $variantPreserve = Invoke-Installer (
        $Repo
    ) $variant.Install $variant.Settings 'preserve'
    Check 'single decoded case variant preserve exit 0' ($variantPreserve.ExitCode -eq 0)
    Check 'single decoded case variant preserve keeps exact bytes' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($variant.Settings)) -ceq $variantText
    )
    $variantOff = Invoke-Installer $Repo $variant.Install $variant.Settings 'off'
    Check 'off ignores case variant and nested exact target' (
        $variantOff.ExitCode -eq 0 -and
        $variantOff.Stdout -ceq "coralline is already up to date.`r`n" -and
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($variant.Settings)) -ceq $variantText
    )
    $variantSnapshot = Get-ManagedSnapshot $variant.Install $variant.Settings
    $variantBackups = Get-BackupCount $variant.Claude 'settings.json.bak.*'
    $variantOn = Invoke-Installer $Repo $variant.Install $variant.Settings 'on'
    Check 'on rejects a case variant instead of creating an ambiguous pair' (
        $variantOn.ExitCode -ne 0 -and
        $variantOn.Stderr.Contains('case-variant subagentStatusLine')
    )
    Check 'case-variant on rejection mutates no settings or runtime' (
        Test-SnapshotsEqual $variantSnapshot (
            Get-ManagedSnapshot $variant.Install $variant.Settings
        )
    )
    Check 'case-variant on rejection creates no backup' (
        (Get-BackupCount $variant.Claude 'settings.json.bak.*') -eq $variantBackups
    )

    $upperMode = New-Paths 'subagent-uppercase-mode'
    $upperModeRun = Invoke-Installer (
        $Repo
    ) $upperMode.Install $upperMode.Settings 'ON'
    Check 'SubagentRows values are exact lowercase' (
        $upperModeRun.ExitCode -ne 0 -and
        $upperModeRun.Stderr.Contains('SubagentRows')
    )
    Check 'invalid SubagentRows mode mutates nothing' (
        -not [IO.Directory]::Exists($upperMode.Install) -and
        -not [IO.File]::Exists($upperMode.Settings) -and
        (Get-BackupCount $upperMode.Claude '*.bak.*') -eq 0
    )

    $onMissing = New-Paths 'subagent-on-missing-settings'
    $onMissingRun = Invoke-Installer (
        $Repo
    ) $onMissing.Install $onMissing.Settings 'on'
    $onMissingText = $StrictUtf8.GetString([IO.File]::ReadAllBytes($onMissing.Settings))
    $onMissingExpected = (
        '{"statusLine":' + (Get-DesiredValue $onMissing.Install) +
        ',"subagentStatusLine":' + (Get-DesiredSubagentValue $onMissing.Install) + '}'
    )
    Check 'subagent on missing settings exit 0' ($onMissingRun.ExitCode -eq 0)
    Check 'subagent on missing settings creates both managed members once' (
        $onMissingText -ceq $onMissingExpected
    )
    $onMissingObject = $onMissingText | ConvertFrom-Json
    $onMissingProperties = @(
        $onMissingObject.PSObject.Properties |
            Where-Object { $_.Name -ceq 'subagentStatusLine' }
    )
    $onMissingSubagent = $null
    if ($onMissingProperties.Count -eq 1) {
        $onMissingSubagent = $onMissingProperties[0].Value
    }
    $onMissingNames = @()
    $onMissingCommand = ''
    $onMissingType = ''
    if ($null -ne $onMissingSubagent) {
        $onMissingNames = @($onMissingSubagent.PSObject.Properties.Name | Sort-Object)
        $onMissingCommand = [string]$onMissingSubagent.command
        $onMissingType = [string]$onMissingSubagent.type
    }
    $expectedPowerShell = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
    $expectedRenderer = [IO.Path]::GetFullPath((Join-Path $onMissing.Install 'statusline.ps1'))
    Check 'subagent command object has exactly type and command' (
        ($onMissingNames -join ',') -ceq 'command,type' -and
        $onMissingType -ceq 'command'
    )
    Check 'subagent command has no refreshInterval or extra properties' (
        $onMissingNames.Count -eq 2 -and
        -not ($onMissingNames -contains 'refreshInterval')
    )
    Check 'subagent command is exact native absolute command' (
        $onMissingCommand -ceq (Get-DesiredSubagentCommand $onMissing.Install) -and
        $onMissingCommand.StartsWith(
            '"' + $expectedPowerShell + '" ',
            [StringComparison]::Ordinal
        ) -and
        $onMissingCommand.Contains('-File "' + $expectedRenderer + '"')
    )
    Check 'subagent command appends literal --subagent' (
        $onMissingCommand.EndsWith(' --subagent', [StringComparison]::Ordinal)
    )
    Check 'new settings with explicit on has no displaced-file backup' (
        (Get-BackupCount $onMissing.Claude 'settings.json.bak.*') -eq 0
    )
    $onMissingSnapshot = Get-ManagedSnapshot $onMissing.Install $onMissing.Settings
    $onMissingBackups = Get-BackupCount $onMissing.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $onMissingSecond = Invoke-Installer (
        $Repo
    ) $onMissing.Install $onMissing.Settings 'on'
    Check 'subagent on idempotent rerun reports no-op' (
        $onMissingSecond.ExitCode -eq 0 -and
        $onMissingSecond.Stdout -ceq "coralline is already up to date.`r`n"
    )
    Check 'subagent on idempotent rerun preserves timestamps' (
        Test-SnapshotsEqual $onMissingSnapshot (
            Get-ManagedSnapshot $onMissing.Install $onMissing.Settings
        )
    )
    Check 'subagent on idempotent rerun creates no backup' (
        (Get-BackupCount $onMissing.Claude 'settings.json.bak.*') -eq $onMissingBackups
    )

    $combined = New-Paths 'subagent-combined-plan'
    [void][IO.Directory]::CreateDirectory($combined.Claude)
    $combinedBefore = (
        '{' + "`r`n" +
        '  "statusLine": {"old":"main"},' + "`r`n" +
        '  "subagentStatusLine": {"old":"sub","refreshInterval":88},' + "`r`n" +
        '  "nested": {"subagentStatusLine":{"keep":true}}' + "`r`n" +
        '}' + "`r`n"
    )
    Write-Utf8 $combined.Settings $combinedBefore
    $combinedBeforeBytes = [IO.File]::ReadAllBytes($combined.Settings)
    $combinedRun = Invoke-Installer $Repo $combined.Install $combined.Settings 'on'
    $combinedExpected = (
        '{' + "`r`n" +
        '  "statusLine": ' + (Get-DesiredValue $combined.Install) + ',' + "`r`n" +
        '  "subagentStatusLine": ' + (Get-DesiredSubagentValue $combined.Install) + ',' + "`r`n" +
        '  "nested": {"subagentStatusLine":{"keep":true}}' + "`r`n" +
        '}' + "`r`n"
    )
    $combinedBackups = @(
        [IO.Directory]::GetFiles($combined.Claude, 'settings.json.bak.*')
    )
    Check 'combined main and subagent update exit 0' ($combinedRun.ExitCode -eq 0)
    Check 'combined main and subagent values use one lossless plan' (
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($combined.Settings)) -ceq
        $combinedExpected
    )
    Check 'combined settings change creates exactly one backup' ($combinedBackups.Count -eq 1)
    Check 'combined settings backup contains both original values' (
        $combinedBackups.Count -eq 1 -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($combinedBackups[0])) -ceq
        [Convert]::ToBase64String($combinedBeforeBytes)
    )

    $offCases = @(
        [pscustomobject]@{
            Name = 'sole'
            Before = "{`r`n  `"subagentStatusLine`" : {`"old`":1}`t`r`n}`n"
            Expected = "{`r`n  `t`r`n`"statusLine`":__STATUS__}`n"
        },
        [pscustomobject]@{
            Name = 'first'
            Before = (
                '{"subagentStatusLine":1 ' + "`t" + ',' + "`r`n" +
                '  "keep":true,"statusLine":__STATUS__}'
            )
            Expected = "{`r`n  `"keep`":true,`"statusLine`":__STATUS__}"
        },
        [pscustomobject]@{
            Name = 'middle'
            Before = (
                '{"keep":1, ' + "`r`n" +
                '"subagentStatus\u004cine":2,' + "`t" + '"statusLine":__STATUS__}'
            )
            Expected = (
                '{"keep":1, ' + "`r`n" + "`t" + '"statusLine":__STATUS__}'
            )
        },
        [pscustomobject]@{
            Name = 'last'
            Before = (
                '{"keep":1,"statusLine":__STATUS__ ' + "`t" + ',' + "`r`n" +
                ' "subagentStatusLine":2 ' + "`r`n" + '}'
            )
            Expected = (
                '{"keep":1,"statusLine":__STATUS__ ' + "`t" + ' ' + "`r`n" + '}'
            )
        }
    )
    foreach ($offCase in $offCases) {
        $off = New-Paths ('subagent-off-' + $offCase.Name)
        [void][IO.Directory]::CreateDirectory($off.Claude)
        $caseDesired = Get-DesiredValue $off.Install
        $caseBefore = ([string]$offCase.Before).Replace('__STATUS__', $caseDesired)
        $caseExpected = ([string]$offCase.Expected).Replace('__STATUS__', $caseDesired)
        Write-Utf8 $off.Settings $caseBefore
        $caseRun = Invoke-Installer $Repo $off.Install $off.Settings 'off'
        $caseActual = $StrictUtf8.GetString([IO.File]::ReadAllBytes($off.Settings))
        $caseValid = $false
        $caseExactAbsent = $false
        try {
            $caseObject = $caseActual | ConvertFrom-Json
            $caseValid = $null -ne $caseObject
            $caseExactAbsent = @(
                $caseObject.PSObject.Properties |
                    Where-Object { $_.Name -ceq 'subagentStatusLine' }
            ).Count -eq 0
        } catch {}
        Check ('subagent off ' + $offCase.Name + ' exit 0') ($caseRun.ExitCode -eq 0)
        Check ('subagent off ' + $offCase.Name + ' preserves lossless separators') (
            $caseActual -ceq $caseExpected
        )
        Check ('subagent off ' + $offCase.Name + ' leaves valid JSON') (
            $caseValid -and $caseExactAbsent
        )
        if ($offCase.Name -ceq 'last') {
            $offSnapshot = Get-ManagedSnapshot $off.Install $off.Settings
            $offBackups = Get-BackupCount $off.Claude 'settings.json.bak.*'
            Start-Sleep -Milliseconds 1200
            $offSecond = Invoke-Installer $Repo $off.Install $off.Settings 'off'
            Check 'subagent off idempotent rerun reports no-op' (
                $offSecond.ExitCode -eq 0 -and
                $offSecond.Stdout -ceq "coralline is already up to date.`r`n"
            )
            Check 'subagent off idempotent rerun preserves timestamps' (
                Test-SnapshotsEqual $offSnapshot (
                    Get-ManagedSnapshot $off.Install $off.Settings
                )
            )
            Check 'subagent off idempotent rerun creates no backup' (
                (Get-BackupCount $off.Claude 'settings.json.bak.*') -eq $offBackups
            )
        }
    }

    $expandedLimit = New-Paths 'expanded-settings-limit'
    $limitPrefix = '{"padding":"'
    $limitSuffix = '"}'
    $paddingLength = 8MB - $Utf8NoBom.GetByteCount($limitPrefix + $limitSuffix)
    $limitBuilder = New-Object System.Text.StringBuilder
    [void]$limitBuilder.Append($limitPrefix)
    [void]$limitBuilder.Append(([char]'x'), [int]$paddingLength)
    [void]$limitBuilder.Append($limitSuffix)
    Write-Utf8 $expandedLimit.Settings $limitBuilder.ToString()
    [void]$limitBuilder.Clear()
    $expandedLimitHash = Get-FileSha256 $expandedLimit.Settings
    $expandedLimitRun = Invoke-Installer (
        $Repo
    ) $expandedLimit.Install $expandedLimit.Settings 'on'
    Check 'post-merge combined settings size limit rejected' ($expandedLimitRun.ExitCode -ne 0)
    Check 'post-merge size rejection preserves settings bytes' (
        (Get-FileSha256 $expandedLimit.Settings) -ceq $expandedLimitHash
    )
    Check 'post-merge size rejection happens before runtime mutation' (
        -not [IO.Directory]::Exists($expandedLimit.Install)
    )
    Check 'post-merge size rejection creates no backup' (
        (Get-BackupCount $expandedLimit.Claude 'settings.json.bak.*') -eq 0
    )

    $bom = New-Paths 'bom-settings'
    $bomCustomSubagent = '{"custom":"保持","refreshInterval":17}'
    Write-Utf8Bom $bom.Settings (
        '{"keep":"雪","statusLine":null,"subagentStatusLine":' + $bomCustomSubagent + '}'
    )
    $bomRun = Invoke-Installer $Repo $bom.Install $bom.Settings
    $bomBytes = [IO.File]::ReadAllBytes($bom.Settings)
    Check 'UTF-8 BOM settings install exit 0' ($bomRun.ExitCode -eq 0)
    Check 'UTF-8 BOM preserved during merge' (
        $bomBytes.Length -ge 3 -and
        $bomBytes[0] -eq 0xef -and $bomBytes[1] -eq 0xbb -and $bomBytes[2] -eq 0xbf
    )
    Check 'UTF-8 BOM merge preserves unrelated content' (
        $StrictUtf8.GetString($bomBytes, 3, $bomBytes.Length - 3) -ceq
        (
            '{"keep":"雪","statusLine":' + (Get-DesiredValue $bom.Install) +
            ',"subagentStatusLine":' + $bomCustomSubagent + '}'
        )
    )
    $bomItem = Get-Item -LiteralPath $bom.Settings
    $bomSnapshot = (Get-FileSha256 $bom.Settings) + ':' + $bomItem.LastWriteTimeUtc.Ticks
    $bomBackups = Get-BackupCount $bom.Claude 'settings.json.bak.*'
    Start-Sleep -Milliseconds 1200
    $bomSecond = Invoke-Installer $Repo $bom.Install $bom.Settings
    $bomItemAfter = Get-Item -LiteralPath $bom.Settings
    Check 'UTF-8 BOM identical rerun reports no-op' (
        $bomSecond.ExitCode -eq 0 -and
        $bomSecond.Stdout -ceq "coralline is already up to date.`r`n"
    )
    Check 'UTF-8 BOM identical rerun changes no bytes or timestamp' (
        ((Get-FileSha256 $bom.Settings) + ':' + $bomItemAfter.LastWriteTimeUtc.Ticks) -ceq $bomSnapshot
    )
    Check 'UTF-8 BOM identical rerun creates no backup' (
        (Get-BackupCount $bom.Claude 'settings.json.bak.*') -eq $bomBackups
    )

    $bomOn = Invoke-Installer $Repo $bom.Install $bom.Settings 'on'
    $bomOnBytes = [IO.File]::ReadAllBytes($bom.Settings)
    Check 'UTF-8 BOM subagent on exit 0' ($bomOn.ExitCode -eq 0)
    Check 'UTF-8 BOM retained for subagent on' (
        $bomOnBytes[0] -eq 0xef -and $bomOnBytes[1] -eq 0xbb -and $bomOnBytes[2] -eq 0xbf
    )
    Check 'UTF-8 BOM subagent on replaces only exact target value' (
        $StrictUtf8.GetString($bomOnBytes, 3, $bomOnBytes.Length - 3) -ceq
        (
            '{"keep":"雪","statusLine":' + (Get-DesiredValue $bom.Install) +
            ',"subagentStatusLine":' + (Get-DesiredSubagentValue $bom.Install) + '}'
        )
    )
    $bomOff = Invoke-Installer $Repo $bom.Install $bom.Settings 'off'
    $bomOffBytes = [IO.File]::ReadAllBytes($bom.Settings)
    Check 'UTF-8 BOM subagent off exit 0' ($bomOff.ExitCode -eq 0)
    Check 'UTF-8 BOM retained for subagent off' (
        $bomOffBytes[0] -eq 0xef -and $bomOffBytes[1] -eq 0xbb -and $bomOffBytes[2] -eq 0xbf
    )
    Check 'UTF-8 BOM subagent off removes only exact target member' (
        $StrictUtf8.GetString($bomOffBytes, 3, $bomOffBytes.Length - 3) -ceq
        ('{"keep":"雪","statusLine":' + (Get-DesiredValue $bom.Install) + '}')
    )

    Test-InvalidSettings 'malformed' '{"x":'
    Test-InvalidSettings 'null-root' 'null'
    Test-InvalidSettings 'array-root' '[1,2,3]'
    Test-InvalidSettings 'duplicate-exact' '{"statusLine":1,"status\u004cine":2}'
    Test-InvalidSettings (
        'subagent-duplicate-exact'
    ) '{"subagentStatusLine":1,"subagentStatus\u004cine":2}'
    Test-InvalidSettings (
        'subagent-case-collision'
    ) '{"SubagentStatusLine":1,"subagentStatus\u004cine":2}'
    Test-InvalidSettings (
        'subagent-case-variant-on'
    ) '{"SubagentStatus\u004cine":{"keep":true}}' 'on'

    . ([scriptblock]::Create((Get-InstallerTransactionFunctions)))
    $script:MaxSettingsBytes = 8MB
    $script:MaxRuntimeBytes = 2MB
    $script:MaxThemeBytes = 256KB
    $driveRelativeRejected = $false
    try {
        [void](Resolve-CanonicalLocalPath 'C:settings.json' 'drive-relative test path')
    } catch {
        $driveRelativeRejected = $_.Exception.Message.Contains('local drive')
    }
    Check 'drive-relative local path rejected before canonicalization' $driveRelativeRejected
    $driveRelativeSlashRejected = $false
    try {
        [void](Resolve-CanonicalLocalPath 'C:folder/settings.json' 'drive-relative slash test path')
    } catch {
        $driveRelativeSlashRejected = $_.Exception.Message.Contains('local drive')
    }
    Check 'drive-relative slash path rejected before canonicalization' $driveRelativeSlashRejected
    $compareRoot = Join-Path $TempRoot 'comparison-stream-cleanup'
    [void][IO.Directory]::CreateDirectory($compareRoot)
    $compareFirst = Join-Path $compareRoot 'first.txt'
    $compareSecond = Join-Path $compareRoot 'second.txt'
    Write-Utf8 $compareFirst 'same-length'
    Write-Utf8 $compareSecond 'same-length'
    $compareTargetLock = [IO.File]::Open(
        $compareSecond,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    $compareOpenFailed = $false
    $compareFirstReleased = $false
    try {
        try {
            [void](Test-FilesEqual $compareFirst $compareSecond)
        } catch {
            $compareOpenFailed = $true
        }
        try {
            [IO.File]::Delete($compareFirst)
            $compareFirstReleased = -not [IO.File]::Exists($compareFirst)
        } catch {}
    } finally {
        $compareTargetLock.Dispose()
    }
    Check 'comparison target open failure surfaced' $compareOpenFailed
    Check 'first comparison stream released after second open failure' $compareFirstReleased
    $lockedPaths = New-Paths 'concurrent-installer-lock'
    $heldMutex = New-Object System.Threading.Mutex(
        $false,
        'Global\coralline-installer'
    )
    $heldMutexAcquired = $false
    try {
        $heldMutexAcquired = $heldMutex.WaitOne(0)
        if (-not $heldMutexAcquired) { throw 'test could not acquire installer mutex' }
        $lockedRun = Invoke-Installer $Repo $lockedPaths.Install $lockedPaths.Settings
    } finally {
        if ($heldMutexAcquired) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }
    Check 'concurrent installer transaction rejected' (
        $lockedRun.ExitCode -ne 0 -and
        $lockedRun.Stderr.Contains('another coralline installer is already targeting')
    )
    Check 'concurrent installer rejection mutates no targets' (
        -not [IO.Directory]::Exists($lockedPaths.Install) -and
        -not [IO.File]::Exists($lockedPaths.Settings) -and
        (Get-BackupCount $lockedPaths.Claude '*.bak.*') -eq 0
    )

    $concurrentRoot = Join-Path $TempRoot 'concurrent-settings'
    [void][IO.Directory]::CreateDirectory($concurrentRoot)
    $concurrentSettings = Join-Path $concurrentRoot 'settings.json'
    $plannedBytes = $Utf8NoBom.GetBytes('{"value":"planned"}')
    $concurrentBytes = $Utf8NoBom.GetBytes('{"value":"concurrent"}')
    [IO.File]::WriteAllBytes($concurrentSettings, $concurrentBytes)
    $concurrentPlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $plannedBytes
        UpdatedBytes = $Utf8NoBom.GetBytes(
            '{"statusLine":"installer","subagentStatusLine":"installer"}'
        )
        Changed = $true
    }
    $concurrentBackup = Join-Path $concurrentRoot 'settings.json.bak'
    $concurrentTemporary = Join-Path $concurrentRoot '.settings.json.tmp'
    $concurrentRestore = Join-Path $concurrentRoot '.settings.json.restore'
    $concurrentRejected = $false
    try {
        [void](Commit-Settings (
            $concurrentSettings
        ) $concurrentPlan $concurrentBackup $concurrentTemporary $concurrentRestore)
    } catch {
        $concurrentRejected = $_.Exception.Message.Contains('before target mutation')
    }
    Check 'pre-commit concurrent combined settings change rejected' $concurrentRejected
    Check 'pre-commit concurrent settings bytes preserved' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($concurrentSettings)) -ceq
        [Convert]::ToBase64String($concurrentBytes)
    )
    Check 'pre-commit concurrent failure leaves no artifacts' (
        -not [IO.File]::Exists($concurrentBackup) -and
        -not [IO.File]::Exists($concurrentTemporary) -and
        -not [IO.File]::Exists($concurrentRestore)
    )

    $newRollbackRoot = Join-Path $TempRoot 'new-settings-rollback'
    [void][IO.Directory]::CreateDirectory($newRollbackRoot)
    $newRollbackSettings = Join-Path $newRollbackRoot 'settings.json'
    $newRollbackRecovery = Join-Path $newRollbackRoot '.settings.json.recovery'
    $newRollbackRestore = Join-Path $newRollbackRoot '.settings.json.restore'
    $newRollbackInstaller = $Utf8NoBom.GetBytes('{"value":"installer"}')
    $newRollbackConcurrent = $Utf8NoBom.GetBytes('{"value":"concurrent"}')
    [IO.File]::WriteAllBytes($newRollbackSettings, $newRollbackConcurrent)
    $newRollbackPlan = [pscustomobject]@{
        Existed = $false
        OriginalBytes = [byte[]]@()
        UpdatedBytes = $newRollbackInstaller
        Changed = $true
    }
    $newRollbackReported = $false
    try {
        Restore-SettingsOriginal (
            $newRollbackSettings
        ) $newRollbackPlan $newRollbackRestore $newRollbackRecovery
    } catch {
        $newRollbackReported = (
            $_.Exception.Message.Contains('recovery copy retained at') -and
            $_.Exception.Message.Contains($newRollbackRecovery)
        )
    }
    Check 'new settings rollback reports displaced concurrent recovery' $newRollbackReported
    Check 'new settings rollback never deletes concurrent bytes' (
        -not [IO.File]::Exists($newRollbackSettings) -and
        [IO.File]::Exists($newRollbackRecovery) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($newRollbackRecovery)) -ceq
        [Convert]::ToBase64String($newRollbackConcurrent)
    )

    $existingRecoveryRoot = Join-Path $TempRoot 'existing-settings-recovery'
    [void][IO.Directory]::CreateDirectory($existingRecoveryRoot)
    $existingRecoverySettings = Join-Path $existingRecoveryRoot 'settings.json'
    $existingRecoveryRestore = Join-Path $existingRecoveryRoot '.settings.json.restore'
    $existingRecoveryFailed = Join-Path $existingRecoveryRoot '.settings.json.failed'
    $existingRecoveryOriginal = $Utf8NoBom.GetBytes('{"value":"original"}')
    $existingRecoveryUpdated = $Utf8NoBom.GetBytes('{"value":"installer"}')
    $existingRecoveryExternal = $Utf8NoBom.GetBytes('{"value":"external"}')
    $existingRecoveryPlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $existingRecoveryOriginal
        UpdatedBytes = $existingRecoveryUpdated
        Changed = $true
    }
    [IO.File]::WriteAllBytes($existingRecoverySettings, $existingRecoveryUpdated)
    [IO.File]::WriteAllBytes($existingRecoveryRestore, $existingRecoveryExternal)
    $unexpectedRestoreReported = $false
    try {
        Restore-SettingsOriginal (
            $existingRecoverySettings
        ) $existingRecoveryPlan $existingRecoveryRestore $existingRecoveryFailed
    } catch {
        $unexpectedRestoreReported = $_.Exception.Message.Contains(
            $existingRecoveryRestore
        )
    }
    Check 'unexpected rollback source reports exact retained path' $unexpectedRestoreReported
    Check 'unexpected rollback source bytes remain untouched' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($existingRecoverySettings)) -ceq
        [Convert]::ToBase64String($existingRecoveryUpdated) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($existingRecoveryRestore)) -ceq
        [Convert]::ToBase64String($existingRecoveryExternal)
    )

    $failedRecoveryRoot = Join-Path $TempRoot 'failed-settings-recovery'
    [void][IO.Directory]::CreateDirectory($failedRecoveryRoot)
    $failedRecoverySettings = Join-Path $failedRecoveryRoot 'settings.json'
    $failedRecoveryRestore = Join-Path $failedRecoveryRoot '.settings.json.restore'
    $failedRecoveryPath = Join-Path $failedRecoveryRoot '.settings.json.failed'
    [IO.File]::WriteAllBytes($failedRecoverySettings, $existingRecoveryUpdated)
    [IO.File]::WriteAllBytes($failedRecoveryRestore, $existingRecoveryOriginal)
    [IO.File]::WriteAllBytes($failedRecoveryPath, $existingRecoveryExternal)
    $unexpectedFailedReported = $false
    try {
        Restore-SettingsOriginal (
            $failedRecoverySettings
        ) $existingRecoveryPlan $failedRecoveryRestore $failedRecoveryPath
    } catch {
        $unexpectedFailedReported = $_.Exception.Message.Contains($failedRecoveryPath)
    }
    Check 'unexpected rollback destination reports exact retained path' $unexpectedFailedReported
    Check 'unexpected rollback destination bytes remain untouched' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedRecoverySettings)) -ceq
        [Convert]::ToBase64String($existingRecoveryUpdated) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($failedRecoveryPath)) -ceq
        [Convert]::ToBase64String($existingRecoveryExternal)
    )

    $openHandleRoot = Join-Path $TempRoot 'open-handle-settings'
    [void][IO.Directory]::CreateDirectory($openHandleRoot)
    $openHandleSettings = Join-Path $openHandleRoot 'settings.json'
    $openHandleBackup = Join-Path $openHandleRoot 'settings.json.bak'
    $openHandleTemporary = Join-Path $openHandleRoot '.settings.json.tmp'
    $openHandleRestore = Join-Path $openHandleRoot '.settings.json.restore'
    $openHandleOriginal = $Utf8NoBom.GetBytes('{"value":"original"}')
    $openHandleUpdated = $Utf8NoBom.GetBytes(
        '{"statusLine":"installer","subagentStatusLine":"installer"}'
    )
    $openHandleExternal = $Utf8NoBom.GetBytes('{"value":"external-after-commit"}')
    [IO.File]::WriteAllBytes($openHandleSettings, $openHandleOriginal)
    $openHandlePlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $openHandleOriginal
        UpdatedBytes = $openHandleUpdated
        Changed = $true
    }
    $sharedHandle = [IO.File]::Open(
        $openHandleSettings,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    )
    try {
        $openHandleBackupMade = Commit-Settings (
            $openHandleSettings
        ) $openHandlePlan $openHandleBackup $openHandleTemporary $openHandleRestore
        $sharedHandle.Position = 0
        $sharedHandle.SetLength(0)
        $sharedHandle.Write($openHandleExternal, 0, $openHandleExternal.Length)
        $sharedHandle.Flush($true)
    } finally {
        $sharedHandle.Dispose()
    }
    Check 'open settings handle commit retains displaced file as backup' (
        $openHandleBackupMade -and
        [IO.File]::Exists($openHandleBackup)
    )
    Check 'open settings handle post-commit edit survives in retained backup' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($openHandleBackup)) -ceq
        [Convert]::ToBase64String($openHandleExternal)
    )
    Check 'open settings handle leaves combined committed settings intact' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($openHandleSettings)) -ceq
        [Convert]::ToBase64String($openHandleUpdated)
    )
    Check 'open settings handle creates no rollback artifact' (
        -not [IO.File]::Exists($openHandleTemporary) -and
        -not [IO.File]::Exists($openHandleRestore)
    )

    $script:ManagedFiles = @('themes\mono.conf')
    $runtimeConflictRoot = Join-Path $TempRoot 'runtime-rollback-conflict'
    $runtimeConflictInstall = Join-Path $runtimeConflictRoot 'install'
    $runtimeConflictBackup = Join-Path $runtimeConflictRoot 'backup'
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeConflictInstall 'themes'))
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeConflictBackup 'themes'))
    $runtimeConflictTarget = Join-Path $runtimeConflictInstall 'themes\mono.conf'
    $runtimeConflictOriginal = $Utf8NoBom.GetBytes('original runtime bytes')
    $runtimeConflictInstalled = $Utf8NoBom.GetBytes('installer runtime bytes')
    $runtimeConflictExternal = $Utf8NoBom.GetBytes('external runtime bytes')
    [IO.File]::WriteAllBytes($runtimeConflictTarget, $runtimeConflictExternal)
    $runtimeConflictBackupFile = Join-Path $runtimeConflictBackup 'themes\mono.conf'
    [IO.File]::WriteAllBytes($runtimeConflictBackupFile, $runtimeConflictOriginal)
    $runtimeExpected = @{ 'themes\mono.conf' = $runtimeConflictInstalled }
    $runtimeConflictRejected = $false
    try {
        Restore-ManagedRuntime (
            $runtimeConflictInstall
        ) $runtimeConflictBackup @('themes\mono.conf') $true $runtimeExpected
    } catch {
        $runtimeConflictRejected = $_.Exception.Message.Contains($runtimeConflictTarget)
    }
    Check 'runtime rollback rejects concurrent managed-file edit' $runtimeConflictRejected
    Check 'runtime rollback preserves concurrent target bytes' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeConflictTarget)) -ceq
        [Convert]::ToBase64String($runtimeConflictExternal)
    )
    Check 'runtime rollback retains original backup after conflict' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeConflictBackupFile)) -ceq
        [Convert]::ToBase64String($runtimeConflictOriginal)
    )

    $script:ManagedFiles = @('statusline.ps1', 'themes\mono.conf')
    $runtimeBatchRoot = Join-Path $TempRoot 'runtime-rollback-batch-preflight'
    $runtimeBatchInstall = Join-Path $runtimeBatchRoot 'install'
    $runtimeBatchBackup = Join-Path $runtimeBatchRoot 'backup'
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeBatchInstall 'themes'))
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeBatchBackup 'themes'))
    $runtimeBatchMissingTarget = Join-Path $runtimeBatchInstall 'statusline.ps1'
    $runtimeBatchMissingBackup = Join-Path $runtimeBatchBackup 'statusline.ps1'
    $runtimeBatchSentinel = "$runtimeBatchMissingBackup.rollback"
    $runtimeBatchTheme = Join-Path $runtimeBatchInstall 'themes\mono.conf'
    $runtimeBatchThemeBackup = Join-Path $runtimeBatchBackup 'themes\mono.conf'
    $runtimeBatchSentinelBytes = $Utf8NoBom.GetBytes('external recovery sentinel')
    [IO.File]::WriteAllBytes($runtimeBatchSentinel, $runtimeBatchSentinelBytes)
    [IO.File]::WriteAllBytes($runtimeBatchTheme, $runtimeConflictInstalled)
    [IO.File]::WriteAllBytes($runtimeBatchThemeBackup, $runtimeConflictOriginal)
    $runtimeBatchExpected = @{
        'statusline.ps1' = $runtimeConflictInstalled
        'themes\mono.conf' = $runtimeConflictInstalled
    }
    $runtimeBatchRejected = $false
    try {
        Restore-ManagedRuntime (
            $runtimeBatchInstall
        ) $runtimeBatchBackup @('statusline.ps1', 'themes\mono.conf') $true $runtimeBatchExpected
    } catch {
        $runtimeBatchRejected = $_.Exception.Message.Contains($runtimeBatchSentinel)
    }
    Check 'runtime rollback preflights every recovery path before mutation' $runtimeBatchRejected
    Check 'runtime rollback recovery collision preserves later target and backup' (
        -not [IO.File]::Exists($runtimeBatchMissingTarget) -and
        -not [IO.File]::Exists($runtimeBatchMissingBackup) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchSentinel)) -ceq
        [Convert]::ToBase64String($runtimeBatchSentinelBytes) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchTheme)) -ceq
        [Convert]::ToBase64String($runtimeConflictInstalled) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchThemeBackup)) -ceq
        [Convert]::ToBase64String($runtimeConflictOriginal)
    )
    [IO.File]::Delete($runtimeBatchSentinel)
    [IO.File]::WriteAllBytes($runtimeBatchMissingTarget, $runtimeConflictInstalled)
    [IO.File]::WriteAllBytes($runtimeBatchMissingBackup, $runtimeConflictOriginal)
    $runtimeBatchManual = $false
    try {
        Restore-ManagedRuntime (
            $runtimeBatchInstall
        ) $runtimeBatchBackup @('statusline.ps1', 'themes\mono.conf') $true $runtimeBatchExpected
    } catch {
        $runtimeBatchManual = $_.Exception.Message.Contains('multi-file runtime rollback')
    }
    Check 'multi-file runtime rollback fails closed before mutation' $runtimeBatchManual
    Check 'multi-file runtime rollback leaves every target and backup unchanged' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchMissingTarget)) -ceq
        [Convert]::ToBase64String($runtimeConflictInstalled) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchMissingBackup)) -ceq
        [Convert]::ToBase64String($runtimeConflictOriginal) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchTheme)) -ceq
        [Convert]::ToBase64String($runtimeConflictInstalled) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeBatchThemeBackup)) -ceq
        [Convert]::ToBase64String($runtimeConflictOriginal)
    )

    $script:ManagedFiles = @('themes\mono.conf')
    $runtimeRestoreRoot = Join-Path $TempRoot 'runtime-rollback-owned'
    $runtimeRestoreInstall = Join-Path $runtimeRestoreRoot 'install'
    $runtimeRestoreBackup = Join-Path $runtimeRestoreRoot 'backup'
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeRestoreInstall 'themes'))
    [void][IO.Directory]::CreateDirectory((Join-Path $runtimeRestoreBackup 'themes'))
    $runtimeRestoreTarget = Join-Path $runtimeRestoreInstall 'themes\mono.conf'
    $runtimeRestoreBackupFile = Join-Path $runtimeRestoreBackup 'themes\mono.conf'
    $runtimeRestoreRecovery = "$runtimeRestoreBackupFile.rollback"
    [IO.File]::WriteAllBytes($runtimeRestoreTarget, $runtimeConflictInstalled)
    [IO.File]::WriteAllBytes($runtimeRestoreBackupFile, $runtimeConflictOriginal)
    Restore-ManagedRuntime (
        $runtimeRestoreInstall
    ) $runtimeRestoreBackup @('themes\mono.conf') $true $runtimeExpected
    Check 'runtime rollback restores original bytes' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeRestoreTarget)) -ceq
        [Convert]::ToBase64String($runtimeConflictOriginal)
    )
    Check 'runtime rollback retains displaced installer bytes' (
        [IO.File]::Exists($runtimeRestoreRecovery) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeRestoreRecovery)) -ceq
        [Convert]::ToBase64String($runtimeConflictInstalled)
    )

    $newRuntimeRoot = Join-Path $TempRoot 'new-runtime-rollback-owned'
    $newRuntimeInstall = Join-Path $newRuntimeRoot 'install'
    $newRuntimeBackup = Join-Path $newRuntimeRoot 'backup'
    [void][IO.Directory]::CreateDirectory((Join-Path $newRuntimeInstall 'themes'))
    $newRuntimeTarget = Join-Path $newRuntimeInstall 'themes\mono.conf'
    $newRuntimeRecovery = Join-Path $newRuntimeBackup 'themes\mono.conf.rollback'
    [IO.File]::WriteAllBytes($newRuntimeTarget, $runtimeConflictInstalled)
    Restore-ManagedRuntime (
        $newRuntimeInstall
    ) $newRuntimeBackup @('themes\mono.conf') $true $runtimeExpected
    Check 'new runtime rollback removes installer-owned target' (
        -not [IO.File]::Exists($newRuntimeTarget)
    )
    Check 'new runtime rollback retains installer bytes in recovery' (
        [IO.File]::Exists($newRuntimeRecovery) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($newRuntimeRecovery)) -ceq
        [Convert]::ToBase64String($runtimeConflictInstalled)
    )

    [IO.File]::WriteAllBytes($runtimeRestoreTarget, $runtimeConflictExternal)
    $runtimeFinalRejected = $false
    try {
        Assert-ManagedPayloadBytes (
            $runtimeRestoreInstall
        ) $runtimeExpected 'installed payload before success'
    } catch {
        $runtimeFinalRejected = $_.Exception.Message.Contains('changed concurrently')
    }
    Check 'final runtime byte validation rejects valid external content' $runtimeFinalRejected
    Check 'final runtime byte validation preserves external content' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($runtimeRestoreTarget)) -ceq
        [Convert]::ToBase64String($runtimeConflictExternal)
    )

    $settingsFinalPath = Join-Path $TempRoot 'settings-final-validation.json'
    $settingsFinalExpected = $Utf8NoBom.GetBytes(
        '{"statusLine":"installer","subagentStatusLine":"installer"}'
    )
    $settingsFinalExternal = $Utf8NoBom.GetBytes('{"value":"external-before-success"}')
    [IO.File]::WriteAllBytes($settingsFinalPath, $settingsFinalExternal)
    $settingsFinalRejected = $false
    try {
        Assert-SettingsBytes (
            $settingsFinalPath
        ) $settingsFinalExpected 'settings before success'
    } catch {
        $settingsFinalRejected = $_.Exception.Message.Contains('changed concurrently')
    }
    Check 'final combined settings byte validation rejects valid external content' $settingsFinalRejected
    Check 'final combined settings byte validation preserves external content' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($settingsFinalPath)) -ceq
        [Convert]::ToBase64String($settingsFinalExternal)
    )

    $commitRaceRoot = Join-Path $TempRoot 'commit-point-settings'
    [void][IO.Directory]::CreateDirectory($commitRaceRoot)
    $commitRaceSettings = Join-Path $commitRaceRoot 'settings.json'
    $commitRaceBackup = Join-Path $commitRaceRoot 'settings.json.bak'
    $commitRaceTemporary = Join-Path $commitRaceRoot '.settings.json.tmp'
    $commitRaceRestore = Join-Path $commitRaceRoot '.settings.json.restore'
    $commitRacePrefix = '{"padding":"'
    $commitRaceSuffix = '"}'
    $commitRacePadding = 8MB - $Utf8NoBom.GetByteCount(
        $commitRacePrefix + $commitRaceSuffix
    )
    $commitRaceBuilder = New-Object System.Text.StringBuilder
    [void]$commitRaceBuilder.Append($commitRacePrefix)
    [void]$commitRaceBuilder.Append(([char]'x'), [int]$commitRacePadding)
    [void]$commitRaceBuilder.Append($commitRaceSuffix)
    $commitRaceOriginal = $Utf8NoBom.GetBytes($commitRaceBuilder.ToString())
    [void]$commitRaceBuilder.Clear()
    $commitRaceUpdated = New-Object byte[] ($commitRaceOriginal.Length)
    [Array]::Copy(
        $commitRaceOriginal,
        0,
        $commitRaceUpdated,
        0,
        $commitRaceOriginal.Length
    )
    $commitRaceUpdated[$commitRacePrefix.Length] = [byte][char]'y'
    [IO.File]::WriteAllBytes($commitRaceSettings, $commitRaceOriginal)
    $commitRaceConcurrent = $Utf8NoBom.GetBytes('{"value":"concurrent-at-commit"}')
    $writerSettings = [Convert]::ToBase64String(
        $Utf8NoBom.GetBytes($commitRaceSettings)
    )
    $writerBackup = [Convert]::ToBase64String(
        $Utf8NoBom.GetBytes($commitRaceBackup)
    )
    $writerBytes = [Convert]::ToBase64String($commitRaceConcurrent)
    $writerCode = (
        '$ErrorActionPreference="Stop";' +
        '$u=New-Object System.Text.UTF8Encoding($false);' +
        '$s=$u.GetString([Convert]::FromBase64String("' + $writerSettings + '"));' +
        '$k=$u.GetString([Convert]::FromBase64String("' + $writerBackup + '"));' +
        '$b=[Convert]::FromBase64String("' + $writerBytes + '");' +
        '$d=[DateTime]::UtcNow.AddSeconds(15);' +
        'while([DateTime]::UtcNow -lt $d){' +
        'if([IO.File]::Exists($k)){try{[IO.File]::WriteAllBytes($s,$b);exit 0}' +
        'catch [IO.IOException]{}}};exit 2'
    )
    $unicode = New-Object System.Text.UnicodeEncoding($false, $false)
    $writerEncoded = [Convert]::ToBase64String($unicode.GetBytes($writerCode))
    $commitRaceWriter = Start-Process -FilePath $PowerShellExe -ArgumentList @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $writerEncoded
    ) -WindowStyle Hidden -PassThru
    $commitRacePlan = [pscustomobject]@{
        Existed = $true
        OriginalBytes = $commitRaceOriginal
        UpdatedBytes = $commitRaceUpdated
        Changed = $true
    }
    $commitRaceRejected = $false
    $commitRaceSucceeded = $false
    try {
        [void](Commit-Settings (
            $commitRaceSettings
        ) $commitRacePlan $commitRaceBackup $commitRaceTemporary $commitRaceRestore)
        $commitRaceSucceeded = $true
    } catch {
        $commitRaceRejected = (
            $_.Exception.Message.Contains('concurrent change') -or
            $_.Exception.Message.Contains('settings changed')
        )
    }
    $commitRaceWriterFinished = $commitRaceWriter.WaitForExit(15000)
    if (-not $commitRaceWriterFinished) { $commitRaceWriter.Kill() }
    $commitRaceWriterExit = -1
    if ($commitRaceWriterFinished) { $commitRaceWriterExit = $commitRaceWriter.ExitCode }
    $commitRaceWriter.Dispose()
    Check 'commit-point concurrent writer completed' (
        $commitRaceWriterFinished -and $commitRaceWriterExit -eq 0
    )
    Check 'commit-point concurrent settings transaction has a safe outcome' (
        $commitRaceRejected -xor $commitRaceSucceeded
    )
    Check 'commit-point concurrent settings bytes preserved' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($commitRaceSettings)) -ceq
        [Convert]::ToBase64String($commitRaceConcurrent)
    )

    $overlapLeaf = '.installer-overlap-' + [guid]::NewGuid().ToString('N')
    $overlapInstall = Join-Path $Repo $overlapLeaf
    $overlapPaths = New-Paths 'overlap-settings'
    $overlapRun = Invoke-Installer $Repo $overlapInstall $overlapPaths.Settings
    Check 'source and install overlap rejected' ($overlapRun.ExitCode -ne 0)
    Check 'overlap rejection creates nothing in source' (-not [IO.Directory]::Exists($overlapInstall))

    $unsafePaths = New-Paths 'unsafe-settings'
    $unsafeInstall = Join-Path $TempRoot 'unsafe%path\coralline'
    $unsafeRun = Invoke-Installer $Repo $unsafeInstall $unsafePaths.Settings
    Check 'percent install path rejected' ($unsafeRun.ExitCode -ne 0)
    Check 'percent path not created' (-not [IO.Directory]::Exists((Join-Path $TempRoot 'unsafe%path')))

    $fakeWorkspace = Join-Path $TempRoot 'fake workspace'
    [void][IO.Directory]::CreateDirectory($fakeWorkspace)
    $marker = Join-Path $fakeWorkspace 'FAKE-RAN'
    [IO.File]::WriteAllBytes((Join-Path $fakeWorkspace 'powershell.exe'), [byte[]](0x4d, 0x5a, 0, 0))
    Write-Utf8 (Join-Path $fakeWorkspace 'powershell.cmd') ('@echo fake>"' + $marker + '"')
    Write-Utf8 (Join-Path $fakeWorkspace 'statusline.cmd') ('@echo fake>"' + $marker + '"')
    $fakeExeHash = Get-FileSha256 (Join-Path $fakeWorkspace 'powershell.exe')
    $sample = $StrictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $Repo 'test\sample-input.json')))
    $cmdArguments = '/d /s /c "' + $desiredCommand + '"'
    $renderEnvironment = @{
        HOME = $main.Home
        USERPROFILE = $main.Home
        PATH = $fakeWorkspace + ';' + $env:PATH
        CORALLINE_NO_SAMPLE = '1'
    }
    $render = Invoke-CapturedProcess $env:ComSpec $cmdArguments $sample $renderEnvironment $fakeWorkspace 30000
    Check 'registered command cmd.exe E2E exit 0' ($render.ExitCode -eq 0)
    Check 'registered command cmd.exe E2E renders output' (
        $null -ne $render.Stdout -and $render.StdoutBytes.Length -gt 0
    )
    Check 'registered command cmd.exe E2E no stderr' ($render.StderrBytes.Length -eq 0)
    $subagentCmdArguments = '/d /s /c "' + $desiredSubagentCommand + '"'
    $subagentRender = Invoke-CapturedProcess (
        $env:ComSpec
    ) $subagentCmdArguments $sample $renderEnvironment $fakeWorkspace 30000
    Check 'subagent command cmd.exe E2E exit 0' ($subagentRender.ExitCode -eq 0)
    Check 'subagent command cmd.exe E2E no stderr' (
        $subagentRender.StderrBytes.Length -eq 0
    )
    Check 'fake workspace executables never ran' (-not [IO.File]::Exists($marker))
    Check 'fake workspace executable untouched' (
        (Get-FileSha256 (Join-Path $fakeWorkspace 'powershell.exe')) -ceq $fakeExeHash
    )

    $explicitNative = New-Paths 'explicit-native-runtime'
    $explicitNativeRun = Invoke-Installer $Repo $explicitNative.Install $explicitNative.Settings '' 'native'
    Check '-Runtime native writes the c2fa1bc bytes and installs no statusline.sh' (
        $explicitNativeRun.ExitCode -eq 0 -and
        $StrictUtf8.GetString([IO.File]::ReadAllBytes($explicitNative.Settings)) -ceq
        ('{"statusLine":' + (Get-DesiredValue $explicitNative.Install) + '}') -and
        -not [IO.File]::Exists((Join-Path $explicitNative.Install 'statusline.sh'))
    )
    $upperRuntime = New-Paths 'runtime-uppercase'
    $upperRuntimeRun = Invoke-Installer $Repo $upperRuntime.Install $upperRuntime.Settings '' 'Bash'
    Check 'Runtime values are exact lowercase' (
        $upperRuntimeRun.ExitCode -ne 0 -and
        (Get-ErrorText $upperRuntimeRun).Contains('Runtime') -and
        -not [IO.Directory]::Exists($upperRuntime.Install) -and
        -not [IO.File]::Exists($upperRuntime.Settings)
    )
    $dollarNative = New-Paths 'native dollar $x'
    $dollarNativeRun = Invoke-Installer $Repo $dollarNative.Install $dollarNative.Settings
    Check 'native install root with $ refused at the command boundary' (
        $dollarNativeRun.ExitCode -ne 0 -and
        (Get-ErrorText $dollarNativeRun).Contains('Git Bash boundary') -and
        -not [IO.Directory]::Exists($dollarNative.Install) -and
        -not [IO.File]::Exists($dollarNative.Settings)
    )

    $gitBash = Get-ExpectedGitBash
    $gitBashBlockedReason = 'Git for Windows is not installed machine-wide on this host'
    if ($null -ne $gitBash) {
        # The bash and default installs below also need jq; without it -Runtime bash
        # exits non-zero and auto falls back to native, so the host cannot run them.
        $jqProbe = Invoke-CapturedProcess $gitBash '--noprofile --norc -c "command -v jq"' '' @{} $TempRoot 15000
        if ($jqProbe.ExitCode -ne 0) {
            $gitBashBlockedReason = 'Git Bash cannot find jq on this host'
            $gitBash = $null
        }
    }
    if ($null -eq $gitBash) {
        Blocked 'Git Bash runtime' $gitBashBlockedReason
    } else {
        function Get-BashCommand([string]$Install) {
            return '"' + $gitBash + '" "' + [IO.Path]::GetFullPath($Install).Replace('\', '/') + '/statusline.sh"'
        }
        function Get-BashValue([string]$Install) {
            return '{"type":"command","command":' +
                (ConvertTo-TestJsonString (Get-BashCommand $Install)) + ',"refreshInterval":1}'
        }
        function Get-BashSubagentValue([string]$Install) {
            return '{"type":"command","command":' +
                (ConvertTo-TestJsonString ((Get-BashCommand $Install) + ' --subagent')) + '}'
        }
        function Read-SettingsText([string]$Path) {
            return $StrictUtf8.GetString([IO.File]::ReadAllBytes($Path))
        }
        function Invoke-RegisteredCommand([string]$Shell, [string]$Command, [string]$HomeDir) {
            $environment = @{
                HOME = $HomeDir
                USERPROFILE = $HomeDir
                PATH = $fakeWorkspace + ';' + $env:PATH
                CORALLINE_NO_SAMPLE = '1'
                CLAUDE_CONFIG_DIR = $null
                CORALLINE_CONFIG = $null
            }
            if ($Shell -ceq 'cmd') {
                return Invoke-CapturedProcess (
                    $env:ComSpec
                ) ('/d /s /c "' + $Command + '"') $sample $environment $fakeWorkspace 30000
            }
            return Invoke-CapturedProcess (
                $gitBash
            ) ('--noprofile --norc -c ' + (ConvertTo-ProcessArgument $Command)) $sample $environment $fakeWorkspace 30000
        }

        # Decoys first on PATH: none may run when a registered command executes.
        [IO.File]::WriteAllBytes((Join-Path $fakeWorkspace 'bash.exe'), [byte[]](0x4d, 0x5a, 0, 0))
        Write-Utf8 (Join-Path $fakeWorkspace 'bash.cmd') ('@echo fake>"' + $marker + '"')
        Write-Utf8 (Join-Path $fakeWorkspace 'jq.cmd') ('@echo fake>"' + $marker + '"')
        $fakeBashHash = Get-FileSha256 (Join-Path $fakeWorkspace 'bash.exe')

        $bashPaths = New-Paths 'bash-runtime'
        $bashRun = Invoke-Installer $Repo $bashPaths.Install $bashPaths.Settings 'on' 'bash'
        Check 'bash runtime install exit 0' ($bashRun.ExitCode -eq 0)
        Check 'bash runtime install no stderr' ($bashRun.StderrBytes.Length -eq 0)
        if ($bashRun.ExitCode -ne 0) {
            [Console]::Out.WriteLine('DIAG  bash runtime stderr=' + $bashRun.Stderr)
        }
        $bashCommand = Get-BashCommand $bashPaths.Install
        Check 'bash runtime command is the quoted absolute bash.exe and forward-slash script' (
            $bashCommand -ceq (
                '"' + $gitBash + '" "' + $bashPaths.Install.Replace('\', '/') + '/statusline.sh"'
            ) -and $gitBash.EndsWith('\bin\bash.exe', [StringComparison]::OrdinalIgnoreCase)
        )
        Check 'bash runtime writes exact statusLine and subagentStatusLine bytes' (
            (Read-SettingsText $bashPaths.Settings) -ceq (
                '{"statusLine":' + (Get-BashValue $bashPaths.Install) +
                ',"subagentStatusLine":' + (Get-BashSubagentValue $bashPaths.Install) + '}'
            )
        )
        $bashInstalled = @(
            Get-ChildItem -LiteralPath $bashPaths.Install -File -Recurse |
                ForEach-Object { $_.FullName.Substring($bashPaths.Install.Length + 1) } |
                Sort-Object
        )
        Check 'bash runtime installs statusline.sh beside statusline.ps1 and the themes' (
            ((@($ExpectedManaged) + 'statusline.sh' | Sort-Object) -join "`n") -ceq ($bashInstalled -join "`n") -and
            (Get-FileSha256 (Join-Path $bashPaths.Install 'statusline.sh')) -ceq
            (Get-FileSha256 (Join-Path $Repo 'statusline.sh'))
        )
        Check 'bash runtime never creates config' (-not [IO.File]::Exists($bashPaths.Config))
        $bashNote = 'note: the Bash runtime sources coralline.conf as shell code (it executes it), ' +
            "unlike the native parser; rerun with -Runtime native to keep the native runtime`r`n"
        Check 'explicit -Runtime bash prints the config-execution note' (
            (Get-OutputText $bashRun).StartsWith($bashNote, [StringComparison]::Ordinal) -and
            -not (Get-OutputText $bashRun).Contains('runtime: ')
        )
        $bashRerun = Invoke-Installer $Repo $bashPaths.Install $bashPaths.Settings 'on' 'bash'
        Check 'bash runtime identical rerun reports no-op' (
            $bashRerun.ExitCode -eq 0 -and
            $bashRerun.Stdout -ceq ($bashNote + "coralline is already up to date.`r`n")
        )

        foreach ($shell in @('cmd', 'bash')) {
            $shellRender = Invoke-RegisteredCommand $shell $bashCommand $bashPaths.Home
            Check "bash runtime $shell E2E exit 0" ($shellRender.ExitCode -eq 0)
            Check "bash runtime $shell E2E renders the sample model" (
                $null -ne $shellRender.Stdout -and $shellRender.Stdout.Contains('Fable')
            )
            Check "bash runtime $shell E2E no stderr" ($shellRender.StderrBytes.Length -eq 0)
            if ($shellRender.ExitCode -ne 0 -or $shellRender.StderrBytes.Length -ne 0) {
                [Console]::Out.WriteLine("DIAG  $shell exit=$($shellRender.ExitCode) stderr=$($shellRender.Stderr)")
            }
            $shellSubagent = Invoke-RegisteredCommand $shell ($bashCommand + ' --subagent') $bashPaths.Home
            Check "bash runtime $shell subagent E2E exit 0 without stderr" (
                $shellSubagent.ExitCode -eq 0 -and $shellSubagent.StderrBytes.Length -eq 0
            )
        }
        Check 'bash runtime decoy bash.exe, bash.cmd and jq.cmd never ran' (
            -not [IO.File]::Exists($marker) -and
            (Get-FileSha256 (Join-Path $fakeWorkspace 'bash.exe')) -ceq $fakeBashHash
        )

        $special = New-Paths "sp it's; (x)"
        $specialRun = Invoke-Installer $Repo $special.Install $special.Settings '' 'bash'
        Check "bash runtime install root with space ' ; ( installs" ($specialRun.ExitCode -eq 0)
        foreach ($shell in @('cmd', 'bash')) {
            $specialRender = Invoke-RegisteredCommand $shell (Get-BashCommand $special.Install) $special.Home
            Check "bash runtime install root with space ' ; ( renders under $shell" (
                $specialRender.ExitCode -eq 0 -and
                $null -ne $specialRender.Stdout -and $specialRender.Stdout.Contains('Fable') -and
                $specialRender.StderrBytes.Length -eq 0
            )
        }
        Check 'special install root decoys never ran' (-not [IO.File]::Exists($marker))

        foreach ($refusedName in @('bash dollar $x', 'bash tick `x')) {
            $refused = New-Paths $refusedName
            $refusedRun = Invoke-Installer $Repo $refused.Install $refused.Settings '' 'bash'
            Check "bash runtime refuses install root: $refusedName" (
                $refusedRun.ExitCode -ne 0 -and
                (Get-ErrorText $refusedRun).Contains('Git Bash boundary') -and
                -not [IO.Directory]::Exists($refused.Install) -and
                -not [IO.File]::Exists($refused.Settings)
            )
        }

        $switch = New-Paths 'runtime-switch'
        $switchShell = Join-Path $switch.Install 'statusline.sh'
        $switchNativeText = '{"statusLine":' + (Get-DesiredValue $switch.Install) +
            ',"subagentStatusLine":' + (Get-DesiredSubagentValue $switch.Install) + '}'
        $switchBashText = '{"statusLine":' + (Get-BashValue $switch.Install) +
            ',"subagentStatusLine":' + (Get-BashSubagentValue $switch.Install) + '}'
        $switchSteps = @(
            [pscustomobject]@{ Rows = 'on'; Runtime = 'native'; Text = $switchNativeText },
            [pscustomobject]@{ Rows = ''; Runtime = 'default'; Text = $switchBashText },
            [pscustomobject]@{ Rows = ''; Runtime = 'native'; Text = $switchNativeText },
            [pscustomobject]@{ Rows = ''; Runtime = 'bash'; Text = $switchBashText },
            [pscustomobject]@{ Rows = ''; Runtime = 'native'; Text = $switchNativeText },
            [pscustomobject]@{ Rows = 'on'; Runtime = 'bash'; Text = $switchBashText },
            [pscustomobject]@{ Rows = ''; Runtime = 'native'; Text = $switchNativeText }
        )
        $switchShellHash = $null
        foreach ($step in $switchSteps) {
            $stepRun = Invoke-Installer $Repo $switch.Install $switch.Settings $step.Rows $step.Runtime
            Check "runtime switch to $($step.Runtime) leaves both rows on the selected runtime" (
                $stepRun.ExitCode -eq 0 -and (Read-SettingsText $switch.Settings) -ceq $step.Text
            )
            if ($null -ne $switchShellHash) {
                Check "runtime switch to $($step.Runtime) keeps statusline.sh" (
                    [IO.File]::Exists($switchShell) -and (Get-FileSha256 $switchShell) -ceq $switchShellHash
                )
            } elseif ([IO.File]::Exists($switchShell)) {
                $switchShellHash = Get-FileSha256 $switchShell
            }
        }

        # Native never probes for Git Bash, yet still moves this installer's
        # Bash row for this install root even when that bash.exe is gone.
        $noProbeInstaller = New-StubInstaller 'stub-native-no-probe' (
            'function Get-GitBashCandidate { throw ''native must not probe for Git Bash'' }'
        )
        $gone = New-Paths 'native-moves-stale-bash-row'
        [void][IO.Directory]::CreateDirectory($gone.Claude)
        $goneCommand = '"D:\gone\Git\bin\bash.exe" "' +
            [IO.Path]::GetFullPath($gone.Install).Replace('\', '/') + '/statusline.sh" --subagent'
        Write-Utf8 $gone.Settings (
            '{"subagentStatusLine":{"type":"command","command":' + (ConvertTo-TestJsonString $goneCommand) + '}}'
        )
        $goneRun = Invoke-Installer $Repo $gone.Install $gone.Settings '' 'native' $noProbeInstaller
        Check 'native never probes and moves a stale Bash-runtime subagent row' (
            $goneRun.ExitCode -eq 0 -and
            (Read-SettingsText $gone.Settings) -ceq (
                '{"subagentStatusLine":' + (Get-DesiredSubagentValue $gone.Install) +
                ',"statusLine":' + (Get-DesiredValue $gone.Install) + '}'
            )
        )

        $autoBash = New-Paths 'auto-selects-bash'
        $autoBashRun = Invoke-Installer $Repo $autoBash.Install $autoBash.Settings 'on' 'default'
        Check 'default runtime auto selects bash when bash.exe and jq resolve' (
            $autoBashRun.ExitCode -eq 0 -and
            (Read-SettingsText $autoBash.Settings) -ceq (
                '{"statusLine":' + (Get-BashValue $autoBash.Install) +
                ',"subagentStatusLine":' + (Get-BashSubagentValue $autoBash.Install) + '}'
            )
        )
        Check 'auto prints the bash selection and the config-execution note' (
            (Get-OutputText $autoBashRun).Contains('runtime: bash (auto: ') -and
            (Get-OutputText $autoBashRun).Contains('sources coralline.conf as shell code (it executes it)') -and
            (Get-OutputText $autoBashRun).Contains('-Runtime native')
        )

        # Claude Code may rewrite settings.json pretty-printed; the other
        # runtime's row is still recognised after JSON decoding.
        $reformatted = New-Paths 'runtime-switch-reformatted'
        [void][IO.Directory]::CreateDirectory($reformatted.Claude)
        $reformattedNativeSubagent = (
            "{`r`n    `"command`": " +
            (ConvertTo-TestJsonString (Get-DesiredSubagentCommand $reformatted.Install)).Replace(
                '--subagent', '--subagent'
            ) +
            ",`r`n    `"type`": `"command`"`r`n  }"
        )
        Write-Utf8 $reformatted.Settings (
            "{`r`n  `"subagentStatusLine`": " + $reformattedNativeSubagent + "`r`n}`r`n"
        )
        $reformattedRun = Invoke-Installer $Repo $reformatted.Install $reformatted.Settings '' 'bash'
        Check 'reformatted native subagent row is recognised and moved to bash' (
            $reformattedRun.ExitCode -eq 0 -and
            (Read-SettingsText $reformatted.Settings) -ceq (
                "{`r`n  `"subagentStatusLine`": " + (Get-BashSubagentValue $reformatted.Install) +
                "`r`n" + ',"statusLine":' + (Get-BashValue $reformatted.Install) + "}`r`n"
            )
        )

        # A Bash row for this root naming an older Git location follows the
        # resolved bash.exe; a custom row is still preserved.
        $oldGit = New-Paths 'bash-moves-old-git-row'
        [void][IO.Directory]::CreateDirectory($oldGit.Claude)
        $oldGitCommand = '"D:\old\Git\bin\bash.exe" "' +
            [IO.Path]::GetFullPath($oldGit.Install).Replace('\', '/') + '/statusline.sh" --subagent'
        $oldGitCustom = '{"type":"command","command":"my-own-subagent-row"}'
        $oldGitCurrent = '{ "command": ' +
            (ConvertTo-TestJsonString ((Get-BashCommand $oldGit.Install) + ' --subagent')) + ', "type": "command" }'
        foreach ($oldGitCase in @(
            [pscustomobject]@{
                Name = 'old Git location'
                Before = '{"type":"command","command":' + (ConvertTo-TestJsonString $oldGitCommand) + '}'
                After = (Get-BashSubagentValue $oldGit.Install)
            },
            [pscustomobject]@{ Name = 'custom'; Before = $oldGitCustom; After = $oldGitCustom },
            [pscustomobject]@{
                Name = 'reformatted current bash'
                Before = $oldGitCurrent
                After = $oldGitCurrent
            }
        )) {
            Write-Utf8 $oldGit.Settings ('{"subagentStatusLine":' + $oldGitCase.Before + '}')
            $oldGitRun = Invoke-Installer $Repo $oldGit.Install $oldGit.Settings '' 'bash'
            Check "bash preserve with a $($oldGitCase.Name) subagent row ends as expected" (
                $oldGitRun.ExitCode -eq 0 -and
                (Read-SettingsText $oldGit.Settings) -ceq (
                    '{"subagentStatusLine":' + $oldGitCase.After +
                    ',"statusLine":' + (Get-BashValue $oldGit.Install) + '}'
                )
            )
        }

        $custom = New-Paths 'runtime-switch-custom'
        [void][IO.Directory]::CreateDirectory($custom.Claude)
        $customExtra = '{"type":"command","command":' +
            (ConvertTo-TestJsonString (Get-DesiredSubagentCommand $custom.Install)) + ',"padding":1}'
        $customUpper = '{"type":"command","command":' +
            (ConvertTo-TestJsonString (Get-DesiredSubagentCommand $custom.Install).ToUpperInvariant()) + '}'
        foreach ($customValue in @($customExtra, $customUpper)) {
            Write-Utf8 $custom.Settings ('{"subagentStatusLine":' + $customValue + '}')
            $customRun = Invoke-Installer $Repo $custom.Install $custom.Settings '' 'bash'
            Check 'bash preserve keeps a subagent row that is not exactly the native command' (
                $customRun.ExitCode -eq 0 -and
                (Read-SettingsText $custom.Settings) -ceq (
                    '{"subagentStatusLine":' + $customValue +
                    ',"statusLine":' + (Get-BashValue $custom.Install) + '}'
                )
            )
        }

        $noGit = New-Paths 'bash-missing'
        [void][IO.Directory]::CreateDirectory($noGit.Claude)
        Write-Utf8 $noGit.Settings '{"keep":true}'
        $noGitBytes = [IO.File]::ReadAllBytes($noGit.Settings)
        $absentBash = Join-Path $TempRoot 'no-git\bin\bash.exe'
        $stubs = @(
            ('function Get-GitBashCandidate { return ''' + $absentBash + ''' }'),
            'function Get-GitBashCandidate { return $null }'
        )
        for ($i = 0; $i -lt $stubs.Count; $i++) {
            $stubInstaller = New-StubInstaller ('stub-no-git-' + $i) $stubs[$i]
            $noGitRun = Invoke-Installer (
                $Repo
            ) $noGit.Install $noGit.Settings 'on' 'bash' $stubInstaller
            Check "bash missing ($i) fails closed pointing to -Runtime native" (
                $noGitRun.ExitCode -ne 0 -and
                (Get-ErrorText $noGitRun).Contains('bash.exe was not found') -and
                (Get-ErrorText $noGitRun).Contains('-Runtime native')
            )
            Check "bash missing ($i) leaves settings and install root untouched" (
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($noGit.Settings)) -ceq
                [Convert]::ToBase64String($noGitBytes) -and
                -not [IO.Directory]::Exists($noGit.Install) -and
                (Get-BackupCount $noGit.Claude '*.bak.*') -eq 0
            )
            $autoNoGit = New-Paths ('auto-bash-missing-' + $i)
            [void][IO.Directory]::CreateDirectory($autoNoGit.Claude)
            Write-Utf8 $autoNoGit.Settings '{"keep":true}'
            $autoNoGitRun = Invoke-Installer (
                $Repo
            ) $autoNoGit.Install $autoNoGit.Settings '' 'auto' $stubInstaller
            Check "auto with bash missing ($i) falls back to the native bytes" (
                $autoNoGitRun.ExitCode -eq 0 -and
                (Read-SettingsText $autoNoGit.Settings) -ceq
                ('{"keep":true,"statusLine":' + (Get-DesiredValue $autoNoGit.Install) + '}') -and
                -not [IO.File]::Exists((Join-Path $autoNoGit.Install 'statusline.sh'))
            )
            Check "auto with bash missing ($i) prints why it chose native" (
                (Get-OutputText $autoNoGitRun).Contains(
                    'runtime: native (auto: Git for Windows bash.exe was not found at the standard locations'
                )
            )
        }

        # Git's own usr\bin\bash.exe does not prepend /usr/bin, so with a
        # system-only PATH it genuinely cannot find jq.
        $bareBash = Join-Path (Split-Path (Split-Path $gitBash -Parent) -Parent) 'usr\bin\bash.exe'
        if ([IO.File]::Exists($bareBash)) {
            $noJq = New-Paths 'jq-missing'
            [void][IO.Directory]::CreateDirectory($noJq.Claude)
            Write-Utf8 $noJq.Settings '{"keep":true}'
            $noJqBytes = [IO.File]::ReadAllBytes($noJq.Settings)
            $noJqInstaller = New-StubInstaller 'stub-no-jq' (
                'function Get-GitBashCandidate { return ''' + $bareBash + ''' }'
            )
            $noJqRun = Invoke-Installer (
                $Repo
            ) $noJq.Install $noJq.Settings '' 'bash' $noJqInstaller @{
                PATH = "$env:SystemRoot\system32;$env:SystemRoot"
            }
            Check 'jq missing fails closed pointing to -Runtime native' (
                $noJqRun.ExitCode -ne 0 -and
                (Get-ErrorText $noJqRun).Contains('jq was not found') -and
                (Get-ErrorText $noJqRun).Contains('-Runtime native')
            )
            Check 'jq missing leaves settings and install root untouched' (
                [Convert]::ToBase64String([IO.File]::ReadAllBytes($noJq.Settings)) -ceq
                [Convert]::ToBase64String($noJqBytes) -and
                -not [IO.Directory]::Exists($noJq.Install) -and
                (Get-BackupCount $noJq.Claude '*.bak.*') -eq 0
            )
            $autoNoJq = New-Paths 'auto-jq-missing'
            [void][IO.Directory]::CreateDirectory($autoNoJq.Claude)
            Write-Utf8 $autoNoJq.Settings '{"keep":true}'
            $autoNoJqRun = Invoke-Installer (
                $Repo
            ) $autoNoJq.Install $autoNoJq.Settings '' 'auto' $noJqInstaller @{
                PATH = "$env:SystemRoot\system32;$env:SystemRoot"
            }
            Check 'auto with jq missing falls back to the native bytes' (
                $autoNoJqRun.ExitCode -eq 0 -and
                (Read-SettingsText $autoNoJq.Settings) -ceq
                ('{"keep":true,"statusLine":' + (Get-DesiredValue $autoNoJq.Install) + '}') -and
                -not [IO.File]::Exists((Join-Path $autoNoJq.Install 'statusline.sh'))
            )
            Check 'auto with jq missing prints why it chose native' (
                (Get-OutputText $autoNoJqRun).Contains('runtime: native (auto: jq was not found')
            )
        } else {
            Blocked 'jq missing' "Git's usr\bin\bash.exe is absent on this host"
        }

        $crlfSource = Join-Path $TempRoot 'crlf-source'
        Copy-ManagedSource $crlfSource $true
        $crlfShell = Join-Path $crlfSource 'statusline.sh'
        [IO.File]::WriteAllText(
            $crlfShell,
            ([IO.File]::ReadAllText($crlfShell, $StrictUtf8).Replace("`n", "`r`n")),
            $Utf8NoBom
        )
        $crlf = New-Paths 'crlf-shell-runtime'
        $crlfRun = Invoke-Installer $crlfSource $crlf.Install $crlf.Settings '' 'bash'
        Check 'CRLF statusline.sh refused in local mode' (
            $crlfRun.ExitCode -ne 0 -and
            (Get-ErrorText $crlfRun).Contains('carriage return') -and
            -not [IO.Directory]::Exists($crlf.Install) -and
            -not [IO.File]::Exists($crlf.Settings)
        )
    }

    $rollback = New-Paths 'rollback'
    $rollbackFresh = Invoke-Installer $Repo $rollback.Install $rollback.Settings
    Check 'rollback fixture fresh install' ($rollbackFresh.ExitCode -eq 0)
    $rollbackSource = Join-Path $TempRoot 'rollback-source'
    Copy-ManagedSource $rollbackSource
    $changedTheme = Join-Path $rollbackSource 'themes\mono.conf'
    [IO.File]::AppendAllText(
        $changedTheme,
        ("`n" + '# rollback test change' + "`n"),
        $Utf8NoBom
    )
    $runtimeBefore = Get-FileSha256 (Join-Path $rollback.Install 'themes\mono.conf')
    $rollbackSettingsText = (
        '{"keep":"original","statusLine":null,' +
        '"subagentStatusLine":{"custom":"original"}}'
    )
    Write-Utf8 $rollback.Settings $rollbackSettingsText
    $rollbackSettingsBytes = [IO.File]::ReadAllBytes($rollback.Settings)
    $lock = [IO.File]::Open(
        $rollback.Settings,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read
    )
    try {
        $rollbackRun = Invoke-Installer (
            $rollbackSource
        ) $rollback.Install $rollback.Settings 'on'
    } finally {
        $lock.Dispose()
    }
    Check 'locked settings forces install failure' ($rollbackRun.ExitCode -ne 0)
    Check 'failed settings commit prints no success' (-not $rollbackRun.Stdout.Contains('coralline installed at'))
    Check 'settings failure restores previous runtime' (
        (Get-FileSha256 (Join-Path $rollback.Install 'themes\mono.conf')) -ceq $runtimeBefore
    )
    Check 'combined settings failure leaves both managed values byte-identical' (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($rollback.Settings)) -ceq
        [Convert]::ToBase64String($rollbackSettingsBytes)
    )

    $junctionTarget = Join-Path $TempRoot 'junction-target'
    $junctionPath = Join-Path $TempRoot 'junction-entry'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    Write-Utf8 (Join-Path $junctionTarget 'canary.txt') 'keep'
    $junctionCreate = Invoke-CapturedProcess $env:ComSpec (
        '/d /s /c "mklink /J ' + (Quote-ProcessArgument $junctionPath) + ' ' +
        (Quote-ProcessArgument $junctionTarget) + '"'
    ) '' @{} $TempRoot 10000
    if ($junctionCreate.ExitCode -eq 0 -and [IO.Directory]::Exists($junctionPath)) {
        $junctionSettings = (New-Paths 'junction-settings').Settings
        $junctionRun = Invoke-Installer $Repo (Join-Path $junctionPath 'coralline') $junctionSettings
        Check 'reparse component rejected' ($junctionRun.ExitCode -ne 0)
        Check 'reparse canary preserved' (
            [IO.File]::ReadAllText((Join-Path $junctionTarget 'canary.txt'), $StrictUtf8) -ceq 'keep'
        )
        [void](Invoke-CapturedProcess $env:ComSpec (
            '/d /s /c "rmdir ' + (Quote-ProcessArgument $junctionPath) + '"'
        ) '' @{} $TempRoot 10000)
    } else {
        Blocked 'reparse component rejection' 'mklink /J was unavailable in this Windows environment'
    }

    # ---- -Engine omp (experimental Oh-My-Posh engine) -------------------------------
    # Local mode under $TempRoot only. A compiled oh-my-posh.exe test double answers
    # the installer's version probe; renders that need Oh-My-Posh itself use the
    # first oh-my-posh.exe on this host's PATH (31.3.0 or newer), else they are Blocked.
    $ompSavedInputEncoding = $null
    try {
        # .NET Framework writes the console input encoding's preamble into every
        # redirected stdin; a UTF-8 BOM there would reach the renderers' JSON parsers.
        $ompSavedInputEncoding = [Console]::InputEncoding
        if ($ompSavedInputEncoding.GetPreamble().Length -gt 0) { [Console]::InputEncoding = $Utf8NoBom }
    } catch { }
    $OmpBaseManaged = @($ExpectedManaged) + @('statusline-omp.ps1', 'tools\build-omp-config.ps1')
    $OmpGenerated = @('coralline.omp.json', 'coralline.float.omp.json', 'coralline.auto.omp.json')
    $OmpManaged = @($OmpBaseManaged) + @($OmpGenerated)
    $ompStubSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class OmpStub {
    public static int Main(string[] args) {
        string dir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
        string modeFile = Path.Combine(dir, "stub-mode.txt");
        string mode = File.Exists(modeFile) ? File.ReadAllText(modeFile).Trim() : "version:31.3.0";
        File.AppendAllText(Path.Combine(dir, "calls.log"), string.Join(" ", args) + "\n");
        Stream stdout = Console.OpenStandardOutput();
        if (mode.StartsWith("version:")) { Write(stdout, mode.Substring(8) + "\n"); return 0; }
        if (mode == "sleep") { Thread.Sleep(60000); Write(stdout, "31.3.0\n"); return 0; }
        if (mode == "big") { Write(stdout, "31.3.0" + new string('x', 8192) + "\n"); return 0; }
        if (mode == "empty") { return 0; }
        if (mode == "exit1") { Write(stdout, "31.3.0\n"); return 1; }
        if (mode == "stderr") {
            Stream stderr = Console.OpenStandardError();
            byte[] chunk = Encoding.ASCII.GetBytes(new string('e', 65536));
            for (int i = 0; i < 64; i++) stderr.Write(chunk, 0, chunk.Length);
            stderr.Flush();
            Write(stdout, "31.3.0\n");
            return 0;
        }
        if (mode.StartsWith("proxy:")) {
            ProcessStartInfo start = new ProcessStartInfo(mode.Substring(6));
            StringBuilder line = new StringBuilder();
            foreach (string a in args) {
                if (line.Length > 0) line.Append(' ');
                line.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            }
            start.Arguments = line.ToString();
            start.UseShellExecute = false;
            start.RedirectStandardOutput = true;
            // stdin is inherited, never re-encoded.
            Process child = Process.Start(start);
            MemoryStream output = new MemoryStream();
            child.StandardOutput.BaseStream.CopyTo(output);
            child.WaitForExit();
            stdout.Write(output.ToArray(), 0, (int)output.Length);
            stdout.Flush();
            return child.ExitCode;
        }
        return 3;
    }
    static void Write(Stream s, string text) {
        byte[] b = Encoding.ASCII.GetBytes(text);
        s.Write(b, 0, b.Length);
        s.Flush();
    }
}
'@
    $ompStubExe = Join-Path $TempRoot 'omp-stub-build\oh-my-posh.exe'
    $ompStubReady = $false
    try {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ompStubExe))
        Add-Type -TypeDefinition $ompStubSource -OutputAssembly $ompStubExe -OutputType ConsoleApplication
        $ompStubReady = [IO.File]::Exists($ompStubExe)
    } catch {
        [Console]::Out.WriteLine('DIAG  omp stub build failed: ' + $_.Exception.Message)
    }
    $ompElevated = $false
    $ompIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $ompElevated = (New-Object Security.Principal.WindowsPrincipal($ompIdentity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    } finally {
        $ompIdentity.Dispose()
    }

    if (-not $ompStubReady) {
        Blocked 'Engine omp installer cases' 'the oh-my-posh.exe test double could not be compiled with Add-Type'
    } elseif ($ompElevated) {
        Blocked 'Engine omp installer cases' 'this test process runs with an elevated token, which -Engine omp refuses by design (G5)'
    } else {
        function New-OmpStubDirectory([string]$Name, [string]$Mode, [string]$FileName = 'oh-my-posh.exe') {
            $directory = Join-Path $TempRoot ('omp-stub ' + $Name)
            [void][IO.Directory]::CreateDirectory($directory)
            [IO.File]::Copy($ompStubExe, (Join-Path $directory $FileName), $true)
            [IO.File]::WriteAllText((Join-Path $directory 'stub-mode.txt'), $Mode, $Utf8NoBom)
            return $directory
        }
        $ompSystemPath = "$env:SystemRoot\system32;$env:SystemRoot"
        $ompOkDir = New-OmpStubDirectory 'ok' 'version:31.3.0'
        $ompOkPath = $ompOkDir + ';' + $ompSystemPath

        function Invoke-OmpInstaller(
            [string]$Source,
            [string]$Install,
            [string]$Settings,
            [string[]]$Arguments = @('-Engine', 'omp'),
            [string]$PathValue = $ompOkPath,
            [string]$InstallerPath = $Installer,
            [hashtable]$ExtraEnvironment = @{}
        ) {
            $parts = @(
                '-NoLogo',
                '-NoProfile',
                '-NonInteractive',
                '-ExecutionPolicy Bypass',
                '-File ' + (Quote-ProcessArgument $InstallerPath),
                '-SourceDirectory ' + (Quote-ProcessArgument $Source),
                '-InstallRoot ' + (Quote-ProcessArgument $Install),
                '-SettingsPath ' + (Quote-ProcessArgument $Settings)
            )
            foreach ($argument in $Arguments) {
                if ($argument.StartsWith('-', [StringComparison]::Ordinal)) { $parts += $argument }
                else { $parts += (Quote-ProcessArgument $argument) }
            }
            $environment = @{
                CORALLINE_REPO = 'must-not-be-read'
                CORALLINE_REF = 'must-not-be-read'
                CORALLINE_BASE_URL = 'https://127.0.0.1:1/must-not-be-read'
                CORALLINE_CONFIG = $null
                CORALLINE_OMP_EXE = $null
                CORALLINE_OMP_CONFIG = $null
                PATH = $PathValue
            }
            foreach ($key in $ExtraEnvironment.Keys) { $environment[$key] = $ExtraEnvironment[$key] }
            return Invoke-CapturedProcess $PowerShellExe ($parts -join ' ') '' $environment $Repo 180000
        }

        function Get-TreeSnapshot([string]$Root, [bool]$IncludeTimestamps = $true) {
            $snapshot = [ordered]@{}
            if (-not [IO.Directory]::Exists($Root)) { return ,$snapshot }
            foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName)) {
                $relative = $item.FullName.Substring($Root.Length)
                if ($item.PSIsContainer) {
                    $snapshot["dir:$relative"] = 'dir'
                } else {
                    $value = Get-FileSha256 $item.FullName
                    if ($IncludeTimestamps) { $value += ':' + $item.LastWriteTimeUtc.Ticks }
                    $snapshot["file:$relative"] = $value
                }
            }
            return ,$snapshot
        }

        function Get-OmpBackups([string]$Claude) {
            $runtime = @()
            $generated = @()
            if ([IO.Directory]::Exists($Claude)) {
                foreach ($entry in @([IO.Directory]::GetDirectories($Claude, 'coralline.bak.*') | Sort-Object)) {
                    if ($entry.EndsWith('.generated', [StringComparison]::Ordinal)) { $generated += $entry }
                    else { $runtime += $entry }
                }
            }
            return [pscustomobject]@{ Runtime = $runtime; Generated = $generated }
        }

        function Get-OmpLeftovers([string]$Claude) {
            if (-not [IO.Directory]::Exists($Claude)) { return 0 }
            return @([IO.Directory]::GetFileSystemEntries($Claude, '.coralline.*')).Count
        }

        function Get-OmpCommand([string]$Install, [string]$Pinned = '') {
            $exe = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
            $wrapper = [IO.Path]::GetFullPath((Join-Path $Install 'statusline-omp.ps1'))
            $configPath = [IO.Path]::GetFullPath((Join-Path $Install 'coralline.omp.json'))
            $text = '"' + $exe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
                $wrapper + '" -Config "' + $configPath + '"'
            if ($Pinned.Length -gt 0) { $text += ' -OmpExe "' + $Pinned + '"' }
            return $text
        }

        function Get-OmpValue([string]$Install, [string]$Pinned = '') {
            return '{"type":"command","command":' + (ConvertTo-TestJsonString (Get-OmpCommand $Install $Pinned)) +
                ',"refreshInterval":2}'
        }

        function Get-OmpWrapperCommand([string]$Install) {
            $exe = [IO.Path]::GetFullPath((Join-Path $PSHOME 'powershell.exe'))
            $wrapper = [IO.Path]::GetFullPath((Join-Path $Install 'statusline-omp.ps1'))
            return '"' + $exe + '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $wrapper + '"'
        }

        function Copy-OmpSource([string]$Destination) {
            Copy-ManagedSource $Destination
            foreach ($relative in @('statusline-omp.ps1', 'tools\build-omp-config.ps1')) {
                $target = Join-Path $Destination $relative
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
                [IO.File]::Copy((Join-Path $Repo $relative), $target, $true)
            }
        }

        function Invoke-OmpDirectGenerator([string]$Install, [string]$Config, [string]$Output, [string]$HomeDir) {
            if ([IO.Directory]::Exists($Output)) { [IO.Directory]::Delete($Output, $true) }
            [void][IO.Directory]::CreateDirectory($Output)
            $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (Quote-ProcessArgument (Join-Path $Install 'tools\build-omp-config.ps1')) +
                ' -ConfigPath ' + (Quote-ProcessArgument $Config) +
                ' -StatuslinePath ' + (Quote-ProcessArgument (Join-Path $Install 'statusline.ps1')) +
                ' -OutFile ' + (Quote-ProcessArgument (Join-Path $Output 'coralline.omp.json')) +
                ' -FloatOutFile ' + (Quote-ProcessArgument (Join-Path $Output 'coralline.float.omp.json')) +
                ' -AutoOutFile ' + (Quote-ProcessArgument (Join-Path $Output 'coralline.auto.omp.json')) +
                ' -AutoPlaceholder'
            $environment = @{ HOME = $HomeDir; USERPROFILE = $HomeDir }
            foreach ($name in @([Environment]::GetEnvironmentVariables().Keys)) {
                $variable = [string]$name
                if ($variable -like 'CORALLINE_*' -or $variable -like 'REMORA_*') { $environment[$variable] = $null }
            }
            return Invoke-CapturedProcess $PowerShellExe $arguments '' $environment $TempRoot 120000
        }

        function Test-OmpGeneratedEqual([string]$Install, [string]$Output) {
            foreach ($name in $OmpGenerated) {
                $installed = Join-Path $Install $name
                $direct = Join-Path $Output $name
                if (-not [IO.File]::Exists($installed) -or -not [IO.File]::Exists($direct)) { return $false }
                if ((Get-FileSha256 $installed) -cne (Get-FileSha256 $direct)) { return $false }
            }
            return $true
        }

        function Test-OmpNoWrite($Before, [string]$Claude) {
            return (Test-SnapshotsEqual $Before (Get-TreeSnapshot $Claude)) -and (Get-OmpLeftovers $Claude) -eq 0
        }

        function Read-Text([string]$Path) {
            return $StrictUtf8.GetString([IO.File]::ReadAllBytes($Path))
        }

        # -- fresh install, byte equality with a direct generator run, no-op, repair --
        $omp = New-Paths "omp it's & (fresh)"
        [void][IO.Directory]::CreateDirectory($omp.Claude)
        Write-Utf8 $omp.Config ('VL_SEGMENTS="model ctx cost lines"' + "`n")
        Write-Utf8 $omp.Settings '{"keep":1}'
        $ompConfHash = Get-FileSha256 $omp.Config
        $ompFresh = Invoke-OmpInstaller $Repo $omp.Install $omp.Settings
        $ompFreshOut = Get-OutputText $ompFresh
        Check 'omp fresh install exit 0 without stderr' ($ompFresh.ExitCode -eq 0 -and $ompFresh.StderrBytes.Length -eq 0)
        if ($ompFresh.ExitCode -ne 0) { [Console]::Out.WriteLine('DIAG  omp fresh stderr=' + (Get-ErrorText $ompFresh)) }
        Check 'omp fresh install prints runtime: native (engine omp)' (
            $ompFreshOut.StartsWith("runtime: native (engine omp)`r`n", [StringComparison]::Ordinal)
        )
        Check 'omp fresh install reports no inventory or concurrency error' (
            -not $ompFreshOut.Contains('unexpected file inventory') -and
            -not $ompFreshOut.Contains('unexpected directory inventory') -and
            -not $ompFreshOut.Contains('changed concurrently') -and
            -not (Get-ErrorText $ompFresh).Contains('unexpected') -and
            -not (Get-ErrorText $ompFresh).Contains('changed concurrently')
        )
        $ompInstalled = @(
            Get-ChildItem -LiteralPath $omp.Install -File -Recurse |
                ForEach-Object { $_.FullName.Substring($omp.Install.Length + 1) } |
                Sort-Object
        )
        Check 'omp installs exactly the base payload, wrapper, generator and three configs' (
            (($OmpManaged | Sort-Object) -join "`n") -ceq ($ompInstalled -join "`n")
        )
        Check 'omp installs the wrapper and generator bytes from the source' (
            (Get-FileSha256 (Join-Path $omp.Install 'statusline-omp.ps1')) -ceq (Get-FileSha256 (Join-Path $Repo 'statusline-omp.ps1')) -and
            (Get-FileSha256 (Join-Path $omp.Install 'tools\build-omp-config.ps1')) -ceq
            (Get-FileSha256 (Join-Path $Repo 'tools\build-omp-config.ps1'))
        )
        Check 'omp statusLine is the wrapper with -Config, refreshInterval 2, no subagent row' (
            (Read-Text $omp.Settings) -ceq ('{"keep":1,"statusLine":' + (Get-OmpValue $omp.Install) + '}')
        )
        Check 'omp install leaves coralline.conf byte-identical' ((Get-FileSha256 $omp.Config) -ceq $ompConfHash)
        Check 'omp install leaves no staging or generator directory' ((Get-OmpLeftovers $omp.Claude) -eq 0)
        $ompDirectOut = Join-Path $TempRoot 'omp-direct-fresh'
        $ompDirect = Invoke-OmpDirectGenerator $omp.Install $omp.Config $ompDirectOut $omp.Home
        Check 'omp generated configs equal a direct 5.1 run of the installed generator' (
            $ompDirect.ExitCode -eq 0 -and (Test-OmpGeneratedEqual $omp.Install $ompDirectOut)
        )
        $ompNoUpgrade = $true
        foreach ($name in $OmpGenerated) {
            if ((Read-Text (Join-Path $omp.Install $name)) -cmatch '"upgrade"\s*:') { $ompNoUpgrade = $false }
        }
        Check 'omp generated configs carry no upgrade key' $ompNoUpgrade
        Check 'omp auto config is the placeholder when VL_LAYOUT is not auto' (
            (Read-Text (Join-Path $omp.Install 'coralline.auto.omp.json')).Contains('"CorallineAutoDisabled"')
        )

        $ompSnapshot = Get-TreeSnapshot $omp.Claude
        Start-Sleep -Milliseconds 1200
        $ompNoop = Invoke-OmpInstaller $Repo $omp.Install $omp.Settings
        Check 'omp identical rerun reports already up to date and changes nothing' (
            $ompNoop.ExitCode -eq 0 -and
            $ompNoop.Stdout -ceq "runtime: native (engine omp)`r`ncoralline is already up to date.`r`n" -and
            (Test-SnapshotsEqual $ompSnapshot (Get-TreeSnapshot $omp.Claude))
        )

        function Set-OneByteChanged([string]$Path) {
            $bytes = [IO.File]::ReadAllBytes($Path)
            $middle = [int]($bytes.Length / 2)
            $bytes[$middle] = $bytes[$middle] -bxor 1
            [IO.File]::WriteAllBytes($Path, $bytes)
        }
        $ompMono = Join-Path $omp.Install 'themes\mono.conf'
        Set-OneByteChanged $ompMono
        $ompBackupsBefore = Get-OmpBackups $omp.Claude
        $ompBaseRepair = Invoke-OmpInstaller $Repo $omp.Install $omp.Settings
        $ompBackupsAfter = Get-OmpBackups $omp.Claude
        Check 'omp rerun reinstalls one changed base file through transaction 1' (
            $ompBaseRepair.ExitCode -eq 0 -and
            (Get-FileSha256 $ompMono) -ceq (Get-FileSha256 (Join-Path $Repo 'themes\mono.conf')) -and
            @($ompBackupsAfter.Runtime).Count -eq @($ompBackupsBefore.Runtime).Count + 1 -and
            @($ompBackupsAfter.Generated).Count -eq @($ompBackupsBefore.Generated).Count -and
            (Get-OutputText $ompBaseRepair).Contains('runtime backup retained at') -and
            -not (Get-OutputText $ompBaseRepair).Contains('already up to date')
        )

        $ompFloat = Join-Path $omp.Install 'coralline.float.omp.json'
        $ompFloatGood = Get-FileSha256 $ompFloat
        Set-OneByteChanged $ompFloat
        $ompBackupsBefore = Get-OmpBackups $omp.Claude
        $ompGeneratedRepair = Invoke-OmpInstaller $Repo $omp.Install $omp.Settings
        $ompBackupsAfter = Get-OmpBackups $omp.Claude
        Check 'omp rerun restores one changed generated config through transaction 2' (
            $ompGeneratedRepair.ExitCode -eq 0 -and
            (Get-FileSha256 $ompFloat) -ceq $ompFloatGood -and
            @($ompBackupsAfter.Generated).Count -eq @($ompBackupsBefore.Generated).Count + 1 -and
            @($ompBackupsAfter.Runtime).Count -eq @($ompBackupsBefore.Runtime).Count -and
            (Get-OutputText $ompGeneratedRepair).Contains('generated config backup retained at') -and
            -not (Get-OutputText $ompGeneratedRepair).Contains('runtime backup retained at')
        )

        Write-Utf8 $omp.Config ('VL_SEGMENTS="model ctx cost"' + "`n")
        $ompConfHash = Get-FileSha256 $omp.Config
        $ompBackupsBefore = Get-OmpBackups $omp.Claude
        $ompBaseBefore = Get-RelativeFileSnapshot $omp.Install $OmpBaseManaged $true
        $ompConfRun = Invoke-OmpInstaller $Repo $omp.Install $omp.Settings
        $ompBackupsAfter = Get-OmpBackups $omp.Claude
        $ompDirect = Invoke-OmpDirectGenerator $omp.Install $omp.Config $ompDirectOut $omp.Home
        Check 'omp conf-only change runs only transaction 2' (
            $ompConfRun.ExitCode -eq 0 -and
            (Test-SnapshotsEqual $ompBaseBefore (Get-RelativeFileSnapshot $omp.Install $OmpBaseManaged $true)) -and
            @($ompBackupsAfter.Runtime).Count -eq @($ompBackupsBefore.Runtime).Count -and
            @($ompBackupsAfter.Generated).Count -eq @($ompBackupsBefore.Generated).Count + 1 -and
            (Get-OutputText $ompConfRun).Contains('generated config backup retained at')
        )
        Check 'omp conf-only change regenerates the same bytes as a direct run' (
            $ompDirect.ExitCode -eq 0 -and (Test-OmpGeneratedEqual $omp.Install $ompDirectOut)
        )
        Check 'omp conf-only rerun leaves coralline.conf byte-identical' ((Get-FileSha256 $omp.Config) -ceq $ompConfHash)

        # -- generator warnings (a conf the parser rejects) are forwarded, install continues --
        $ompWarn = New-Paths 'omp-conf-warning'
        [void][IO.Directory]::CreateDirectory($ompWarn.Claude)
        Write-Utf8 $ompWarn.Config ('VL_STYLE=$(evil)' + "`n")
        $ompWarnRun = Invoke-OmpInstaller $Repo $ompWarn.Install $ompWarn.Settings
        Check 'omp forwards the generator warning for a rejected conf and still installs' (
            $ompWarnRun.ExitCode -eq 0 -and
            (Get-OutputText $ompWarnRun).Contains('warning: ') -and
            (Get-OutputText $ompWarnRun).Contains('was rejected by the coralline parser') -and
            [IO.File]::Exists((Join-Path $ompWarn.Install 'coralline.omp.json'))
        )

        # -- themes: the generator reads the themes this same run installed ------------
        $ompTheme = New-Paths 'omp-theme-include'
        [void][IO.Directory]::CreateDirectory($ompTheme.Claude)
        Write-Utf8 $ompTheme.Config (
            '. "' + $ompTheme.Install.Replace('\', '/') + '/themes/claude-coral.conf"' + "`n"
        )
        $ompThemeSourceA = Join-Path $TempRoot 'omp-theme-source-a'
        Copy-OmpSource $ompThemeSourceA
        # claude-coral is the default palette, so the shipped file would be
        # indistinguishable from the defaults; a changed copy proves the include.
        $ompCoralA = Join-Path $ompThemeSourceA 'themes\claude-coral.conf'
        [IO.File]::WriteAllText($ompCoralA, ([IO.File]::ReadAllText($ompCoralA, $StrictUtf8).Replace(
            'VL_BG_DIR="81,166,199"', 'VL_BG_DIR="11,22,33"'
        )), $Utf8NoBom)
        $ompThemeRunA = Invoke-OmpInstaller $ompThemeSourceA $ompTheme.Install $ompTheme.Settings
        $ompThemeDirect = Join-Path $TempRoot 'omp-direct-theme'
        $ompThemeDirectRun = Invoke-OmpDirectGenerator $ompTheme.Install $ompTheme.Config $ompThemeDirect $ompTheme.Home
        $ompDefaultConf = Join-Path $TempRoot 'omp-default.conf'
        Write-Utf8 $ompDefaultConf ('# defaults' + "`n")
        $ompDefaultDirect = Join-Path $TempRoot 'omp-direct-default'
        [void](Invoke-OmpDirectGenerator $ompTheme.Install $ompDefaultConf $ompDefaultDirect $ompTheme.Home)
        $ompThemeMainA = Get-FileSha256 (Join-Path $ompTheme.Install 'coralline.omp.json')
        Check 'omp first install generates from the theme it just installed' (
            $ompThemeRunA.ExitCode -eq 0 -and $ompThemeDirectRun.ExitCode -eq 0 -and
            (Test-OmpGeneratedEqual $ompTheme.Install $ompThemeDirect) -and
            $ompThemeMainA -cne (Get-FileSha256 (Join-Path $ompDefaultDirect 'coralline.omp.json'))
        )
        $ompThemeSourceB = Join-Path $TempRoot 'omp-theme-source-b'
        Copy-OmpSource $ompThemeSourceB
        $ompCoralB = Join-Path $ompThemeSourceB 'themes\claude-coral.conf'
        [IO.File]::WriteAllText($ompCoralB, ([IO.File]::ReadAllText($ompCoralB, $StrictUtf8).Replace(
            'VL_BG_DIR="81,166,199"', 'VL_BG_DIR="44,55,66"'
        )), $Utf8NoBom)
        $ompThemeRunB = Invoke-OmpInstaller $ompThemeSourceB $ompTheme.Install $ompTheme.Settings
        $ompThemeDirectRun = Invoke-OmpDirectGenerator $ompTheme.Install $ompTheme.Config $ompThemeDirect $ompTheme.Home
        Check 'omp upgrade over an older installed theme generates from the new theme' (
            $ompThemeRunB.ExitCode -eq 0 -and $ompThemeDirectRun.ExitCode -eq 0 -and
            (Get-FileSha256 (Join-Path $ompTheme.Install 'themes\claude-coral.conf')) -ceq (Get-FileSha256 $ompCoralB) -and
            (Test-OmpGeneratedEqual $ompTheme.Install $ompThemeDirect) -and
            (Get-FileSha256 (Join-Path $ompTheme.Install 'coralline.omp.json')) -cne $ompThemeMainA
        )

        # -- refusals before anything is written --------------------------------------
        $ompRefusalCases = @(
            [pscustomobject]@{ Name = 'omp with -Runtime bash'; Args = @('-Engine', 'omp', '-Runtime', 'bash'); PathValue = $ompOkPath; Installer = $Installer; Needle = 'needs the native runtime' },
            [pscustomobject]@{ Name = '-OmpPath without -Engine omp'; Args = @('-Runtime', 'native', '-OmpPath', (Join-Path $ompOkDir 'oh-my-posh.exe')); PathValue = $ompOkPath; Installer = $Installer; Needle = '-OmpPath needs -Engine omp' },
            [pscustomobject]@{ Name = 'omp without oh-my-posh on PATH'; Args = @('-Engine', 'omp'); PathValue = $ompSystemPath; Installer = $Installer; Needle = 'was not found on PATH' },
            [pscustomobject]@{ Name = 'omp with oh-my-posh 31.2.9'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'old' 'version:31.2.9') + ';' + $ompSystemPath); Installer = $Installer; Needle = 'is older than' },
            [pscustomobject]@{ Name = 'omp with a version probe that times out'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'sleep' 'sleep') + ';' + $ompSystemPath); Installer = (New-StubInstaller 'stub-omp-version-timeout' '$script:OmpVersionTimeoutMs = 2000'); Needle = 'did not answer' },
            [pscustomobject]@{ Name = 'omp with a version answer over 4 KB'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'big' 'big') + ';' + $ompSystemPath); Installer = $Installer; Needle = 'printed more than' },
            [pscustomobject]@{ Name = 'omp with an empty version answer'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'empty' 'empty') + ';' + $ompSystemPath); Installer = $Installer; Needle = 'printed no version number' },
            [pscustomobject]@{ Name = 'omp with too many version digits'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'digits' 'version:1234567.0.0') + ';' + $ompSystemPath); Installer = $Installer; Needle = 'printed no version number' },
            [pscustomobject]@{ Name = 'omp with a failing version probe'; Args = @('-Engine', 'omp'); PathValue = ((New-OmpStubDirectory 'exit1' 'exit1') + ';' + $ompSystemPath); Installer = $Installer; Needle = 'exited with 1' },
            [pscustomobject]@{ Name = 'omp with an elevated token'; Args = @('-Engine', 'omp'); PathValue = $ompOkPath; Installer = (New-StubInstaller 'stub-omp-elevated' 'function Test-InstallerElevated { return $true }'); Needle = 'refuses an elevated' },
            [pscustomobject]@{ Name = 'omp with a relative -OmpPath'; Args = @('-Engine', 'omp', '-OmpPath', 'oh-my-posh.exe'); PathValue = $ompOkPath; Installer = $Installer; Needle = 'must be absolute' },
            [pscustomobject]@{ Name = 'omp with -OmpPath not named oh-my-posh.exe'; Args = @('-Engine', 'omp', '-OmpPath', (Join-Path (New-OmpStubDirectory 'renamed' 'version:31.3.0' 'omp.exe') 'omp.exe')); PathValue = $ompOkPath; Installer = $Installer; Needle = 'must name oh-my-posh.exe' },
            [pscustomobject]@{ Name = 'omp with -OmpPath that does not exist'; Args = @('-Engine', 'omp', '-OmpPath', (Join-Path $TempRoot 'no-such\oh-my-posh.exe')); PathValue = $ompOkPath; Installer = $Installer; Needle = 'does not exist' },
            [pscustomobject]@{ Name = 'omp with Engine OMP (wrong case)'; Args = @('-Engine', 'OMP'); PathValue = $ompOkPath; Installer = $Installer; Needle = 'Engine' }
        )
        $ompCmdOnlyDir = Join-Path $TempRoot 'omp-stub cmd-only'
        [void][IO.Directory]::CreateDirectory($ompCmdOnlyDir)
        Write-Utf8 (Join-Path $ompCmdOnlyDir 'oh-my-posh.cmd') ('@echo 31.3.0' + "`r`n")
        $ompRefusalCases += [pscustomobject]@{ Name = 'omp with only oh-my-posh.cmd on PATH'; Args = @('-Engine', 'omp'); PathValue = ($ompCmdOnlyDir + ';' + $ompSystemPath); Installer = $Installer; Needle = 'not an .exe' }
        $ompJunctionTarget = Join-Path $TempRoot 'omp-junction-target'
        $ompJunction = Join-Path $TempRoot 'omp-junction'
        [void][IO.Directory]::CreateDirectory($ompJunctionTarget)
        [IO.File]::Copy($ompStubExe, (Join-Path $ompJunctionTarget 'oh-my-posh.exe'), $true)
        $ompJunctionCreate = Invoke-CapturedProcess $env:ComSpec (
            '/d /s /c "mklink /J ' + (Quote-ProcessArgument $ompJunction) + ' ' + (Quote-ProcessArgument $ompJunctionTarget) + '"'
        ) '' @{} $TempRoot 10000
        $ompJunctionReady = $ompJunctionCreate.ExitCode -eq 0 -and [IO.Directory]::Exists($ompJunction)
        if ($ompJunctionReady) {
            $ompRefusalCases += [pscustomobject]@{ Name = 'omp with -OmpPath through a reparse point'; Args = @('-Engine', 'omp', '-OmpPath', (Join-Path $ompJunction 'oh-my-posh.exe')); PathValue = $ompOkPath; Installer = $Installer; Needle = 'reparse point' }
        } else {
            Blocked 'omp with -OmpPath through a reparse point' 'mklink /J was unavailable in this Windows environment'
        }
        $ompRefusalIndex = 0
        foreach ($case in $ompRefusalCases) {
            $ompRefusalIndex++
            $refused = New-Paths ('omp-refusal-' + $ompRefusalIndex)
            [void][IO.Directory]::CreateDirectory($refused.Claude)
            Write-Utf8 $refused.Settings '{"keep":true}'
            Write-Utf8 $refused.Config ('VL_STYLE="lean"' + "`n")
            $refusedBefore = Get-TreeSnapshot $refused.Claude
            $refusedRun = Invoke-OmpInstaller $Repo $refused.Install $refused.Settings $case.Args $case.PathValue $case.Installer
            Check "$($case.Name) is refused" (
                -not $refusedRun.TimedOut -and $refusedRun.ExitCode -ne 0 -and
                (Get-ErrorText $refusedRun).Contains($case.Needle)
            )
            if (-not (Get-ErrorText $refusedRun).Contains($case.Needle)) {
                [Console]::Out.WriteLine('DIAG  ' + $case.Name + ' stderr=' + (Get-ErrorText $refusedRun))
            }
            Check "$($case.Name) writes nothing" (
                (Test-OmpNoWrite $refusedBefore $refused.Claude) -and -not [IO.Directory]::Exists($refused.Install)
            )
        }
        if ($ompJunctionReady) {
            [void](Invoke-CapturedProcess $env:ComSpec ('/d /s /c "rmdir ' + (Quote-ProcessArgument $ompJunction) + '"') '' @{} $TempRoot 10000)
        }
        Blocked 'omp refusal under a real elevated token' 'this test host token is not elevated; the refusal branch is covered by the Test-InstallerElevated stub above'

        $ompStderrFlood = New-Paths 'omp-version-stderr-flood'
        $ompStderrFloodRun = Invoke-OmpInstaller $Repo $ompStderrFlood.Install $ompStderrFlood.Settings @('-Engine', 'omp') (
            (New-OmpStubDirectory 'stderr' 'stderr') + ';' + $ompSystemPath
        )
        Check 'omp version probe drains 4 MB of stderr and still accepts 31.3.0' ($ompStderrFloodRun.ExitCode -eq 0)

        # -- settings rejected by the parser: exit 1 and not one byte written (H3) --------
        $ompBadSettings = New-Paths 'omp-malformed-settings'
        [void][IO.Directory]::CreateDirectory($ompBadSettings.Claude)
        Write-Utf8 $ompBadSettings.Settings '{"x":'
        Write-Utf8 $ompBadSettings.Config ('VL_STYLE="lean"' + "`n")
        $ompBadBefore = Get-TreeSnapshot $ompBadSettings.Claude
        $ompBadRun = Invoke-OmpInstaller $Repo $ompBadSettings.Install $ompBadSettings.Settings
        Check 'omp first install with malformed settings exits 1 and writes nothing' (
            $ompBadRun.ExitCode -eq 1 -and
            (Test-OmpNoWrite $ompBadBefore $ompBadSettings.Claude) -and
            -not [IO.Directory]::Exists($ompBadSettings.Install) -and
            @((Get-OmpBackups $ompBadSettings.Claude).Runtime).Count -eq 0 -and
            @((Get-OmpBackups $ompBadSettings.Claude).Generated).Count -eq 0
        )

        # -- -OmpPath pins an absolute oh-my-posh.exe ------------------------------------
        $ompPinned = New-Paths 'omp-pinned'
        $ompPinnedExe = Join-Path (New-OmpStubDirectory 'pinned' 'version:31.3.0') 'oh-my-posh.exe'
        $ompPinnedRun = Invoke-OmpInstaller $Repo $ompPinned.Install $ompPinned.Settings @(
            '-Engine', 'omp', '-OmpPath', $ompPinnedExe
        ) $ompSystemPath
        Check 'omp -OmpPath appends -OmpExe with the exact path (probe did not need PATH)' (
            $ompPinnedRun.ExitCode -eq 0 -and
            (Read-Text $ompPinned.Settings) -ceq ('{"statusLine":' + (Get-OmpValue $ompPinned.Install $ompPinnedExe) + '}')
        )

        # -- G7: install-time inputs versus render-time inputs ----------------------------
        $ompNotes = New-Paths 'omp-env-notes'
        $ompNotesRun = Invoke-OmpInstaller $Repo $ompNotes.Install $ompNotes.Settings @('-Engine', 'omp') $ompOkPath $Installer @{
            CORALLINE_CONFIG = (Join-Path $TempRoot 'elsewhere.conf')
            CORALLINE_OMP_EXE = (Join-Path $TempRoot 'elsewhere\oh-my-posh.exe')
            CORALLINE_OMP_CONFIG = (Join-Path $TempRoot 'elsewhere.omp.json')
        }
        Check 'omp prints notes for CORALLINE_CONFIG, CORALLINE_OMP_EXE and CORALLINE_OMP_CONFIG' (
            $ompNotesRun.ExitCode -eq 0 -and
            (Get-OutputText $ompNotesRun).Contains('note: CORALLINE_CONFIG is set') -and
            (Get-OutputText $ompNotesRun).Contains('note: CORALLINE_OMP_EXE is set') -and
            (Get-OutputText $ompNotesRun).Contains('note: CORALLINE_OMP_CONFIG is set')
        )

        # -- generator failures after transaction 1 (stub generators, Local mode) ----------
        $ompStubGeneratorHead = (
            'param([string]$ConfigPath, [string]$StatuslinePath, [string]$OutFile, [string]$FloatOutFile, ' +
            '[string]$AutoOutFile, [switch]$AutoPlaceholder)' + "`n" +
            '$u = New-Object System.Text.UTF8Encoding($false)' + "`n" +
            '$valid = "{`n  `"var`": {`n    `"CorallineGenerator`": `"coralline-omp/1`"`n  }`n}`n"' + "`n" +
            'function Write-All([string]$Main) { [IO.File]::WriteAllText($OutFile, $Main, $u); ' +
            '[IO.File]::WriteAllText($FloatOutFile, $valid, $u); [IO.File]::WriteAllText($AutoOutFile, $valid, $u) }' + "`n"
        )
        $ompGeneratorModes = @(
            [pscustomobject]@{ Name = 'exit 1'; Body = '[Console]::Error.WriteLine("stub generator failure"); exit 1'; Needle = 'exited with 1'; Installer = $Installer },
            [pscustomobject]@{ Name = 'timeout'; Body = 'Start-Sleep -Seconds 30'; Needle = 'did not finish within'; Installer = (New-StubInstaller 'stub-omp-generator-timeout' '$script:OmpGeneratorTimeoutMs = 3000') },
            [pscustomobject]@{ Name = 'non-ASCII output'; Body = 'Write-All ($valid + "caf" + [char]0xE9 + "`n")'; Needle = 'is not ASCII'; Installer = $Installer },
            [pscustomobject]@{ Name = 'missing marker'; Body = 'Write-All ("{}" + "`n")'; Needle = 'lacks the coralline-omp generator marker'; Installer = $Installer },
            [pscustomobject]@{ Name = 'upgrade key'; Body = 'Write-All ($valid.Replace("{`n  `"var`"", "{`n  `"upgrade`": {},`n  `"var`""))'; Needle = 'contains an upgrade key'; Installer = $Installer },
            [pscustomobject]@{ Name = 'extra file'; Body = 'Write-All $valid; [IO.File]::WriteAllText([IO.Path]::Combine([IO.Path]::GetDirectoryName($OutFile), "extra.json"), $valid, $u)'; Needle = 'unexpected file inventory'; Installer = $Installer },
            [pscustomobject]@{ Name = 'oversized output'; Body = 'Write-All ($valid + (New-Object string ([char]32, 1048577)))'; Needle = 'exceeds the'; Installer = $Installer },
            [pscustomobject]@{ Name = 'stdout flood'; Body = 'Write-All $valid; [Console]::Out.Write((New-Object string ([char]120, 70000)))'; Needle = 'printed more than'; Installer = $Installer },
            [pscustomobject]@{ Name = 'reparse point'; Body = ('Write-All $valid; $d = [IO.Path]::GetDirectoryName($OutFile); ' +
                '$t = [IO.Path]::Combine([IO.Path]::GetDirectoryName($d), "omp-junction-target"); [void][IO.Directory]::CreateDirectory($t); ' +
                'New-Item -ItemType Junction -Path ([IO.Path]::Combine($d, "junction")) -Target $t | Out-Null'); Needle = 'reparse point'; Installer = $Installer },
            [pscustomobject]@{ Name = 'tampered installed runtime'; Body = 'Write-All $valid; [IO.File]::AppendAllText($StatuslinePath, "`n# tampered`n")'; Needle = 'changed concurrently'; Installer = $Installer }
        )
        $ompGen = New-Paths 'omp-generator-failures'
        [void][IO.Directory]::CreateDirectory($ompGen.Claude)
        Write-Utf8 $ompGen.Config ('VL_STYLE="lean"' + "`n")
        $ompGenGood = Invoke-OmpInstaller $Repo $ompGen.Install $ompGen.Settings
        Check 'omp generator-failure fixture installs' ($ompGenGood.ExitCode -eq 0)
        $ompGenSource = Join-Path $TempRoot 'omp-generator-stub-source'
        Copy-OmpSource $ompGenSource
        $ompGenStub = Join-Path $ompGenSource 'tools\build-omp-config.ps1'
        foreach ($mode in $ompGeneratorModes) {
            if ($mode.Name -ceq 'tampered installed runtime') {
                # Put the fixture back to the shipped runtime first.
                [void](Invoke-OmpInstaller $Repo $ompGen.Install $ompGen.Settings)
            }
            Write-Utf8 $ompGenStub ($ompStubGeneratorHead + $mode.Body + "`n")
            $genBefore = Get-TreeSnapshot $ompGen.Install
            $genSettingsBefore = Get-FileSha256 $ompGen.Settings
            $genRun = Invoke-OmpInstaller $ompGenSource $ompGen.Install $ompGen.Settings @('-Engine', 'omp') $ompOkPath $mode.Installer
            $genError = Get-ErrorText $genRun
            Check "omp generator $($mode.Name) fails the install" (
                -not $genRun.TimedOut -and $genRun.ExitCode -ne 0 -and $genError.Contains($mode.Needle)
            )
            if (-not $genError.Contains($mode.Needle)) { [Console]::Out.WriteLine("DIAG  generator $($mode.Name) stderr=$genError") }
            $genAfter = Get-TreeSnapshot $ompGen.Install
            if ($mode.Name -ceq 'tampered installed runtime') {
                $genAfter.Remove('file:\statusline.ps1')
                $genBefore.Remove('file:\statusline.ps1')
            }
            Check "omp generator $($mode.Name) rolls transaction 1 back byte for byte" (
                $genError.Contains('previous managed runtime restored') -and
                (Test-SnapshotsEqual $genBefore $genAfter) -and
                (Get-FileSha256 $ompGen.Settings) -ceq $genSettingsBefore
            )
            if ($mode.Name -ceq 'reparse point') {
                foreach ($leftover in @([IO.Directory]::GetDirectories($ompGen.Claude, '.coralline.generate.*'))) {
                    $leftoverJunction = Join-Path $leftover 'junction'
                    if ([IO.Directory]::Exists($leftoverJunction)) {
                        [void](Invoke-CapturedProcess $env:ComSpec ('/d /s /c "rmdir ' + (Quote-ProcessArgument $leftoverJunction) + '"') '' @{} $TempRoot 10000)
                    }
                    if (-not [IO.Directory]::Exists($leftoverJunction)) { [IO.Directory]::Delete($leftover, $true) }
                }
            }
        }
        Check 'omp generator failures leave no generator directory behind' ((Get-OmpLeftovers $ompGen.Claude) -eq 0)

        $ompGenFirst = New-Paths 'omp-generator-failure-first-install'
        [void][IO.Directory]::CreateDirectory($ompGenFirst.Claude)
        Write-Utf8 $ompGenFirst.Settings '{"keep":true}'
        $ompGenFirstSettings = Get-FileSha256 $ompGenFirst.Settings
        Write-Utf8 $ompGenStub ($ompStubGeneratorHead + '[Console]::Error.WriteLine("stub generator failure"); exit 1' + "`n")
        $ompGenFirstRun = Invoke-OmpInstaller $ompGenSource $ompGenFirst.Install $ompGenFirst.Settings
        Check 'omp generator failure on a first install fails closed and leaves settings untouched' (
            $ompGenFirstRun.ExitCode -ne 0 -and
            (Get-ErrorText $ompGenFirstRun).Contains('multi-file runtime rollback requires manual recovery') -and
            (Get-FileSha256 $ompGenFirst.Settings) -ceq $ompGenFirstSettings
        )

        # -- settings commit failure: reverse rollback of both transactions ---------------
        $ompRb = New-Paths 'omp-settings-rollback'
        [void][IO.Directory]::CreateDirectory($ompRb.Claude)
        Write-Utf8 $ompRb.Config ('VL_LAYOUT="auto"' + "`n" + 'VL_MAX_LINES="3"' + "`n" + 'VL_SEGMENTS="model ctx cost"' + "`n")
        Write-Utf8 $ompRb.Settings '{"keep":1}'
        $ompRbFresh = Invoke-OmpInstaller $Repo $ompRb.Install $ompRb.Settings
        Check 'omp rollback fixture installs a real auto config' (
            $ompRbFresh.ExitCode -eq 0 -and
            (Read-Text (Join-Path $ompRb.Install 'coralline.auto.omp.json')).Contains('"CorallineAutoTokens"')
        )
        function Invoke-OmpLocked([string]$Source) {
            $lock = [IO.File]::Open($ompRb.Settings, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            try { return Invoke-OmpInstaller $Source $ompRb.Install $ompRb.Settings }
            finally { $lock.Dispose() }
        }
        Write-Utf8 $ompRb.Settings '{"keep":1,"statusLine":null}'
        $ompRbSettings = Get-FileSha256 $ompRb.Settings
        Write-Utf8 $ompRb.Config ('VL_LAYOUT="auto"' + "`n" + 'VL_MAX_LINES="1"' + "`n" + 'VL_SEGMENTS="model ctx cost"' + "`n")
        $ompRbBefore = Get-TreeSnapshot $ompRb.Install
        $ompRbRun = Invoke-OmpLocked $Repo
        Check 'omp settings failure with only auto changed restores auto byte for byte' (
            $ompRbRun.ExitCode -ne 0 -and
            (Get-ErrorText $ompRbRun).Contains('previous managed runtime and generated configs restored') -and
            (Test-SnapshotsEqual $ompRbBefore (Get-TreeSnapshot $ompRb.Install)) -and
            (Get-FileSha256 $ompRb.Settings) -ceq $ompRbSettings
        )
        $ompRbSource = Join-Path $TempRoot 'omp-rollback-source'
        Copy-OmpSource $ompRbSource
        [IO.File]::AppendAllText((Join-Path $ompRbSource 'themes\mono.conf'), ("`n# rollback`n"), $Utf8NoBom)
        $ompRbRun = Invoke-OmpLocked $ompRbSource
        Check 'omp settings failure with one base file and auto changed restores both byte for byte' (
            $ompRbRun.ExitCode -ne 0 -and
            (Get-ErrorText $ompRbRun).Contains('previous managed runtime and generated configs restored') -and
            (Test-SnapshotsEqual $ompRbBefore (Get-TreeSnapshot $ompRb.Install)) -and
            (Get-FileSha256 $ompRb.Settings) -ceq $ompRbSettings
        )
        Write-Utf8 $ompRb.Config (
            '. "' + $ompRb.Install.Replace('\', '/') + '/themes/dracula.conf"' + "`n" +
            'VL_LAYOUT="auto"' + "`n" + 'VL_MAX_LINES="3"' + "`n" + 'VL_SEGMENTS="model ctx cost git"' + "`n" +
            'VL_FLOAT_SEGMENTS="model ctx"' + "`n"
        )
        $ompRbOldGenerated = Get-RelativeFileSnapshot $ompRb.Install $OmpGenerated $false
        $ompRbOldMono = Get-FileSha256 (Join-Path $ompRb.Install 'themes\mono.conf')
        $ompRbBackupsBefore = Get-OmpBackups $ompRb.Claude
        $ompRbRun = Invoke-OmpLocked $ompRbSource
        $ompRbBackupsAfter = Get-OmpBackups $ompRb.Claude
        $ompRbNewRuntime = @($ompRbBackupsAfter.Runtime | Where-Object { @($ompRbBackupsBefore.Runtime) -notcontains $_ })
        $ompRbNewGenerated = @($ompRbBackupsAfter.Generated | Where-Object { @($ompRbBackupsBefore.Generated) -notcontains $_ })
        $ompRbDirectRun = Invoke-OmpDirectGenerator $ompRb.Install $ompRb.Config (Join-Path $TempRoot 'omp-direct-rollback') $ompRb.Home
        $ompRbKept = $ompRbNewRuntime.Count -eq 1 -and $ompRbNewGenerated.Count -eq 1
        if ($ompRbKept) {
            foreach ($name in $OmpGenerated) {
                if ((Get-FileSha256 (Join-Path $ompRbNewGenerated[0] $name)) -cne $ompRbOldGenerated[$name]) { $ompRbKept = $false }
            }
            if ((Get-FileSha256 (Join-Path $ompRbNewRuntime[0] 'themes\mono.conf')) -cne $ompRbOldMono) { $ompRbKept = $false }
        }
        $ompRbError = Get-ErrorText $ompRbRun
        Check 'omp settings failure with a multi-file transaction 2 fails closed and names both backups' (
            $ompRbRun.ExitCode -ne 0 -and
            $ompRbError.Contains('multi-file runtime rollback requires manual recovery') -and
            $ompRbNewRuntime.Count -eq 1 -and $ompRbError.Contains([IO.Path]::GetFileName($ompRbNewRuntime[0])) -and
            $ompRbNewGenerated.Count -eq 1 -and $ompRbError.Contains([IO.Path]::GetFileName($ompRbNewGenerated[0]))
        )
        Check 'omp fail-closed rollback leaves transaction 1, every target and both backups untouched' (
            $ompRbKept -and $ompRbDirectRun.ExitCode -eq 0 -and
            (Test-OmpGeneratedEqual $ompRb.Install (Join-Path $TempRoot 'omp-direct-rollback')) -and
            (Get-FileSha256 (Join-Path $ompRb.Install 'themes\mono.conf')) -ceq
            (Get-FileSha256 (Join-Path $ompRbSource 'themes\mono.conf')) -and
            (Get-FileSha256 $ompRb.Settings) -ceq $ompRbSettings
        )

        # -- G11: a generated config held open by a reader ---------------------------------
        $ompLocked = New-Paths 'omp-locked-config'
        [void][IO.Directory]::CreateDirectory($ompLocked.Claude)
        Write-Utf8 $ompLocked.Config ('VL_SEGMENTS="model ctx cost"' + "`n")
        $ompLockedFresh = Invoke-OmpInstaller $Repo $ompLocked.Install $ompLocked.Settings
        Write-Utf8 $ompLocked.Config ('VL_SEGMENTS="model ctx"' + "`n" + 'VL_FLOAT_SEGMENTS="model"' + "`n")
        $ompLockedBefore = Get-TreeSnapshot $ompLocked.Install
        $ompLockedSettings = Get-FileSha256 $ompLocked.Settings
        $ompReader = [IO.File]::Open(
            (Join-Path $ompLocked.Install 'coralline.float.omp.json'),
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        try {
            $ompLockedRun = Invoke-OmpInstaller $Repo $ompLocked.Install $ompLocked.Settings
        } finally {
            $ompReader.Dispose()
        }
        Check 'omp config held open by a reader fails closed and rolls the replaced config back' (
            $ompLockedFresh.ExitCode -eq 0 -and $ompLockedRun.ExitCode -ne 0 -and
            (Get-ErrorText $ompLockedRun).Contains('previous managed runtime restored') -and
            (Test-SnapshotsEqual $ompLockedBefore (Get-TreeSnapshot $ompLocked.Install)) -and
            (Get-FileSha256 $ompLocked.Settings) -ceq $ompLockedSettings
        )

        # -- subagent rows -------------------------------------------------------------------
        $ompSub = New-Paths 'omp-subagent'
        $ompSubOn = Invoke-OmpInstaller $Repo $ompSub.Install $ompSub.Settings @('-Engine', 'omp', '-SubagentRows', 'on')
        Check 'omp -SubagentRows on writes the native subagent row' (
            $ompSubOn.ExitCode -eq 0 -and
            (Read-Text $ompSub.Settings) -ceq (
                '{"statusLine":' + (Get-OmpValue $ompSub.Install) + ',"subagentStatusLine":' +
                (Get-DesiredSubagentValue $ompSub.Install) + '}'
            )
        )
        $ompWrapperRow = Get-OmpWrapperCommand $ompSub.Install
        $ompOtherRoot = Get-OmpWrapperCommand (Join-Path $TempRoot 'other-root\coralline')
        $ompBashRow = '"C:\Program Files\Git\bin\bash.exe" "' + $ompSub.Install.Replace('\', '/') + '/statusline.sh" --subagent'
        $ompSubCases = @(
            [pscustomobject]@{ Name = 'bare wrapper --subagent row'; Row = ($ompWrapperRow + ' --subagent'); Moves = $true },
            [pscustomobject]@{ Name = 'wrapper -Config --subagent row'; Row = ($ompWrapperRow + ' -Config "C:\x\coralline.omp.json" --subagent'); Moves = $true },
            [pscustomobject]@{ Name = 'wrapper -Config -OmpExe --subagent row'; Row = ($ompWrapperRow + ' -Config "C:\x.json" -OmpExe "C:\o\oh-my-posh.exe" --subagent'); Moves = $true },
            [pscustomobject]@{ Name = 'Bash row for this root'; Row = $ompBashRow; Moves = $true },
            [pscustomobject]@{ Name = 'wrapper row for another root'; Row = ($ompOtherRoot + ' --subagent'); Moves = $false },
            [pscustomobject]@{ Name = 'upper-case wrapper row'; Row = ($ompWrapperRow + ' --subagent').ToUpperInvariant(); Moves = $false },
            [pscustomobject]@{ Name = 'wrapper row with an extra argument'; Row = ($ompWrapperRow + ' --subagent --extra'); Moves = $false },
            [pscustomobject]@{ Name = 'wrapper row with an extra flag before --subagent'; Row = ($ompWrapperRow + ' -Verbose --subagent'); Moves = $false }
        )
        foreach ($case in $ompSubCases) {
            $rowValue = '{"type":"command","command":' + (ConvertTo-TestJsonString $case.Row) + '}'
            Write-Utf8 $ompSub.Settings ('{"subagentStatusLine":' + $rowValue + '}')
            $subRun = Invoke-OmpInstaller $Repo $ompSub.Install $ompSub.Settings
            $expectedRow = $rowValue
            if ($case.Moves) { $expectedRow = Get-DesiredSubagentValue $ompSub.Install }
            $verb = 'is kept'
            if ($case.Moves) { $verb = 'moves to the native row' }
            Check "omp preserve: $($case.Name) $verb" (
                $subRun.ExitCode -eq 0 -and
                (Read-Text $ompSub.Settings) -ceq (
                    '{"subagentStatusLine":' + $expectedRow + ',"statusLine":' + (Get-OmpValue $ompSub.Install) + '}'
                )
            )
        }
        $ompWrapperValue = '{"type":"command","command":' + (ConvertTo-TestJsonString ($ompWrapperRow + ' --subagent')) + '}'
        Write-Utf8 $ompSub.Settings ('{"subagentStatusLine":' + $ompWrapperValue + '}')
        $ompSubNative = Invoke-Installer $Repo $ompSub.Install $ompSub.Settings '' 'native'
        Check 'native rerun keeps a wrapper --subagent row (documented asymmetry)' (
            $ompSubNative.ExitCode -eq 0 -and
            (Read-Text $ompSub.Settings) -ceq (
                '{"subagentStatusLine":' + $ompWrapperValue + ',"statusLine":' + (Get-DesiredValue $ompSub.Install) + '}'
            )
        )
        # Same host gate as the Bash runtime cases above: machine-wide Git Bash that finds jq.
        $ompBash = Get-ExpectedGitBash
        $ompBashReason = 'Git for Windows is not installed machine-wide on this host'
        if ($null -ne $ompBash) {
            $ompJqProbe = Invoke-CapturedProcess $ompBash '--noprofile --norc -c "command -v jq"' '' @{} $TempRoot 15000
            if ($ompJqProbe.ExitCode -ne 0) {
                $ompBashReason = 'Git Bash cannot find jq on this host'
                $ompBash = $null
            }
        }
        if ($null -ne $ompBash) {
            $ompBashCommand = '"' + $ompBash + '" "' + [IO.Path]::GetFullPath($ompSub.Install).Replace('\', '/') + '/statusline.sh"'
            Write-Utf8 $ompSub.Settings ('{"subagentStatusLine":' + (Get-DesiredSubagentValue $ompSub.Install) + '}')
            [void](Invoke-OmpInstaller $Repo $ompSub.Install $ompSub.Settings)
            $ompSubAuto = Invoke-Installer $Repo $ompSub.Install $ompSub.Settings '' 'default'
            Check 'omp then default auto selecting bash moves the native subagent row to bash' (
                $ompSubAuto.ExitCode -eq 0 -and
                (Read-Text $ompSub.Settings) -ceq (
                    '{"subagentStatusLine":{"type":"command","command":' +
                    (ConvertTo-TestJsonString ($ompBashCommand + ' --subagent')) + '}' +
                    ',"statusLine":{"type":"command","command":' + (ConvertTo-TestJsonString $ompBashCommand) +
                    ',"refreshInterval":1}}'
                )
            )
        } else {
            Blocked 'omp then auto selecting bash' $ompBashReason
        }

        # -- switching back to native keeps every omp file in place -----------------------
        $ompSwitch = New-Paths 'omp-switch-native'
        $ompSwitchFresh = Invoke-OmpInstaller $Repo $ompSwitch.Install $ompSwitch.Settings
        $ompSwitchFiles = Get-RelativeFileSnapshot $ompSwitch.Install (@('statusline-omp.ps1', 'tools\build-omp-config.ps1') + $OmpGenerated) $true
        $ompSwitchRun = Invoke-Installer $Repo $ompSwitch.Install $ompSwitch.Settings '' 'native'
        Check 'native rerun after omp restores the native statusLine' (
            $ompSwitchFresh.ExitCode -eq 0 -and $ompSwitchRun.ExitCode -eq 0 -and
            (Read-Text $ompSwitch.Settings) -ceq ('{"statusLine":' + (Get-DesiredValue $ompSwitch.Install) + '}')
        )
        Check 'native rerun after omp leaves the wrapper, generator and configs byte-identical' (
            Test-SnapshotsEqual $ompSwitchFiles (
                Get-RelativeFileSnapshot $ompSwitch.Install (@('statusline-omp.ps1', 'tools\build-omp-config.ps1') + $OmpGenerated) $true
            )
        )

        # -- static check: every managed-list walk in the omp flow goes through Invoke-WithManagedSet --
        $ompTokens = $null
        $ompErrors = $null
        $ompAst = [Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$ompTokens, [ref]$ompErrors)
        $ompWalkers = @(
            'Assert-ExpectedManagedInventory', 'Assert-ValidManagedPayload', 'Assert-ValidStagedPayload',
            'Test-ManagedPayloadEqual', 'Get-ManagedPayloadBytes', 'Assert-ManagedPayloadBytes', 'Install-Runtime',
            'Undo-RuntimeInstall', 'Restore-ManagedRuntime', 'Remove-EmptyCreatedRuntime',
            'Stage-LocalPayload', 'Stage-RemotePayload'
        )
        $ompUnwrapped = New-Object 'System.Collections.Generic.List[string]'
        $ompWalkCount = 0
        foreach ($functionName in @('Invoke-CorallineOmpInstall', 'Undo-OmpInstall')) {
            $definition = $ompAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
            }, $true)
            if ($null -eq $definition) { $ompUnwrapped.Add("missing $functionName"); continue }
            foreach ($call in @($definition.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $ompWalkers -ccontains $node.GetCommandName()
            }, $true))) {
                $ompWalkCount++
                $wrapped = $false
                $parent = $call.Parent
                while ($null -ne $parent -and $parent -ne $definition) {
                    if ($parent -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                        $parent.Parent -is [Management.Automation.Language.CommandAst] -and
                        $parent.Parent.GetCommandName() -ceq 'Invoke-WithManagedSet') {
                        $wrapped = $true
                        break
                    }
                    $parent = $parent.Parent
                }
                if (-not $wrapped) { $ompUnwrapped.Add($call.Extent.Text) }
            }
            if ($definition.Extent.Text.Contains('$script:ManagedFiles =') -or $definition.Extent.Text.Contains('$script:ManagedFiles +=')) {
                $ompUnwrapped.Add("$functionName assigns the managed list")
            }
        }
        $nativeEntry = $ompAst.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Invoke-CorallineInstall'
        }, $true)
        Check 'omp flow walks the managed lists only through Invoke-WithManagedSet (AST)' (
            $ompErrors.Count -eq 0 -and $ompWalkCount -ge 15 -and $ompUnwrapped.Count -eq 0
        )
        if ($ompUnwrapped.Count -gt 0) { [Console]::Out.WriteLine('DIAG  unwrapped: ' + ($ompUnwrapped -join ' | ')) }
        Check 'native entry point never calls Invoke-WithManagedSet (AST)' (
            $null -ne $nativeEntry -and
            @($nativeEntry.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-WithManagedSet'
            }, $true)).Count -eq 0
        )
        $ompInventoryFunctions = @($ompAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            @('Assert-ExpectedManagedInventory', 'Get-SafeTreeInventory', 'Assert-NoReparsePath') -ccontains $node.Name
        }, $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
        $ompInventoryRoot = Join-Path $TempRoot 'omp-inventory-tools'
        [void][IO.Directory]::CreateDirectory((Join-Path $ompInventoryRoot 'themes'))
        [void][IO.Directory]::CreateDirectory((Join-Path $ompInventoryRoot 'tools'))
        Write-Utf8 (Join-Path $ompInventoryRoot 'statusline.ps1') 'x'
        $ompInventoryCheck = [scriptblock]::Create(
            'param($EngineValue, $Root) $Engine = $EngineValue; $script:ManagedFiles = @(''statusline.ps1''); ' + $ompInventoryFunctions +
            "`n" + 'try { Assert-ExpectedManagedInventory $Root ''staged payload''; return ''accepted'' } catch { return $_.Exception.Message }'
        )
        $nativeInventory = & $ompInventoryCheck 'native' $ompInventoryRoot
        $ompInventory = & $ompInventoryCheck 'omp' $ompInventoryRoot
        Check 'native staging still rejects a tools directory with the upstream error text' (
            [string]$nativeInventory -ceq 'staged payload has an unexpected directory inventory'
        )
        Check 'omp staging accepts exactly themes and tools' ([string]$ompInventory -ceq 'accepted')

        # -- renders through the registered command (real Oh-My-Posh) ------------------------
        $realOmp = $null
        foreach ($candidate in @(Get-Command -Name 'oh-my-posh' -CommandType Application -ErrorAction SilentlyContinue)) {
            if (-not ([string]$candidate.Source).EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $realProbe = Invoke-CapturedProcess ([string]$candidate.Source) 'version' '' @{} $TempRoot 15000
            $realMatch = [regex]::Match([string]$realProbe.Stdout, '\A([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})')
            if ($realProbe.ExitCode -eq 0 -and $realMatch.Success -and
                (New-Object Version([int]$realMatch.Groups[1].Value, [int]$realMatch.Groups[2].Value, [int]$realMatch.Groups[3].Value)) -ge [Version]'31.3.0') {
                $realOmp = [string]$candidate.Source
            }
            break
        }
        if ($null -eq $realOmp) {
            Blocked 'omp renders through the registered command' 'no oh-my-posh.exe 31.3.0 or newer on this host PATH'
        } else {
            $realOmpPath = [IO.Path]::GetDirectoryName($realOmp) + ';' + $ompSystemPath
            $ompGitBash = Get-ExpectedGitBash
            $ompSample = $StrictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $Repo 'test\sample-input.json')))
            # Decoys in the working directory: none may run when a registered command executes.
            $ompWorkspace = Join-Path $TempRoot 'omp fake workspace'
            [void][IO.Directory]::CreateDirectory($ompWorkspace)
            $ompMarker = Join-Path $ompWorkspace 'FAKE-RAN'
            [IO.File]::WriteAllBytes((Join-Path $ompWorkspace 'powershell.exe'), [byte[]](0x4d, 0x5a, 0, 0))
            [IO.File]::WriteAllBytes((Join-Path $ompWorkspace 'oh-my-posh.exe'), [byte[]](0x4d, 0x5a, 0, 0))
            foreach ($decoy in @('powershell.cmd', 'oh-my-posh.cmd', 'statusline-omp.cmd')) {
                Write-Utf8 (Join-Path $ompWorkspace $decoy) ('@echo fake>"' + $ompMarker + '"')
            }
            function Invoke-OmpRender([string]$Shell, [string]$Command, [string]$HomeDir, [string]$PathValue, [string]$ConfPath, [hashtable]$Extra = @{}) {
                $environment = @{
                    HOME = $HomeDir
                    USERPROFILE = $HomeDir
                    PATH = $PathValue
                    CORALLINE_NO_SAMPLE = '1'
                    CLAUDE_CONFIG_DIR = $null
                    CORALLINE_CONFIG = $ConfPath
                    CORALLINE_OMP_EXE = $null
                    CORALLINE_OMP_CONFIG = $null
                }
                foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
                switch ($Shell) {
                    'cmd' { return Invoke-CapturedProcess $env:ComSpec ('/d /s /c "' + $Command + '"') $ompSample $environment $ompWorkspace 60000 }
                    'bash' { return Invoke-CapturedProcess $ompGitBash ('--noprofile --norc -c ' + (ConvertTo-ProcessArgument $Command)) $ompSample $environment $ompWorkspace 60000 }
                    default { return Invoke-CapturedProcess $PowerShellExe $Command $ompSample $environment $ompWorkspace 60000 }
                }
            }

            $ompRender = [pscustomobject]@{
                Root = (Join-Path $TempRoot "omp render it's & (x)")
            }
            $ompRenderClaude = Join-Path $ompRender.Root 'not-dot-claude'
            $ompRenderInstall = Join-Path $ompRenderClaude 'coralline'
            $ompRenderSettings = Join-Path $ompRenderClaude 'settings.json'
            $ompRenderConf = Join-Path $ompRenderClaude 'coralline.conf'
            $ompRenderHome = Join-Path $ompRender.Root 'render home'
            $ompRenderOtherConfig = Join-Path $ompRender.Root 'other claude config'
            [void][IO.Directory]::CreateDirectory($ompRenderClaude)
            [void][IO.Directory]::CreateDirectory((Join-Path $ompRenderHome '.claude'))
            [void][IO.Directory]::CreateDirectory($ompRenderOtherConfig)
            Write-Utf8 $ompRenderConf ('VL_SEGMENTS="model ctx cost lines"' + "`n")
            $ompRenderRun = Invoke-OmpInstaller $Repo $ompRenderInstall $ompRenderSettings
            $ompRenderCommand = Get-OmpCommand $ompRenderInstall
            Check 'omp installs under a root outside HOME\.claude with space, & and quote' (
                $ompRenderRun.ExitCode -eq 0 -and
                (Read-Text $ompRenderSettings) -ceq ('{"statusLine":' + (Get-OmpValue $ompRenderInstall) + '}')
            )
            $directArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (Quote-ProcessArgument (Join-Path $ompRenderInstall 'statusline-omp.ps1')) + ' -Config ' +
                (Quote-ProcessArgument (Join-Path $ompRenderInstall 'coralline.omp.json'))
            $ompDirectRender = Invoke-OmpRender 'direct' $directArguments $ompRenderHome $realOmpPath $ompRenderConf
            Check 'direct wrapper render of the installed config shows the sample model' (
                $ompDirectRender.ExitCode -eq 0 -and $null -ne $ompDirectRender.Stdout -and $ompDirectRender.Stdout.Contains('Fable')
            )
            $ompShells = @('cmd')
            if ($null -ne $ompGitBash) { $ompShells += 'bash' } else { Blocked 'omp registered command under Git Bash' 'Git for Windows bash.exe is not installed machine-wide on this host' }
            foreach ($shell in $ompShells) {
                $shellRender = Invoke-OmpRender $shell $ompRenderCommand $ompRenderHome $realOmpPath $ompRenderConf
                Check "omp registered command under $shell renders byte-identical to the direct wrapper run" (
                    $shellRender.ExitCode -eq 0 -and $shellRender.StderrBytes.Length -eq 0 -and
                    [Convert]::ToBase64String($shellRender.StdoutBytes) -ceq [Convert]::ToBase64String($ompDirectRender.StdoutBytes)
                )
                $shellConfigDir = Invoke-OmpRender $shell $ompRenderCommand $ompRenderHome $realOmpPath $ompRenderConf @{ CLAUDE_CONFIG_DIR = $ompRenderOtherConfig }
                Check "omp registered command under $shell ignores CLAUDE_CONFIG_DIR thanks to -Config" (
                    $shellConfigDir.ExitCode -eq 0 -and
                    [Convert]::ToBase64String($shellConfigDir.StdoutBytes) -ceq [Convert]::ToBase64String($ompDirectRender.StdoutBytes)
                )
            }
            $noConfigArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (Quote-ProcessArgument (Join-Path $ompRenderInstall 'statusline-omp.ps1'))
            $ompNoConfigRender = Invoke-OmpRender 'direct' $noConfigArguments $ompRenderHome $realOmpPath $ompRenderConf @{ CLAUDE_CONFIG_DIR = $ompRenderOtherConfig }
            Check 'without -Config the same environment finds no config (so -Config is what renders)' (
                $ompNoConfigRender.ExitCode -eq 0 -and
                [Convert]::ToBase64String($ompNoConfigRender.StdoutBytes) -ceq [Convert]::ToBase64String([byte[]](10))
            )
            Check 'omp render decoys never ran' (-not [IO.File]::Exists($ompMarker))

            # Pinned -OmpPath: the pinned exe is a counting proxy in front of the real one.
            $ompProxyDir = New-OmpStubDirectory 'proxy' ('proxy:' + $realOmp)
            $ompProxyExe = Join-Path $ompProxyDir 'oh-my-posh.exe'
            $ompPinRender = Invoke-OmpInstaller $Repo $ompRenderInstall $ompRenderSettings @(
                '-Engine', 'omp', '-OmpPath', $ompProxyExe
            ) $ompSystemPath
            $ompProxyLog = Join-Path $ompProxyDir 'calls.log'
            if ([IO.File]::Exists($ompProxyLog)) { [IO.File]::Delete($ompProxyLog) }
            $pinnedRender = Invoke-OmpRender 'cmd' (Get-OmpCommand $ompRenderInstall $ompProxyExe) $ompRenderHome $ompSystemPath $ompRenderConf
            Check 'omp -OmpPath command renders through the pinned exe without PATH' (
                $ompPinRender.ExitCode -eq 0 -and $pinnedRender.ExitCode -eq 0 -and
                [Convert]::ToBase64String($pinnedRender.StdoutBytes) -ceq [Convert]::ToBase64String($ompDirectRender.StdoutBytes) -and
                [IO.File]::Exists($ompProxyLog)
            )

            # Auto placeholder: VL_MAX_LINES 2 -> 1 replaces auto (backed up), then one row, one OMP call.
            $ompAuto = New-Paths 'omp-auto-placeholder'
            [void][IO.Directory]::CreateDirectory($ompAuto.Claude)
            Write-Utf8 $ompAuto.Config ('VL_LAYOUT="auto"' + "`n" + 'VL_MAX_LINES="2"' + "`n" + 'VL_SEGMENTS="model ctx cost lines"' + "`n")
            $ompAutoFirst = Invoke-OmpInstaller $Repo $ompAuto.Install $ompAuto.Settings
            $ompAutoPath = Join-Path $ompAuto.Install 'coralline.auto.omp.json'
            $ompAutoReal = Get-FileSha256 $ompAutoPath
            Check 'omp VL_LAYOUT=auto with two lines installs a real auto config' (
                $ompAutoFirst.ExitCode -eq 0 -and (Read-Text $ompAutoPath).Contains('"CorallineAutoTokens"')
            )
            Write-Utf8 $ompAuto.Config ('VL_LAYOUT="auto"' + "`n" + 'VL_MAX_LINES="1"' + "`n" + 'VL_SEGMENTS="model ctx cost lines"' + "`n")
            $ompAutoBackupsBefore = Get-OmpBackups $ompAuto.Claude
            $ompAutoSecond = Invoke-OmpInstaller $Repo $ompAuto.Install $ompAuto.Settings
            $ompAutoBackupsAfter = Get-OmpBackups $ompAuto.Claude
            $ompAutoNew = @($ompAutoBackupsAfter.Generated | Where-Object { @($ompAutoBackupsBefore.Generated) -notcontains $_ })
            Check 'omp VL_MAX_LINES 2 -> 1 replaces auto with the placeholder and backs the old one up' (
                $ompAutoSecond.ExitCode -eq 0 -and
                (Read-Text $ompAutoPath).Contains('"CorallineAutoDisabled"') -and
                $ompAutoNew.Count -eq 1 -and
                (Get-FileSha256 (Join-Path $ompAutoNew[0] 'coralline.auto.omp.json')) -ceq $ompAutoReal -and
                (Get-OutputText $ompAutoSecond).Contains('generated config backup retained at') -and
                -not (Get-OutputText $ompAutoSecond).Contains('already up to date')
            )
            $ompAutoSingle = Join-Path $TempRoot 'omp-auto-single-row'
            [void][IO.Directory]::CreateDirectory($ompAutoSingle)
            foreach ($name in @('coralline.omp.json', 'coralline.float.omp.json')) {
                [IO.File]::Copy((Join-Path $ompAuto.Install $name), (Join-Path $ompAutoSingle $name), $true)
            }
            $ompProxyPath = $ompProxyDir + ';' + $ompSystemPath
            if ([IO.File]::Exists($ompProxyLog)) { [IO.File]::Delete($ompProxyLog) }
            $autoRender = Invoke-OmpRender 'cmd' (Get-OmpCommand $ompAuto.Install) $ompAuto.Home $ompProxyPath $ompAuto.Config
            $autoCalls = @()
            if ([IO.File]::Exists($ompProxyLog)) { $autoCalls = @([IO.File]::ReadAllLines($ompProxyLog)) }
            $singleArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' +
                (Quote-ProcessArgument (Join-Path $ompAuto.Install 'statusline-omp.ps1')) + ' -Config ' +
                (Quote-ProcessArgument (Join-Path $ompAutoSingle 'coralline.omp.json'))
            $singleRender = Invoke-OmpRender 'direct' $singleArguments $ompAuto.Home $realOmpPath $ompAuto.Config
            Check 'omp auto placeholder renders the one-row output byte for byte' (
                $autoRender.ExitCode -eq 0 -and $null -ne $autoRender.Stdout -and $autoRender.Stdout.Contains('Fable') -and
                [Convert]::ToBase64String($autoRender.StdoutBytes) -ceq [Convert]::ToBase64String($singleRender.StdoutBytes)
            )
            Check 'omp auto placeholder costs exactly one Oh-My-Posh call, on the main config' (
                $autoCalls.Count -eq 1 -and $autoCalls[0].Contains('coralline.omp.json') -and -not $autoCalls[0].Contains('auto.omp')
            )
        }
    }
    if ($null -ne $ompSavedInputEncoding) {
        try { [Console]::InputEncoding = $ompSavedInputEncoding } catch { }
    }
} finally {
    if ([IO.Directory]::Exists($TempRoot)) {
        $canonicalTemp = [IO.Path]::GetFullPath($TempRoot)
        $canonicalSystemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($canonicalTemp.StartsWith($canonicalSystemTemp, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($canonicalTemp).StartsWith('c 雪&(p)-')) {
            Remove-Item -LiteralPath $canonicalTemp -Recurse -Force
        } else {
            [Console]::Error.WriteLine("refusing unexpected test cleanup path: $canonicalTemp")
            $script:Fail++
        }
    }
}

[Console]::Out.WriteLine("RESULT  pass=$($script:Pass) fail=$($script:Fail) blocked=$($script:Blocked)")
if ($script:Fail -gt 0) { exit 1 }
exit 0
