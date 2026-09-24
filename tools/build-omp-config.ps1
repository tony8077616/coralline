#Requires -Version 5.1
<#
.SYNOPSIS
  Generate an Oh-My-Posh config that renders coralline's statusline.

.DESCRIPTION
  Reads coralline.conf with coralline's own parser, extracted live from
  statusline.ps1 through the PowerShell AST, so the generator and the native
  renderer can never disagree about what a config means. The resolved settings
  are then written out as an Oh-My-Posh config for `oh-my-posh claude --config`.

  Supported: styles pill, lean and classic; the bundled themes and every
  VL_BG_* / VL_FG_* override; the fixed layout with VL_SEGMENTS, VL_SEGMENTS2 and
  VL_SEGMENTS3; gauge thresholds, bar width and glyphs; VL_ASCII; path depth;
  name truncation; cost decimals; clock modes; the *_ALWAYS_SHOW switches; and the
  segments dir, project, git, stash, node, python, model, effort, ctx, limit5h,
  limit7d, lines, cost, style, duration and clock, plus cache and burn when rendered
  through statusline-omp.ps1. Other segment names are skipped with a warning.

  burn and VL_LIMIT_SYNC need statusline-omp.ps1, which runs coralline's own state
  layer on every render. A direct `oh-my-posh claude --config` call hides burn and
  shows limit5h / limit7d from the payload alone, never from the synced store.

  The output is pure ASCII JSON with LF line endings, identical under Windows
  PowerShell 5.1 and PowerShell 7.

.PARAMETER ConfigPath
  coralline.conf to read. Defaults to $env:CORALLINE_CONFIG, then
  ~/.claude/coralline.conf, the same order the native renderer uses.

.PARAMETER StatuslinePath
  statusline.ps1 supplying the config parser and defaults. Its folder's themes
  directory is the approved include root, as at runtime.

.PARAMETER OutFile
  Where the Oh-My-Posh config is written. Prints to stdout when omitted.

.PARAMETER FloatOutFile
  Where the float config for VL_FLOAT is written; not written when omitted.
  statusline-omp.ps1 looks for coralline.float.omp.json next to the main config.
  The config renders one block per VL_FLOAT_SEGMENTS token, each opened by a
  U+FDD0 <index> U+FDD1 marker, so the wrapper can trim and join the segments the
  way statusline.ps1 does. VL_FLOAT_SEGMENTS is baked in and needs a rebuild after
  a change; VL_FLOAT_SEP and VL_FLOAT_FILE are read at render time.

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-omp-config.ps1 -OutFile "$HOME\.claude\coralline\coralline.omp.json"

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-omp-config.ps1 -OutFile "$HOME\.claude\coralline\coralline.omp.json" -FloatOutFile "$HOME\.claude\coralline\coralline.float.omp.json"

.EXAMPLE
  pwsh -NoProfile -File .\tools\build-omp-config.ps1 -ConfigPath .\my.conf
#>
param(
    [string]$ConfigPath = '',
    [string]$StatuslinePath = '',
    [string]$OutFile = '',
    [string]$FloatOutFile = ''
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
if ([string]::IsNullOrEmpty($StatuslinePath)) { $StatuslinePath = Join-Path (Split-Path -Path $Here -Parent) 'statusline.ps1' }
$StatuslinePath = [System.IO.Path]::GetFullPath($StatuslinePath)
$ScriptDir = [System.IO.Path]::GetDirectoryName($StatuslinePath)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IntegerStyle = [System.Globalization.NumberStyles]::Integer
$FloatStyle = [System.Globalization.NumberStyles]::Float
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- 1. coralline's own parser and defaults, extracted from statusline.ps1 ------
$parseTokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($StatuslinePath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ('statusline.ps1 does not parse: ' + $parseErrors[0].Message) }
$helperNames = @('Glyph', 'Remove-ControlChars', 'Copy-Config', 'Add-Utf8Text', 'Read-WordChar', 'Decode-ShellWord',
    'Add-Utf8Run', 'Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath', 'Test-PathInside',
    'Test-NoReparseComponents', 'Test-SafeRegularFile', 'Read-StrictUtf8File', 'Import-ConfigFile',
    'Get-BoundedInt', 'Test-Color', 'Get-SegmentTokens')
$helpers = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $helperNames -contains $node.Name
    }, $false)
foreach ($definition in $helpers) { . ([scriptblock]::Create($definition.Extent.Text)) }
foreach ($name in $helperNames) {
    if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { throw ('statusline.ps1 no longer defines ' + $name) }
}

function Test-NoExitCode {
    <#
    .SYNOPSIS
      True when none of the given AST nodes holds an exit statement or an [Environment]::Exit call.
    .PARAMETER Nodes
      Statements taken from statusline.ps1.
    .EXAMPLE
      Test-NoExitCode -Nodes @($statement)
    #>
    param([object[]]$Nodes)
    foreach ($node in $Nodes) {
        if ($null -ne $node.Find({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) { return $false }
        if ([regex]::IsMatch([string]$node.Extent.Text, '\[\s*(System\s*\.\s*)?Environment\s*\]\s*::\s*Exit', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { return $false }
    }
    return $true
}

function Get-AstVariableName {
    <#
    .SYNOPSIS
      A variable's name without its scope or drive qualifier (script:, global:, local:, private:, using:, variable:).
    .PARAMETER Variable
      VariableExpressionAst.
    .EXAMPLE
      Get-AstVariableName -Variable $node
    #>
    param($Variable)
    return [regex]::Replace([string]$Variable.VariablePath.UserPath, '^(?i:script|global|local|private|using|variable):', '')
}

function Get-StatuslineWriteCount {
    <#
    .SYNOPSIS
      Number of places anywhere in statusline.ps1 that may write the variable, compared without case.
    .DESCRIPTION
      The same conservative count statusline-omp.ps1 uses: assignment targets at
      any depth (any operator, scope or type constraint), foreach variables, [ref]
      conversions, *-Variable commands and aliases naming it, -OutVariable and the
      other common variable parameters naming it, variable:<name> paths and
      .Set(<name>, ...) calls.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Name
      Variable name without $.
    .EXAMPLE
      Get-StatuslineWriteCount -Ast $ast -Name 'ShellWordStops'
    #>
    param($Ast, [string]$Name)
    # One pass over the tree, kept for this AST: every node that could write some
    # variable. Commands are kept only when they are *-Variable commands or carry a
    # common variable parameter, [ref] conversions and variable: paths only as such.
    if ($null -eq $script:OmpWriteSiteCache -or -not [object]::ReferenceEquals($script:OmpWriteSiteCache.Ast, $Ast)) {
        # Plain type tests with early returns: this predicate runs once per node.
        $sites = $Ast.FindAll({
                param($n)
                if ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -or $n -is [System.Management.Automation.Language.ForEachStatementAst]) { return $true }
                if ($n -is [System.Management.Automation.Language.CommandAst]) {
                    # A nested command is a node of its own, so only this command's own elements matter.
                    if ([string]$n.GetCommandName() -match '(^|\\)(?i:Set-Variable|New-Variable|Clear-Variable|Remove-Variable|sv|set|nv|clv|rv)$') { return $true }
                    foreach ($element in $n.CommandElements) {
                        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -match '^(?i:ov|ev|wv|iv|pv|OutV[a-z]*|ErrorV[a-z]*|WarningV[a-z]*|InformationV[a-z]*|PipelineV[a-z]*)$') { return $true }
                    }
                    return $false
                }
                if ($n -is [System.Management.Automation.Language.ConvertExpressionAst]) { return ($n.Type.TypeName.Name -match '^(?i:ref|System\.Management\.Automation\.PSReference)$') }
                if ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return ([string]$n.Value).StartsWith('variable:', [System.StringComparison]::OrdinalIgnoreCase) }
                if ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { return ([string]$n.Member.Extent.Text -match '^(?i:Set)$') }
                return $false
            }, $true)
        $script:OmpWriteSiteCache = @{ Ast = $Ast; Sites = @($sites); Text = [string]$Ast.Extent.Text; Start = [int]$Ast.Extent.StartOffset }
    }
    # Every write site spells the name somewhere in its own text, so only sites that
    # contain an occurrence of it are examined.
    $hits = New-Object 'System.Collections.Generic.List[int]'
    $text = $script:OmpWriteSiteCache.Text
    $at = $text.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase)
    while ($at -ge 0) {
        [void]$hits.Add($at + $script:OmpWriteSiteCache.Start)
        $at = $text.IndexOf($Name, $at + 1, [System.StringComparison]::OrdinalIgnoreCase)
    }
    $count = 0
    if ($hits.Count -eq 0) { return $count }
    foreach ($site in $script:OmpWriteSiteCache.Sites) {
        $from = $site.Extent.StartOffset
        $to = $site.Extent.EndOffset
        $spelled = $false
        foreach ($hit in $hits) { if ($hit -ge $from -and $hit -lt $to) { $spelled = $true; break } }
        if (-not $spelled) { continue }
        switch ($true) {
            { $site -is [System.Management.Automation.Language.AssignmentStatementAst] } {
                foreach ($target in $site.Left.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    if ([string]::Equals((Get-AstVariableName $target), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $count++ }
                }
                break
            }
            { $site -is [System.Management.Automation.Language.ForEachStatementAst] } {
                if ([string]::Equals((Get-AstVariableName $site.Variable), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $count++ }
                break
            }
            { $site -is [System.Management.Automation.Language.ConvertExpressionAst] } {
                foreach ($target in $site.Child.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
                    if ([string]::Equals((Get-AstVariableName $target), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $count++ }
                }
                break
            }
            { $site -is [System.Management.Automation.Language.StringConstantExpressionAst] } {
                if ([string]::Equals([string]$site.Value, 'variable:' + $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $count++ }
                break
            }
            { $site -is [System.Management.Automation.Language.InvokeMemberExpressionAst] } {
                foreach ($argument in @($site.Arguments)) {
                    if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]::Equals([string]$argument.Value, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $count++ }
                }
                break
            }
            default {
                $namesIt = $false
                foreach ($constant in $site.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                    if ([string]::Equals(([string]$constant.Value).TrimStart('+'), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $namesIt = $true }
                }
                if ($namesIt) { $count++ }
            }
        }
    }
    return $count
}

function Get-StatuslineBinding {
    <#
    .SYNOPSIS
      Script text of the one script-level constant assignment of a statusline.ps1 variable; throws otherwise.
    .DESCRIPTION
      The assignment must be a direct statement of the script body, operator =,
      with the unqualified variable alone on the left; the variable may be written
      nowhere else in the file; the right side may hold no variable other than
      $true, $false and $null, no command, no $( ), no script block and no nested
      assignment; and nothing may exit.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Name
      Variable name without $.
    .EXAMPLE
      Get-StatuslineBinding -Ast $ast -Name 'ShellWordStops'
    #>
    param($Ast, [string]$Name)
    $writes = Get-StatuslineWriteCount $Ast $Name
    if ($writes -ne 1) { throw ('statusline.ps1 writes $' + $Name + ' in ' + $writes + ' places; expected exactly one') }
    $source = $null
    foreach ($statement in $Ast.EndBlock.Statements) {
        if ($statement -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
        if ($statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
        if ($statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if (-not $statement.Left.VariablePath.IsUnqualified) { continue }
        if ([string]::Equals((Get-AstVariableName $statement.Left), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $source = $statement }
    }
    if ($null -eq $source) { throw ('statusline.ps1 no longer assigns $' + $Name + ' at script level') }
    $forbidden = $source.Right.Find({
            param($n)
            ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and @('true', 'false', 'null') -notcontains [string]$n.VariablePath.UserPath) -or
            $n -is [System.Management.Automation.Language.CommandAst] -or
            $n -is [System.Management.Automation.Language.SubExpressionAst] -or
            $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
            $n -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true)
    if ($null -ne $forbidden) { throw ('statusline.ps1 assigns $' + $Name + ' from something other than a constant') }
    if (-not (Test-NoExitCode @($source))) { throw ('statusline.ps1 assignment of $' + $Name + ' can exit') }
    return [string]$source.Extent.Text + "`n"
}

function Get-StatuslineHomeBinding {
    <#
    .SYNOPSIS
      statusline.ps1's two $HomeDir statements as script text; throws otherwise.
    .DESCRIPTION
      Each statement must appear exactly once in the script body with exactly this
      text (ordinal), the second directly after the first, and nothing else in the
      file may write $HomeDir.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .EXAMPLE
      Get-StatuslineHomeBinding -Ast $ast
    #>
    param($Ast)
    $assignText = '$HomeDir = [string]$HOME'
    $fallbackText = "if ([string]::IsNullOrEmpty(`$HomeDir)) { `$HomeDir = [Environment]::GetFolderPath('UserProfile') }"
    $statements = $Ast.EndBlock.Statements
    $assignAt = -1
    $assignCount = 0
    $fallbackCount = 0
    for ($i = 0; $i -lt $statements.Count; $i++) {
        $text = [string]$statements[$i].Extent.Text
        if ([string]::Equals($text, $assignText, [System.StringComparison]::Ordinal)) { $assignCount++; $assignAt = $i }
        if ([string]::Equals($text, $fallbackText, [System.StringComparison]::Ordinal)) { $fallbackCount++ }
    }
    if ($assignCount -ne 1 -or $fallbackCount -ne 1 -or ($assignAt + 1) -ge $statements.Count -or
        -not [string]::Equals([string]$statements[$assignAt + 1].Extent.Text, $fallbackText, [System.StringComparison]::Ordinal)) {
        throw 'statusline.ps1 no longer sets $HomeDir with the expected two statements'
    }
    $writes = Get-StatuslineWriteCount $Ast 'HomeDir'
    if ($writes -ne 2) { throw ('statusline.ps1 writes $HomeDir in ' + $writes + ' places; expected exactly two') }
    if (-not (Test-NoExitCode @($statements[$assignAt], $statements[$assignAt + 1]))) { throw 'statusline.ps1 $HomeDir statements can exit' }
    return $assignText + "`n" + $fallbackText + "`n"
}

# Script-level values the parser reads, bound from statusline.ps1's own statements:
# $HomeDir (for ~ and $HOME in path values) and the quoting tables Decode-ShellWord
# scans with. Each must bind to a non-empty value that decodes a fixed word per
# quoting context exactly as expected.
$HomeDir = $null
. ([scriptblock]::Create((Get-StatuslineHomeBinding $ast)))
if (-not ($HomeDir -is [string] -and $HomeDir.Length -gt 0)) { throw 'statusline.ps1 left $HomeDir empty' }
foreach ($name in @('ShellWordStops', 'ShellDoubleQuoteStops', 'ShellAnsiQuoteStops')) {
    $bindingCode = Get-StatuslineBinding $ast $name
    Set-Variable -Name $name -Value $null
    . ([scriptblock]::Create($bindingCode))
    $bound = Get-Variable -Name $name -ValueOnly
    if (-not ($bound -is [char[]] -and $bound.Length -gt 0)) { throw ('statusline.ps1 $' + $name + ' is not a non-empty [char[]]') }
}
foreach ($canary in @(@('abc  # note', 'abc'), @('"a b\"c"', 'a b"c'), @("`$'a\tb'", "a`tb"), @("'x y'", 'x y'))) {
    $decodedWord = Decode-ShellWord $canary[0] $false
    if (-not ($decodedWord.Success -eq $true -and [string]::Equals([string]$decodedWord.Value, $canary[1], [System.StringComparison]::Ordinal))) {
        throw ('statusline.ps1 Decode-ShellWord no longer decodes ' + $canary[0] + ' as expected')
    }
}
$defaultsAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$Defaults'
    }, $false)
if ($null -eq $defaultsAst) { throw 'statusline.ps1 no longer assigns $Defaults' }
# $Defaults references these paths; their values do not matter to the generator.
$DefaultFloatFile = ''
$DefaultBurnFile = ''
$DefaultRl5File = ''
$DefaultRl7File = ''
. ([scriptblock]::Create($defaultsAst.Extent.Text))
$PathConfigKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($key in @('VL_FLOAT_FILE', 'BURN_FILE', 'RL5H_FILE', 'RL7D_FILE')) { [void]$PathConfigKeys.Add($key) }
$ConfigKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($key in $Defaults.Keys) { [void]$ConfigKeys.Add([string]$key) }

# ---- 2. Load the config exactly as statusline.ps1 does ----------------------------
$Cfg = Copy-Config $Defaults
$ConfigAssignments = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$ConfigInput = $ConfigPath
if ([string]::IsNullOrEmpty($ConfigInput)) { $ConfigInput = [string]$env:CORALLINE_CONFIG }
if ([string]::IsNullOrEmpty($ConfigInput)) { $ConfigInput = [System.IO.Path]::Combine([string]$HOME, '.claude\coralline.conf') }
$resolvedConfig = ConvertTo-LocalFullPath $ConfigInput ([Environment]::CurrentDirectory)
$configLoaded = $false
if (-not [string]::IsNullOrEmpty($resolvedConfig) -and [System.IO.File]::Exists($resolvedConfig)) {
    $approved = @([System.IO.Path]::GetDirectoryName($resolvedConfig))
    $themesRoot = ConvertTo-LocalFullPath ([System.IO.Path]::Combine($ScriptDir, 'themes')) $ScriptDir
    if (-not [string]::IsNullOrEmpty($themesRoot)) { $approved += $themesRoot }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $parsed = Import-ConfigFile $resolvedConfig $Cfg $ConfigAssignments @{ IncludeCount = 0; Visited = $visited } 0 $approved
    if ($parsed.Success) {
        $Cfg = $parsed.Config
        $ConfigAssignments = $parsed.Assignments
        $configLoaded = $true
    } else {
        [Console]::Error.WriteLine('warning: ' + $resolvedConfig + ' was rejected by the coralline parser; using defaults')
    }
}
foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars ([string]$Cfg[$key]) }

# ---- 3. Normalisation, in statusline.ps1's order -----------------------------------
$Cfg.VL_BAR_WIDTH = [string](Get-BoundedInt $Cfg.VL_BAR_WIDTH ([int]$Defaults.VL_BAR_WIDTH) 0 64)
$Cfg.VL_PATH_DEPTH = [string](Get-BoundedInt $Cfg.VL_PATH_DEPTH ([int]$Defaults.VL_PATH_DEPTH) 1 256)
$Cfg.VL_NAME_MAX = [string](Get-BoundedInt $Cfg.VL_NAME_MAX ([int]$Defaults.VL_NAME_MAX) 0 4096)
$Cfg.VL_COST_DECIMALS = [string](Get-BoundedInt $Cfg.VL_COST_DECIMALS ([int]$Defaults.VL_COST_DECIMALS) 0 9)
$Cfg.VL_WARN_PCT = [string](Get-BoundedInt $Cfg.VL_WARN_PCT ([int]$Defaults.VL_WARN_PCT) 0 100)
$Cfg.VL_HOT_PCT = [string](Get-BoundedInt $Cfg.VL_HOT_PCT ([int]$Defaults.VL_HOT_PCT) 0 100)
if ([int]$Cfg.VL_HOT_PCT -lt [int]$Cfg.VL_WARN_PCT) {
    $Cfg.VL_WARN_PCT = $Defaults.VL_WARN_PCT
    $Cfg.VL_HOT_PCT = $Defaults.VL_HOT_PCT
}
foreach ($key in @($Cfg.Keys | Where-Object { $_ -like 'VL_BG_*' -or $_ -like 'VL_FG_*' })) {
    if (-not (Test-Color $Cfg[$key])) { $Cfg[$key] = $Defaults[$key] }
}
if (-not (Test-Color $Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = '' }
if (-not (Test-Color $Cfg.VL_LEAN_FG)) { $Cfg.VL_LEAN_FG = '' }
$Cfg.VL_STYLE = switch -CaseSensitive ([string]$Cfg.VL_STYLE) {
    'pill' { 'pill'; break }
    'lean' { 'lean'; break }
    'classic' { 'classic'; break }
    default { 'pill' }
}
$Cfg.VL_LAYOUT = switch -CaseSensitive ([string]$Cfg.VL_LAYOUT) {
    'fixed' { 'fixed'; break }
    'auto' { 'auto'; break }
    default { 'fixed' }
}
if ($Cfg.VL_ASCII -eq '1') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_SEP = ''
    $Cfg.VL_BAR_FILL = '#'
    $Cfg.VL_BAR_EMPTY = '-'
    $Cfg.VL_NODE_GLYPH = 'node'
    $Cfg.VL_PY_GLYPH = 'py'
}
if ($Cfg.VL_STYLE -eq 'classic') {
    $Cfg.VL_STYLE = 'lean'
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) {
        $Cfg.VL_LEAN_BG = $Cfg.VL_BG_BAR
        if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = '238' }
    }
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_R)) { $Cfg.VL_LEAN_CAP_R = $Cfg.VL_SEP }
}
if ($Cfg.VL_STYLE -eq 'lean') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_FG_TEXT = $Cfg.VL_LEAN_FG
}
if ($Cfg.VL_LAYOUT -eq 'auto') {
    [Console]::Error.WriteLine('warning: VL_LAYOUT=auto is not supported by the Oh-My-Posh engine yet; rendering VL_SEGMENTS as one fixed row')
}

# ---- 4. Oh-My-Posh building blocks --------------------------------------------------
$Lean = $Cfg.VL_STYLE -eq 'lean'
$G = @{
    Branch = Glyph 0x2387; Diamond = Glyph 0x25C6; Flag = Glyph 0x2691; Dot = Glyph 0x2299; Pencil = Glyph 0x270E
    Hourglass = Glyph 0x29D6; Psi = Glyph 0x03C8; Ahead = Glyph 0x21E1; Behind = Glyph 0x21E3; Ellipsis = Glyph 0x2026
    Up = Glyph 0x2191; Down = Glyph 0x2193; Reset = Glyph 0x21BA; Check = Glyph 0x2713; BurnTo = Glyph 0x21E2
}

function ConvertTo-OmpColor {
    <#
    .SYNOPSIS
      Translate a coralline colour spec (256-colour index or "R,G,B") to Oh-My-Posh.
    .PARAMETER Spec
      coralline colour spec; empty means no colour.
    .EXAMPLE
      ConvertTo-OmpColor -Spec '81,166,199'
    #>
    param([string]$Spec)
    if ([string]::IsNullOrEmpty($Spec)) { return '' }
    if ($Spec.Contains(',')) {
        $parts = $Spec.Split(',')
        return [string]::Format($Invariant, '#{0:x2}{1:x2}{2:x2}', [int]$parts[0], [int]$parts[1], [int]$parts[2])
    }
    return $Spec
}

function Protect-Markup {
    <#
    .SYNOPSIS
      Escape a literal for use inside an Oh-My-Posh template string.
    .DESCRIPTION
      Literal glyphs from the config end up in Go template text; braces and angle
      brackets would otherwise be read as template actions or colour markup.
    .PARAMETER Text
      Literal text.
    .EXAMPLE
      Protect-Markup -Text '<x>'
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '<' { [void]$builder.Append('{{ "<" }}'); break }
            '>' { [void]$builder.Append('{{ ">" }}'); break }
            '{' { [void]$builder.Append('{{ "{" }}'); break }
            '}' { [void]$builder.Append('{{ "}" }}'); break }
            default { [void]$builder.Append($ch) }
        }
    }
    return $builder.ToString()
}

function Protect-Diamond {
    <#
    .SYNOPSIS
      Escape a literal for an Oh-My-Posh diamond, which is markup but not a template.
    .DESCRIPTION
      Uses Oh-My-Posh's own chevron escape (template.EscapeText): "<" becomes "<<>"
      and ">" becomes "<>>", so a cap or separator such as ">" is not read as colour
      markup. Template-style escaping would print literally here.
    .PARAMETER Text
      Literal cap or separator.
    .EXAMPLE
      Protect-Diamond -Text '>'
    #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $builder = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '<' { [void]$builder.Append('<<>'); break }
            '>' { [void]$builder.Append('<>>'); break }
            default { [void]$builder.Append($ch) }
        }
    }
    return $builder.ToString()
}

function Get-ColorSpan {
    <#
    .SYNOPSIS
      Wrap template text in a foreground colour, or return it unchanged for an empty colour.
    .PARAMETER Color
      Oh-My-Posh colour, or a template expression that yields one.
    .PARAMETER Text
      Template text.
    .EXAMPLE
      Get-ColorSpan -Color '245' -Text 'dim'
    #>
    param([string]$Color, [string]$Text)
    if ([string]::IsNullOrEmpty($Color)) { return $Text }
    return '<' + $Color + '>' + $Text + '</>'
}

function Get-TextSpan {
    <#
    .SYNOPSIS
      Text coloured as coralline's ${fg}: the segment default in pill, VL_LEAN_FG in lean.
    .PARAMETER Text
      Template text.
    .EXAMPLE
      Get-TextSpan -Text ' x '
    #>
    param([string]$Text)
    if ($Lean) { return (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_TEXT) $Text) }
    return $Text
}

function Get-PctColorTemplate {
    <#
    .SYNOPSIS
      Template expression choosing VL_FG_OK / WARN / HOT for a percentage variable.
    .PARAMETER Variable
      Template variable holding an integer percentage, such as '$p'.
    .EXAMPLE
      Get-PctColorTemplate -Variable '$p'
    #>
    param([string]$Variable)
    return '{{ if ge ' + $Variable + ' ' + $Cfg.VL_HOT_PCT + ' }}' + (ConvertTo-OmpColor $Cfg.VL_FG_HOT) +
        '{{ else if ge ' + $Variable + ' ' + $Cfg.VL_WARN_PCT + ' }}' + (ConvertTo-OmpColor $Cfg.VL_FG_WARN) +
        '{{ else }}' + (ConvertTo-OmpColor $Cfg.VL_FG_OK) + '{{ end }}'
}

function Get-BarTemplate {
    <#
    .SYNOPSIS
      Gauge of VL_BAR_WIDTH cells rounded like New-Bar: floor((pct * width + 50) / 100).
    .PARAMETER Variable
      Template variable holding an integer percentage clamped to 0..100.
    .EXAMPLE
      Get-BarTemplate -Variable '$p'
    #>
    param([string]$Variable)
    $width = [int]$Cfg.VL_BAR_WIDTH
    if ($width -le 0) { return '' }
    return '{{ $f := div (add (mul ' + $Variable + ' ' + $width + ') 50) 100 }}{{ repeat $f "' + (Protect-Markup $Cfg.VL_BAR_FILL) +
        '" }}{{ repeat (sub ' + $width + ' $f) "' + (Protect-Markup $Cfg.VL_BAR_EMPTY) + '" }}'
}

function Get-TokTemplate {
    <#
    .SYNOPSIS
      Token count formatted like Format-Tok: 1.2M, 45.6k, truncated to one decimal.
    .PARAMETER Expression
      Template expression yielding a non-negative integer.
    .EXAMPLE
      Get-TokTemplate -Expression '.ContextWindow.TotalInputTokens'
    #>
    param([string]$Expression, [string]$EnvName = '')
    $formatted = '{{ $n := ' + $Expression + ' }}{{ if ge $n 1000000 }}{{ printf "%d.%dM" (div $n 1000000) (div (mod $n 1000000) 100000) }}' +
        '{{ else if ge $n 1000 }}{{ printf "%d.%dk" (div $n 1000) (div (mod $n 1000) 100) }}{{ else }}{{ $n }}{{ end }}'
    if ([string]::IsNullOrEmpty($EnvName)) { return $formatted }
    # statusline-omp.ps1 passes coralline's own Format-Tok text, which keeps a
    # non-integer payload value verbatim where an Oh-My-Posh int cannot.
    return '{{ if .Env.' + $EnvName + ' }}{{ .Env.' + $EnvName + ' }}{{ else }}' + $formatted + '{{ end }}'
}

function Get-TruncTemplate {
    <#
    .SYNOPSIS
      Name shortened like Get-Trunc to VL_NAME_MAX characters with a middle ellipsis.
    .DESCRIPTION
      Byte-based: exact for ASCII names, which covers branch and repository names.
    .PARAMETER Expression
      Template expression yielding the name.
    .EXAMPLE
      Get-TruncTemplate -Expression '.Ref'
    #>
    param([string]$Expression)
    $max = [int]$Cfg.VL_NAME_MAX
    if ($max -le 0) { return '{{ ' + $Expression + ' }}' }
    $head = [int][Math]::Floor(($max - 1) / 2)
    $tail = $max - 1 - $head
    $short = '{{ substr 0 ' + $max + ' $t }}'
    if ($max -ge 3) { $short = '{{ substr 0 ' + $head + ' $t }}' + $G.Ellipsis + '{{ substr (sub (len $t) ' + $tail + ') (len $t) $t }}' }
    return '{{ $t := ' + $Expression + ' }}{{ if gt (len $t) ' + $max + ' }}' + $short + '{{ else }}{{ $t }}{{ end }}'
}

function Get-CountdownTemplate {
    <#
    .SYNOPSIS
      Countdown formatted like Format-Countdown: 1d11h, 2h44m, 44m, or now.
    .PARAMETER Expression
      Template expression yielding the reset epoch.
    .EXAMPLE
      Get-CountdownTemplate -Expression '.RateLimits.FiveHour.ResetsAt'
    #>
    param([string]$Expression)
    return '{{ $d := sub ' + $Expression + ' (now | unixEpoch) }}{{ if le $d 0 }}now' +
        '{{ else if ge $d 86400 }}{{ printf "%dd%02dh" (div $d 86400) (div (mod $d 86400) 3600) }}' +
        '{{ else if ge $d 3600 }}{{ printf "%dh%02dm" (div $d 3600) (div (mod $d 3600) 60) }}' +
        '{{ else }}{{ printf "%dm" (div $d 60) }}{{ end }}'
}

function Get-BankersPctTemplate {
    <#
    .SYNOPSIS
      Integer percentage from a float, clamped to 0..100 and rounded half to even like Get-PctValue.
    .PARAMETER Expression
      Template expression yielding the float (a pointer is dereferenced by addf).
    .PARAMETER Variable
      Template variable to assign.
    .EXAMPLE
      Get-BankersPctTemplate -Expression '.RateLimits.FiveHour.UsedPercentage' -Variable '$p'
    #>
    param([string]$Expression, [string]$Variable)
    return '{{ $x := addf ' + $Expression + ' 0 }}{{ if lt $x 0.0 }}{{ $x = 0.0 }}{{ end }}{{ if gt $x 100.0 }}{{ $x = 100.0 }}{{ end }}' +
        '{{ $fl := floor $x }}{{ $fr := subf $x $fl }}{{ ' + $Variable + ' := int $fl }}' +
        '{{ if gt $fr 0.5 }}{{ ' + $Variable + ' = add ' + $Variable + ' 1 }}{{ else if eq $fr 0.5 }}{{ if eq (mod ' + $Variable + ' 2) 1 }}{{ ' + $Variable + ' = add ' + $Variable + ' 1 }}{{ end }}{{ end }}'
}

function Get-PathTemplate {
    <#
    .SYNOPSIS
      Current directory collapsed like Get-DisplayPath: ~ for home, first/.../last beyond VL_PATH_DEPTH.
    .EXAMPLE
      Get-PathTemplate
    #>
    # No {{- -}} trim markers: they would also eat the literal spaces the caller
    # puts around the path.
    $depth = [int]$Cfg.VL_PATH_DEPTH
    # statusline-omp.ps1 passes the payload directory verbatim: Oh-My-Posh replaces a
    # directory that does not exist with its own working folder.
    return '{{ $s := regexReplaceAll "\\\\" (or .Env.CORALLINE_OMP_CWD .PWD) "/" }}' +
        # statusline.ps1 compares against PowerShell's $HOME, which Windows derives from the
        # profile directory, not from the HOME variable; USERPROFILE is that directory.
        '{{ $h := trimSuffix "/" (regexReplaceAll "\\\\" .Env.USERPROFILE "/") }}' +
        '{{ if and $h (eq (lower $s) (lower $h)) }}{{ $s = "~" }}{{ else if and $h (hasPrefix (printf "%s/" (lower $h)) (lower $s)) }}{{ $s = printf "~%s" (substr (len $h) (len $s) $s) }}{{ end }}' +
        '{{ $l := compact (splitList "/" $s) }}{{ $n := len $l }}' +
        '{{ if eq $n 0 }}/{{ else if and (eq $n 1) (regexMatch "^[A-Za-z]:$" (index $l 0)) }}{{ index $l 0 }}/' +
        '{{ else if le $n ' + $depth + ' }}{{ trimSuffix "/" $s }}{{ else }}{{ index $l 0 }}/{{ index $l 1 }}/' + $G.Ellipsis + '/{{ last $l }}{{ end }}'
}

function Get-PinWalkTemplate {
    <#
    .SYNOPSIS
      Template that walks from the working directory to the root, reading pin files like Read-PinFile.
    .DESCRIPTION
      Assigns $v the first line of the first non-empty pin file found, with control
      characters removed and surrounding whitespace trimmed. A missing file reads as
      empty, so the walk simply continues.
    .PARAMETER Names
      Pin file names checked in order in each directory.
    .EXAMPLE
      Get-PinWalkTemplate -Names @('.nvmrc', '.node-version')
    #>
    param([string[]]$Names)
    $list = (@($Names | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    return '{{ $parts := splitList "/" (regexReplaceAll "\\\\" .AbsolutePWD "/") }}' +
        '{{ range $i := untilStep (len $parts) 0 -1 }}{{ if not $v }}{{ $dir := join "/" (slice $parts 0 $i) }}' +
        '{{ range $name := list ' + $list + ' }}{{ if not $v }}{{ $raw := readFile (printf "%s/%s" $dir $name) }}' +
        '{{ $v = trim (regexReplaceAll "[\\x00-\\x1f\\x7f-\\x9f]" (regexFind "^[^\\r\\n]*" $raw) "") }}{{ end }}{{ end }}{{ end }}{{ end }}'
}

$SegmentTemplates = [ordered]@{}
$dirTemplate = '<b>' + (Get-TextSpan (' ' + (Get-PathTemplate) + ' ')) + '</b>'
$SegmentTemplates['dir'] = @{ Type = 'path'; Bg = $Cfg.VL_BG_DIR; Template = $dirTemplate }
$projectBg = $Cfg.VL_BG_PROJECT
if ([string]::IsNullOrEmpty($projectBg)) { $projectBg = $Cfg.VL_BG_DIR }
# RepoName is the main worktree's folder in a linked worktree, matching Get-GitRoot's
# --git-common-dir, so the name stays stable across worktrees.
$SegmentTemplates['project'] = @{
    Type = 'git'; Bg = $projectBg; Alias = 'CorallineProject'
    Template = '{{ if .RepoName }}<b>' + (Get-TextSpan (' ' + (Protect-Markup $Cfg.VL_PROJECT_GLYPH) + ' ' + (Get-TruncTemplate '.RepoName') + ' ')) + '</b>{{ end }}'
}
# Outside a repository the project pill falls back to the directory, but only when
# no row lists dir itself (Add-ProjectSegment).
$SegmentTemplates['project-fallback'] = @{
    Type = 'path'; Bg = $Cfg.VL_BG_DIR
    Template = '{{ if not (.Segments.Contains "CorallineProject") }}' + $dirTemplate + '{{ end }}'
}
$probe = $Cfg.VL_RUNTIME_PROBE -eq '1'
$nodeProbe = ''
if ($probe) { $nodeProbe = '{{ if not $v }}{{ $v = trim (cmd "node" "--version") }}{{ end }}' }
$nodeBg = $Cfg.VL_BG_NODE
if ([string]::IsNullOrEmpty($nodeBg)) { $nodeBg = $Cfg.VL_BG_MODEL }
$SegmentTemplates['node'] = @{
    Type = 'text'; Bg = $nodeBg
    Template = '{{ $v := "" }}' + (Get-PinWalkTemplate @('.nvmrc', '.node-version')) + $nodeProbe +
        '{{ $v = regexReplaceAll "^v+" $v "" }}{{ if $v }}' + (Get-TextSpan (' ' + (Protect-Markup $Cfg.VL_NODE_GLYPH) + ' {{ $v }} ')) + '{{ end }}'
}
$pythonProbe = ''
if ($probe) { $pythonProbe = '{{ if not $v }}{{ $v = trim (regexReplaceAll "^Python " (trim (cmd "python3" "--version")) "") }}{{ end }}' }
$pythonBg = $Cfg.VL_BG_PYTHON
if ([string]::IsNullOrEmpty($pythonBg)) { $pythonBg = $Cfg.VL_BG_MODEL }
$SegmentTemplates['python'] = @{
    Type = 'text'; Bg = $pythonBg
    Template = '{{ $v := "" }}{{ $venv := regexReplaceAll "[\\x00-\\x1f\\x7f-\\x9f]" (default "" .Env.VIRTUAL_ENV) "" }}' +
        '{{ $conda := regexReplaceAll "[\\x00-\\x1f\\x7f-\\x9f]" (default "" .Env.CONDA_DEFAULT_ENV) "" }}' +
        '{{ if $venv }}{{ $v = base (regexReplaceAll "[\\\\/]+$" (regexReplaceAll "\\\\" $venv "/") "") }}' +
        '{{ else if and $conda (ne $conda "base") }}{{ $v = $conda }}{{ else }}' + (Get-PinWalkTemplate @('.python-version')) + '{{ end }}' + $pythonProbe +
        '{{ if $v }}' + (Get-TextSpan (' ' + (Protect-Markup $Cfg.VL_PY_GLYPH) + ' {{ $v }} ')) + '{{ end }}'
}
$gitDirty = '(or (gt (add .Staging.Added .Staging.Deleted .Staging.Modified .Staging.Moved) 0) (gt (add .Working.Added .Working.Deleted .Working.Modified .Working.Moved .Working.Unmerged .Working.Conflicted) 0) (gt .Working.Untracked 0))'
$SegmentTemplates['git'] = @{
    Type = 'git'; Bg = $Cfg.VL_BG_GIT_OK; BgDirty = $Cfg.VL_BG_GIT_DIRTY; DirtyCondition = $gitDirty
    Options = [ordered]@{ fetch_status = $true }
    Template = '<b>' + (Get-TextSpan (' ' + $G.Branch + ' ' + (Get-TruncTemplate '.Ref') +
            '{{ if gt (add .Staging.Added .Staging.Deleted .Staging.Modified .Staging.Moved) 0 }}+{{ end }}' +
            '{{ if gt (add .Working.Added .Working.Deleted .Working.Modified .Working.Moved .Working.Unmerged .Working.Conflicted) 0 }}!{{ end }}' +
            '{{ if gt .Working.Untracked 0 }}?{{ end }}' +
            '{{ if gt .Ahead 0 }}' + $G.Ahead + '{{ .Ahead }}{{ end }}{{ if gt .Behind 0 }}' + $G.Behind + '{{ .Behind }}{{ end }} ')) + '</b>'
}
$stashBg = $Cfg.VL_BG_STASH
if ([string]::IsNullOrEmpty($stashBg)) { $stashBg = $Cfg.VL_BG_GIT_OK }
$SegmentTemplates['stash'] = @{
    Type = 'git'; Bg = $stashBg
    Template = '{{ if gt .StashCount 0 }}' + (Get-TextSpan (' ' + $G.Flag + ' {{ .StashCount }} ')) + '{{ end }}'
}
$SegmentTemplates['model'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_MODEL
    Template = '{{ if .Model.DisplayName }}<b>' + (Get-TextSpan (' ' + $G.Diamond + ' {{ trimPrefix "Claude " .Model.DisplayName }} ')) + '</b>{{ end }}'
}
$SegmentTemplates['effort'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_EFFORT
    Template = '{{ if and .Effort .Effort.Level }}' + (Get-TextSpan (' ' + $G.Psi + ' {{ if eq .Effort.Level "medium" }}med{{ else }}{{ .Effort.Level }}{{ end }} ')) + '{{ end }}'
}
$ctxShow = '.ContextWindow.UsedPercentage'
if ($Cfg.VL_CTX_ALWAYS_SHOW -eq '1') { $ctxShow = 'true' }
$SegmentTemplates['ctx'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_CTX
    Template = '{{ if and (not .Env.CORALLINE_OMP_CTX_HIDE) ' + $ctxShow + ' }}{{ $p := 0 }}{{ if .ContextWindow.UsedPercentage }}{{ $p = int .ContextWindow.UsedPercentage }}{{ end }}' +
        '{{ if lt $p 0 }}{{ $p = 0 }}{{ end }}{{ if gt $p 100 }}{{ $p = 100 }}{{ end }}' +
        '{{ $cr := 0 }}{{ $cw := 0 }}{{ if .ContextWindow.CurrentUsage }}{{ $cr = .ContextWindow.CurrentUsage.CacheReadInputTokens }}{{ $cw = .ContextWindow.CurrentUsage.CacheCreationInputTokens }}{{ end }}' +
        (Get-ColorSpan (Get-PctColorTemplate '$p') (' ' + (Protect-Markup $Cfg.VL_CTX_GLYPH) + ' ' + (Get-BarTemplate '$p') + ' {{ $p }}% ')) +
        (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_DIM) ($G.Up + (Get-TokTemplate '.ContextWindow.TotalInputTokens' 'CORALLINE_OMP_TOK_IN') + ' ' +
            $G.Down + (Get-TokTemplate '.ContextWindow.TotalOutputTokens' 'CORALLINE_OMP_TOK_OUT') +
            ' cr:' + (Get-TokTemplate '$cr' 'CORALLINE_OMP_TOK_CR') + ' cw:' + (Get-TokTemplate '$cw' 'CORALLINE_OMP_TOK_CW') + ' ')) + '{{ end }}'
}
# prompt_cache is not part of Oh-My-Posh's Claude model, so statusline-omp.ps1 computes
# the percentage and the countdown with coralline's own helpers and passes them in
# the environment. A direct `oh-my-posh claude` call has neither and hides the segment.
$cacheBg = $Cfg.VL_BG_CACHE
if ([string]::IsNullOrEmpty($cacheBg)) { $cacheBg = $Cfg.VL_BG_CTX }
$SegmentTemplates['cache'] = @{
    Type = 'text'; Bg = $cacheBg
    Template = '{{ if .Env.CORALLINE_OMP_CACHE_PCT }}{{ $p := atoi .Env.CORALLINE_OMP_CACHE_PCT }}{{ $q := sub 100 $p }}' +
        (Get-ColorSpan (Get-PctColorTemplate '$q') (' ' + (Protect-Markup $Cfg.VL_CACHE_GLYPH) + ' {{ $p }}% ')) +
        (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_DIM) ('{{ if eq .Env.CORALLINE_OMP_CACHE_LEFT "cold" }}cold{{ else }}' + $G.Reset + '{{ .Env.CORALLINE_OMP_CACHE_LEFT }}{{ end }} ')) + '{{ end }}'
}
# burn: statusline-omp.ps1 runs coralline's own state layer and passes Add-BurnSegment's
# decision in the environment: CORALLINE_OMP_BURN (warming, idle, done or active),
# CORALLINE_OMP_BURN_TONE (dim, ok, warn or hot) and, when active, CORALLINE_OMP_BURN_ETA
# ("5h 1h28m", ASCII only). The arrow between label and ETA is written here. A direct
# `oh-my-posh claude` call has none of them and hides the segment.
$burnBg = $Cfg.VL_BG_BURN
if ([string]::IsNullOrEmpty($burnBg)) { $burnBg = $Cfg.VL_BG_5H }
$burnTone = '{{ if eq .Env.CORALLINE_OMP_BURN_TONE "hot" }}' + (ConvertTo-OmpColor $Cfg.VL_FG_HOT) +
    '{{ else if eq .Env.CORALLINE_OMP_BURN_TONE "warn" }}' + (ConvertTo-OmpColor $Cfg.VL_FG_WARN) +
    '{{ else if eq .Env.CORALLINE_OMP_BURN_TONE "ok" }}' + (ConvertTo-OmpColor $Cfg.VL_FG_OK) +
    '{{ else }}' + (ConvertTo-OmpColor $Cfg.VL_FG_DIM) + '{{ end }}'
$burnText = ' ' + (Protect-Markup $Cfg.VL_BURN_GLYPH) + ' {{ if eq .Env.CORALLINE_OMP_BURN "warming" }}' + $G.Ellipsis +
    '{{ else if eq .Env.CORALLINE_OMP_BURN "active" }}{{ $e := splitList " " .Env.CORALLINE_OMP_BURN_ETA }}{{ index $e 0 }} ' + $G.BurnTo + ' {{ index $e 1 }}' +
    '{{ else }}' + $G.Check + '{{ end }} '
$SegmentTemplates['burn'] = @{
    Type = 'text'; Bg = $burnBg
    Template = '{{ if .Env.CORALLINE_OMP_BURN }}' + (Get-ColorSpan $burnTone $burnText) + '{{ end }}'
}
foreach ($window in @(@('limit5h', 'FiveHour', '5h', $Cfg.VL_BG_5H), @('limit7d', 'SevenDay', '7d', $Cfg.VL_BG_7D))) {
    $source = '.RateLimits.' + $window[1]
    $reset = '{{ if ' + $source + '.ResetsAt }}' + (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_DIM) ($G.Reset + (Get-CountdownTemplate ($source + '.ResetsAt')))) + '{{ end }}'
    $SegmentTemplates[$window[0]] = @{
        Type = 'claude'; Bg = $window[3]
        Template = '{{ if and .RateLimits ' + $source + ' ' + $source + '.UsedPercentage }}' + (Get-BankersPctTemplate ($source + '.UsedPercentage') '$p') +
            (Get-ColorSpan (Get-PctColorTemplate '$p') (' ' + $window[2] + ' ' + (Get-BarTemplate '$p') + ' {{ $p }}% ')) + $reset + ' {{ end }}'
    }
}
$SegmentTemplates['lines'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_LINES
    Template = '{{ $a := max .Cost.TotalLinesAdded 0 }}{{ $r := max .Cost.TotalLinesRemoved 0 }}{{ if or (gt $a 0) (gt $r 0) }} ' +
        (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_OK) '+{{ $a }}') + ' ' + (Get-ColorSpan (ConvertTo-OmpColor $Cfg.VL_FG_HOT) '-{{ $r }}') + ' {{ end }}'
}
$costZero = '(gt $c 0.0)'
if ($Cfg.VL_COST_ALWAYS_SHOW -eq '1') { $costZero = 'true' }
$SegmentTemplates['cost'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_COST
    Template = '{{ $c := .Cost.TotalCostUSD }}{{ if and (not .Env.CORALLINE_OMP_COST_HIDE) (ge $c 0.0) (le $c 1000000000.0) ' + $costZero + ' }}' +
        (Get-TextSpan (' ${{ printf "%.' + $Cfg.VL_COST_DECIMALS + 'f" $c }} ')) + '{{ end }}'
}
$SegmentTemplates['style'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_STYLE
    Template = '{{ if and .OutputStyle .OutputStyle.Name (ne .OutputStyle.Name "default") }}' + (Get-TextSpan (' ' + $G.Pencil + ' {{ .OutputStyle.Name }} ')) + '{{ end }}'
}
$SegmentTemplates['duration'] = @{
    Type = 'claude'; Bg = $Cfg.VL_BG_DURATION
    Template = '{{ $ms := atoi (printf "%d" .Cost.TotalDurationMS) }}{{ if gt $ms 0 }}{{ $s := div $ms 1000 }}' +
        (Get-TextSpan (' ' + $G.Hourglass + ' {{ if ge $s 3600 }}{{ printf "%dh%02dm" (div $s 3600) (div (mod $s 3600) 60) }}' +
            '{{ else if ge $s 60 }}{{ printf "%dm" (div $s 60) }}{{ else }}{{ $s }}s{{ end }} ')) + '{{ end }}'
}
if ($Cfg.VL_CLOCK -cne 'off') {
    $layout = '03:04 pm'
    switch -CaseSensitive ($Cfg.VL_CLOCK) {
        '24h' { $layout = '15:04'; if ($Cfg.VL_CLOCK_SECONDS -eq '1') { $layout = '15:04:05' } }
        default { if ($Cfg.VL_CLOCK_SECONDS -eq '1') { $layout = '03:04:05 pm' } }
    }
    $SegmentTemplates['clock'] = @{
        Type = 'time'; Bg = $Cfg.VL_BG_CLOCK
        Template = Get-TextSpan (' ' + $G.Dot + ' {{ .CurrentDate | date "' + $layout + '" }} ')
    }
}

$SegmentTemplates['dir'].HideEnv = @('CORALLINE_OMP_NODIR')
$SegmentTemplates['project-fallback'].HideEnv = @('CORALLINE_OMP_NODIR')
$SegmentTemplates['project'].HideEnv = @('CORALLINE_OMP_NODIR', 'CORALLINE_OMP_NOPROBE')
foreach ($name in @('git', 'stash', 'node', 'python')) { $SegmentTemplates[$name].HideEnv = @('CORALLINE_OMP_NOPROBE') }

function New-OmpSegment {
    <#
    .SYNOPSIS
      Oh-My-Posh segment for one coralline segment in the configured style.
    .PARAMETER Spec
      Entry from $SegmentTemplates.
    .EXAMPLE
      New-OmpSegment -Spec $SegmentTemplates['model']
    #>
    param($Spec)
    $bg = ConvertTo-OmpColor $Spec.Bg
    $segment = [ordered]@{ type = $Spec.Type; style = 'diamond' }
    switch ($Lean) {
        $true {
            # lean paints each segment's text in its own background colour on the shared bar.
            $leanBg = ConvertTo-OmpColor $Cfg.VL_LEAN_BG
            $segment.background = $(if ($leanBg) { $leanBg } else { 'transparent' })
            $segment.foreground = $(if ($bg) { $bg } else { 'default' })
            if ($Spec.ContainsKey('BgDirty')) { $segment.foreground_templates = @('{{ if ' + $Spec.DirtyCondition + ' }}' + (ConvertTo-OmpColor $Spec.BgDirty) + '{{ end }}') }
            if (-not [string]::IsNullOrEmpty($Cfg.VL_LEAN_SEP)) { $segment.leading_diamond = '<default,background>' + (Protect-Diamond $Cfg.VL_LEAN_SEP) + '</>' }
        }
        default {
            $segment.background = $(if ($bg) { $bg } else { 'transparent' })
            $segment.foreground = $(if ($Cfg.VL_FG_TEXT) { ConvertTo-OmpColor $Cfg.VL_FG_TEXT } else { 'default' })
            if ($Spec.ContainsKey('BgDirty')) { $segment.background_templates = @('{{ if ' + $Spec.DirtyCondition + ' }}' + (ConvertTo-OmpColor $Spec.BgDirty) + '{{ end }}') }
            if (-not [string]::IsNullOrEmpty($Cfg.VL_SEP)) { $segment.leading_diamond = '<parentBackground,background>' + (Protect-Diamond $Cfg.VL_SEP) + '</>' }
        }
    }
    if ($Spec.ContainsKey('Options')) { $segment.options = $Spec.Options }
    if ($Spec.ContainsKey('Alias')) { $segment.alias = $Spec.Alias }
    $segment.template = $Spec.Template
    # statusline-omp.ps1 sets these when the payload has no usable directory, where
    # statusline.ps1 hides the segment and Oh-My-Posh would use its own working folder.
    if ($Spec.ContainsKey('HideEnv')) {
        $conditions = @($Spec.HideEnv | ForEach-Object { '.Env.' + $_ })
        $test = $conditions[0]
        if ($conditions.Count -gt 1) { $test = '(or ' + [string]::Join(' ', $conditions) + ')' }
        $segment.template = '{{ if not ' + $test + ' }}' + $Spec.Template + '{{ end }}'
    }
    return $segment
}

# A non-empty block diamond that prints nothing: Oh-My-Posh only swaps the first
# segment's own leading diamond (the separator) for the block's when the block has
# one, so without it the row would open with a stray separator.
$silentDiamond = '<transparent></>'
$capLeft = $Cfg.VL_CAP_L
$capRight = $Cfg.VL_CAP_R
if ($Lean) {
    $capLeft = ''
    $capRight = ''
    if (-not [string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) {
        $capLeft = $Cfg.VL_LEAN_CAP_L
        $capRight = $Cfg.VL_LEAN_CAP_R
    }
}
$rows = @($Cfg.VL_SEGMENTS)
if ($Cfg.VL_LAYOUT -eq 'fixed') { $rows += @($Cfg.VL_SEGMENTS2, $Cfg.VL_SEGMENTS3) }
# Main rows are all three lists regardless of layout, as $MainSegmentNames in statusline.ps1.
$mainNames = @(@($Cfg.VL_SEGMENTS, $Cfg.VL_SEGMENTS2, $Cfg.VL_SEGMENTS3) | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { [regex]::Split($_.Trim(), '\s+') } })
$dirListed = $mainNames -ccontains 'dir'
$blocks = New-Object 'System.Collections.Generic.List[object]'
$unsupported = New-Object 'System.Collections.Generic.List[string]'
foreach ($row in $rows) {
    if ([string]::IsNullOrWhiteSpace($row)) { continue }
    $segments = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in @([regex]::Split($row.Trim(), '\s+'))) {
        switch ($true) {
            { $name -ceq 'project' } {
                [void]$segments.Add((New-OmpSegment $SegmentTemplates['project']))
                if (-not $dirListed) { [void]$segments.Add((New-OmpSegment $SegmentTemplates['project-fallback'])) }
                break
            }
            { $name -ceq 'project-fallback' } { break }
            { $SegmentTemplates.Contains($name) } { [void]$segments.Add((New-OmpSegment $SegmentTemplates[$name])); break }
            { $name -ceq 'clock' } { break }
            default { if (-not $unsupported.Contains($name)) { [void]$unsupported.Add($name) } }
        }
    }
    if ($segments.Count -eq 0) { continue }
    $block = [ordered]@{ type = 'prompt'; alignment = 'left' }
    if ($blocks.Count -gt 0) { $block.newline = $true }
    $block.leading_diamond = $(if ($capLeft) { Protect-Diamond $capLeft } else { $silentDiamond })
    if ($capRight) { $block.trailing_diamond = Protect-Diamond $capRight }
    $block.segments = $segments.ToArray()
    [void]$blocks.Add($block)
}
foreach ($name in $unsupported) { [Console]::Error.WriteLine('warning: segment "' + $name + '" is not supported by the Oh-My-Posh engine yet; skipped') }

$config = [ordered]@{
    '$schema' = 'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json'
    version = 4
    # statusline-omp.ps1 refuses any config without this marker, because Oh-My-Posh
    # silently renders its own default layout for a config it cannot read.
    var = [ordered]@{ CorallineGenerator = 'coralline-omp/1' }
    blocks = $blocks.ToArray()
}

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
      Serialize to JSON identically on Windows PowerShell 5.1 and PowerShell 7.
    .DESCRIPTION
      ConvertTo-Json differs between the two (indentation, spacing, and 5.1 escaping
      < > & ' as < and friends), so the generator writes JSON itself: two-space
      indentation, only the escapes JSON requires, and every non-ASCII character as
      \uXXXX so the file is pure ASCII.
    .PARAMETER Value
      Ordered dictionary, array, string, boolean or integer.
    .PARAMETER Indent
      Current indentation depth.
    .EXAMPLE
      ConvertTo-CanonicalJson -Value ([ordered]@{ a = @(1, 'x') }) -Indent 0
    #>
    param($Value, [int]$Indent)
    $pad = '  ' * ($Indent + 1)
    $end = '  ' * $Indent
    switch ($true) {
        { $null -eq $Value } { return 'null' }
        { $Value -is [bool] } { if ($Value) { return 'true' } else { return 'false' } }
        { $Value -is [int] -or $Value -is [long] } { return $Value.ToString($Invariant) }
        { $Value -is [string] } {
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append('"')
            foreach ($ch in $Value.ToCharArray()) {
                switch ([int]$ch) {
                    34 { [void]$builder.Append('\"'); break }
                    92 { [void]$builder.Append('\\'); break }
                    { $_ -lt 32 -or $_ -gt 126 } { [void]$builder.AppendFormat($Invariant, '\u{0:x4}', [int]$ch); break }
                    default { [void]$builder.Append($ch) }
                }
            }
            [void]$builder.Append('"')
            return $builder.ToString()
        }
        { $Value -is [System.Collections.IDictionary] } {
            if ($Value.Count -eq 0) { return '{}' }
            $members = foreach ($key in $Value.Keys) { $pad + (ConvertTo-CanonicalJson ([string]$key) 0) + ': ' + (ConvertTo-CanonicalJson $Value[$key] ($Indent + 1)) }
            return "{`n" + ($members -join ",`n") + "`n" + $end + '}'
        }
        { $Value -is [System.Collections.IEnumerable] } {
            $items = @(foreach ($item in $Value) { $pad + (ConvertTo-CanonicalJson $item ($Indent + 1)) })
            if ($items.Count -eq 0) { return '[]' }
            return "[`n" + ($items -join ",`n") + "`n" + $end + ']'
        }
    }
    throw ('cannot serialize ' + $Value.GetType().FullName)
}

function ConvertTo-FloatSegment {
    <#
    .SYNOPSIS
      Plain copy of a segment for the float config: no colours, diamonds or caps.
    .DESCRIPTION
      statusline.ps1 builds the float line without colour and strips what is left;
      the wrapper strips the SGR codes Oh-My-Posh still writes for template markup.
    .PARAMETER Segment
      Segment from New-OmpSegment.
    .EXAMPLE
      ConvertTo-FloatSegment -Segment (New-OmpSegment $SegmentTemplates['model'])
    #>
    param($Segment)
    $plain = [ordered]@{ type = $Segment.type; style = 'plain' }
    foreach ($key in @('options', 'alias', 'template')) {
        if ($Segment.Contains($key)) { $plain[$key] = $Segment[$key] }
    }
    return $plain
}

function New-FloatConfig {
    <#
    .SYNOPSIS
      Float config: one block per VL_FLOAT_SEGMENTS token, each opened by its marker.
    .DESCRIPTION
      Block i starts with U+FDD0, the decimal i and U+FDD1, printed whether or not the
      segment itself shows, so statusline-omp.ps1 can require exactly N markers in
      order and cut the output into the per-token pieces statusline.ps1 trims and
      joins. A token without a template (an unknown name, clock under
      VL_CLOCK=off) keeps its block with the marker alone and comes out empty. No
      block sets newline: the wrapper refuses any output holding a line break.
    .EXAMPLE
      New-FloatConfig
    #>
    $open = [string][char]0xFDD0
    $close = [string][char]0xFDD1
    $tokens = @(Get-SegmentTokens ([string]$Cfg.VL_FLOAT_SEGMENTS))
    $floatBlocks = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $name = [string]$tokens[$i]
        $marker = $open + $i.ToString($Invariant) + $close
        $members = New-Object 'System.Collections.Generic.List[object]'
        switch ($true) {
            { $name -ceq 'project' } {
                [void]$members.Add((ConvertTo-FloatSegment (New-OmpSegment $SegmentTemplates['project'])))
                if (-not $dirListed) { [void]$members.Add((ConvertTo-FloatSegment (New-OmpSegment $SegmentTemplates['project-fallback']))) }
                break
            }
            { $name -ceq 'project-fallback' } { break }
            { $SegmentTemplates.Contains($name) } { [void]$members.Add((ConvertTo-FloatSegment (New-OmpSegment $SegmentTemplates[$name]))); break }
        }
        switch ($members.Count -eq 1 -and $members[0].type -ceq 'text') {
            # A text segment carries its marker in front of the template, outside any condition.
            $true { $members[0].template = $marker + $members[0].template }
            default { $members.Insert(0, [ordered]@{ type = 'text'; style = 'plain'; template = $marker }) }
        }
        [void]$floatBlocks.Add([ordered]@{ type = 'prompt'; alignment = 'left'; segments = $members.ToArray() })
    }
    return [ordered]@{
        '$schema' = 'https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json'
        version = 4
        var = [ordered]@{ CorallineGenerator = 'coralline-omp/1'; CorallineFloatCount = [int]$tokens.Count; CorallineFloatTokens = $tokens }
        blocks = $floatBlocks.ToArray()
    }
}

$text = (ConvertTo-CanonicalJson $config 0) + "`n"
if ([string]::IsNullOrEmpty($OutFile)) { [Console]::Out.Write($text) }
else { [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutFile), $text, $Utf8NoBom) }
if (-not [string]::IsNullOrEmpty($FloatOutFile)) {
    $floatText = (ConvertTo-CanonicalJson (New-FloatConfig) 0) + "`n"
    [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($FloatOutFile), $floatText, $Utf8NoBom)
}
