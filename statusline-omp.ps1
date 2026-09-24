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
  ctx and cost, the burn projection) travel as CORALLINE_OMP_* environment
  variables read by the config that tools/build-omp-config.ps1 generates.

  Failure handling:
  - stdin that is not a JSON object renders like statusline.ps1 does for it,
    from an empty payload.
  - If interpreting the payload fails, the raw stdin goes to Oh-My-Posh unchanged.
  - A config that does not parse or lacks the generator marker, a missing
    Oh-My-Posh, or an Oh-My-Posh failure prints an empty line. Oh-My-Posh would
    otherwise fall back to its own default layout without saying so.
  The exit status is always 0.

  burn and VL_LIMIT_SYNC: coralline.conf is loaded and coralline's burn / limit
  state layer (the TSV history and the limit directories) is run once per render,
  both extracted from statusline.ps1 unchanged. Under VL_LIMIT_SYNC=1 the payload's
  rate_limits windows are replaced by the synced ones, or removed where
  statusline.ps1 would hide the gauge; the burn projection goes to Oh-My-Posh as
  CORALLINE_OMP_BURN, CORALLINE_OMP_BURN_TONE and CORALLINE_OMP_BURN_ETA. If the
  state layer cannot be reused safely it is skipped: no store is read or written,
  burn hides, and under VL_LIMIT_SYNC=1 both limit gauges hide.

  VL_FLOAT: after the statusline is written, the float file is produced the way
  statusline.ps1 produces it. The float target and its collision checks and the
  atomic writer are coralline's own code, extracted from statusline.ps1 and
  evaluated on every render. The text comes from a second Oh-My-Posh call on the
  float config (tools/build-omp-config.ps1 -FloatOutFile), whose per-segment
  markers let this script trim and join the segments with VL_FLOAT_SEP. Any
  failure skips the float file silently.

.PARAMETER OmpExe
  oh-my-posh executable. Defaults to $env:CORALLINE_OMP_EXE, then PATH.

.PARAMETER Config
  Config written by tools/build-omp-config.ps1. Defaults to
  $env:CORALLINE_OMP_CONFIG, then coralline.omp.json in the coralline state folder.

.PARAMETER FloatConfig
  Float config written by tools/build-omp-config.ps1 -FloatOutFile. Defaults to
  $env:CORALLINE_OMP_FLOAT_CONFIG, then coralline.float.omp.json next to Config.

.PARAMETER Rest
  Every argument that is not one of the three named parameters above. A single
  '--subagent' (case-sensitive) hands the whole render to statusline.ps1's own
  --subagent mode, in the same process, unchanged: this script never renders
  subagent panels through Oh-My-Posh, because that mode emits one JSON-lines
  row per task and Oh-My-Posh's claude segment renders a single payload. Any
  other combination of extra arguments (wrong case, an extra token, a bare
  positional value) is not a supported call shape; this script prints an
  empty line and exits 0, same as an unrecognised call always has.

.EXAMPLE
  Get-Content -Raw .\test\sample-input.json | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\statusline-omp.ps1

.EXAMPLE
  Get-Content -Raw .\test\sample-subagent-input.json | powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\statusline-omp.ps1 --subagent
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$OmpExe = '',
    [string]$Config = '',
    [string]$FloatConfig = '',
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Rest
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
$GeneratorPath = [System.IO.Path]::Combine($Here, 'tools', 'build-omp-config.ps1')
$script:StatuslineAst = $null
$Stdout = [Console]::OpenStandardOutput()

# ---- --subagent: hand the whole render to statusline.ps1, in this same process --------
# Must run before stdin is read, before the config is loaded, before any Oh-My-Posh
# parsing: statusline.ps1's --subagent mode reads stdin and writes stdout itself, and
# this script must not consume or transform any of those bytes.
if ($Rest.Count -eq 1 -and $Rest[0] -ceq '--subagent') {
    try { & $StatuslinePath '--subagent' } catch { }
    exit 0
}
if ($Rest.Count -gt 0) {
    # Any other extra-argument shape (wrong case, an extra token, a bare value) is not
    # a supported call: same empty-line, exit-0 fallback as every other unrecognised case.
    # Write-Bytes is defined further down the script, so this writes the bytes directly.
    $blank = [byte[]](10)
    $Stdout.Write($blank, 0, $blank.Length)
    $Stdout.Flush()
    exit 0
}

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

function Get-FloatConfigPath {
    <#
    .SYNOPSIS
      The float config this render uses: the parameter, then CORALLINE_OMP_FLOAT_CONFIG, then coralline.float.omp.json next to the main config.
    .DESCRIPTION
      Resolved once per render, before the state layer runs, because the float
      config is one of the files no state path may point at, whether or not
      VL_FLOAT is on. Returns '' when the default cannot be derived.
    .PARAMETER MainConfig
      Validated main config.
    .PARAMETER FloatConfigPath
      The -FloatConfig parameter, possibly empty.
    .EXAMPLE
      Get-FloatConfigPath -MainConfig .\coralline.omp.json -FloatConfigPath ''
    #>
    param([string]$MainConfig, [string]$FloatConfigPath)
    if ([string]::IsNullOrEmpty($FloatConfigPath)) { $FloatConfigPath = [string]$env:CORALLINE_OMP_FLOAT_CONFIG }
    if ([string]::IsNullOrEmpty($FloatConfigPath)) {
        try {
            $FloatConfigPath = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($MainConfig)), 'coralline.float.omp.json')
        } catch { $FloatConfigPath = '' }
    }
    return $FloatConfigPath
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

function Test-NoExitCode {
    <#
    .SYNOPSIS
      True when none of the given AST nodes holds an exit statement or an [Environment]::Exit call.
    .DESCRIPTION
      Extracted statusline.ps1 code runs inside this process under SilentlyContinue,
      which suppresses errors but not an exit: one would end the render before the
      statusline is written. Code that could exit is therefore never run.
    .PARAMETER Nodes
      Function definitions or statements taken from statusline.ps1.
    .EXAMPLE
      Test-NoExitCode -Nodes @($definition)
    #>
    param([object[]]$Nodes)
    try {
        $clean = 0
        foreach ($node in $Nodes) {
            $exitNode = $node.Find({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
            $callsExit = [regex]::IsMatch([string]$node.Extent.Text, '\[\s*(System\s*\.\s*)?Environment\s*\]\s*::\s*Exit', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($null -eq $exitNode -and -not $callsExit) { $clean++ }
        }
        return ($clean -eq @($Nodes).Count)
    } catch { return $false }
}

function Select-StatuslineFunctions {
    <#
    .SYNOPSIS
      The statusline.ps1 function definitions with the given names, or $null.
    .DESCRIPTION
      Every name must be defined exactly once in the whole file (a second
      definition, in any case spelling or nested anywhere, would make it ambiguous
      which one statusline.ps1 actually runs), that one definition must be a
      direct statement of the script body (one inside a function or an if is not
      what statusline.ps1 defines when it starts), and no definition may exit. Any
      failure returns $null, never a partial list.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Names
      Function names.
    .EXAMPLE
      Select-StatuslineFunctions -Ast (Get-StatuslineAst) -Names @('Format-Eta')
    #>
    param($Ast, [string[]]$Names)
    try {
        $everywhere = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $selected = New-Object 'System.Collections.Generic.List[object]'
        foreach ($name in $Names) {
            $matching = @($everywhere | Where-Object { $_.Name -eq $name })
            if ($matching.Count -ne 1) { return $null }
            if (-not [object]::ReferenceEquals($matching[0].Parent, $Ast.EndBlock)) { return $null }
            [void]$selected.Add($matching[0])
        }
        if (-not (Test-NoExitCode $selected.ToArray())) { return $null }
        return , $selected.ToArray()
    } catch { return $null }
}

function Get-StatuslineConfigCode {
    <#
    .SYNOPSIS
      statusline.ps1's defaults and config-loading statements, as two script texts, or $null.
    .DESCRIPTION
      Located by their opening text:
        Defaults  after `$HomeDir = [string]$HOME` to the $ConfigKeys loop, without
                  the two $HomeDir statements (Get-StatuslineHomeBinding binds
                  them) and without $ScriptDir and $ScriptPath, which describe
                  statusline.ps1 and are set by the caller;
        Config    from `$Cfg = Copy-Config $Defaults` to the Remove-ControlChars pass.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .EXAMPLE
      Get-StatuslineConfigCode -Ast (Get-StatuslineAst)
    #>
    param($Ast)
    try {
        $defaultsCode = New-Object System.Text.StringBuilder
        $configCode = New-Object System.Text.StringBuilder
        $nodes = New-Object 'System.Collections.Generic.List[object]'
        $stage = 0
        $homeFallback = "if ([string]::IsNullOrEmpty(`$HomeDir)) { `$HomeDir = [Environment]::GetFolderPath('UserProfile') }"
        foreach ($statement in $Ast.EndBlock.Statements) {
            $text = $statement.Extent.Text
            switch ($stage) {
                0 {
                    if ($text.StartsWith('$HomeDir = [string]$HOME', [System.StringComparison]::Ordinal)) { $stage = 1 }
                    break
                }
                1 {
                    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                    if ([string]::Equals($text, $homeFallback, [System.StringComparison]::Ordinal)) { break }
                    if ($text.StartsWith('$ScriptDir = ', [System.StringComparison]::Ordinal) -or $text.StartsWith('$ScriptPath = ', [System.StringComparison]::Ordinal)) { break }
                    [void]$defaultsCode.AppendLine($text)
                    [void]$nodes.Add($statement)
                    if ($text.StartsWith('foreach ($key in $Defaults.Keys)', [System.StringComparison]::Ordinal)) { $stage = 2 }
                    break
                }
                2 {
                    if ($text.StartsWith('$Cfg = Copy-Config $Defaults', [System.StringComparison]::Ordinal)) { $stage = 3; [void]$configCode.AppendLine($text); [void]$nodes.Add($statement) }
                    break
                }
                3 {
                    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { break }
                    [void]$configCode.AppendLine($text)
                    [void]$nodes.Add($statement)
                    if ($text.StartsWith('foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars', [System.StringComparison]::Ordinal)) { $stage = 4 }
                    break
                }
            }
            if ($stage -eq 4) { break }
        }
        if ($stage -ne 4 -or -not (Test-NoExitCode $nodes.ToArray())) { return $null }
        return @{ Defaults = $defaultsCode.ToString(); Config = $configCode.ToString() }
    } catch { return $null }
}

function Select-StatuslineStatements {
    <#
    .SYNOPSIS
      Consecutive script-level statements of statusline.ps1 matched against a fixed list of openings, as one script text, or $null.
    .DESCRIPTION
      The first statement opening with Starts[0] anchors the run; statement k after
      it must open with Starts[k]. A missing, renamed or inserted statement returns
      $null rather than running a different sequence, and so does any exit.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Starts
      Expected opening text of each statement, in order.
    .EXAMPLE
      Select-StatuslineStatements -Ast (Get-StatuslineAst) -Starts @('$State = $null')
    #>
    param($Ast, [string[]]$Starts)
    try {
        $statements = $Ast.EndBlock.Statements
        $first = -1
        for ($i = 0; $i -lt $statements.Count; $i++) {
            if ($statements[$i].Extent.Text.StartsWith($Starts[0], [System.StringComparison]::Ordinal)) { $first = $i; break }
        }
        if ($first -lt 0 -or $first + $Starts.Count -gt $statements.Count) { return $null }
        $code = New-Object System.Text.StringBuilder
        $nodes = New-Object 'System.Collections.Generic.List[object]'
        $matched = 0
        for ($k = 0; $k -lt $Starts.Count; $k++) {
            $statement = $statements[$first + $k]
            if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            if (-not $statement.Extent.Text.StartsWith($Starts[$k], [System.StringComparison]::Ordinal)) { continue }
            [void]$code.AppendLine($statement.Extent.Text)
            [void]$nodes.Add($statement)
            $matched++
        }
        if ($matched -ne $Starts.Count -or -not (Test-NoExitCode $nodes.ToArray())) { return $null }
        return $code.ToString()
    } catch { return $null }
}

function Get-AstVariableName {
    <#
    .SYNOPSIS
      A variable's name without its scope or drive qualifier.
    .DESCRIPTION
      $script:X, $global:X, $local:X, $private:X, $using:X and ${variable:X} all name X.
      Other drives ($env:X) keep their prefix, so they never equal a plain name.
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
      Counted conservatively, so that anything which could rebind the variable
      makes a binding ambiguous:
        - the variable anywhere on the left of an assignment of any operator, at
          any depth, with or without a scope qualifier or type constraint;
        - a foreach loop variable;
        - a [ref] conversion of it;
        - a Set-Variable, New-Variable, Clear-Variable or Remove-Variable call
          (or alias) that names it;
        - a command naming it as the value of -OutVariable, -ErrorVariable,
          -WarningVariable, -InformationVariable or -PipelineVariable, in any
          abbreviation or alias;
        - a variable:<name> path, and a .Set(<name>, ...) call.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Name
      Variable name without $.
    .EXAMPLE
      Get-StatuslineWriteCount -Ast (Get-StatuslineAst) -Name 'Latin1'
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
      Script text of the one script-level assignment that gives a statusline.ps1 variable its value, or $null.
    .DESCRIPTION
      The assignment must be a direct statement of the script body, operator =,
      with the unqualified variable alone on the left. The variable may be written
      nowhere else in the file (Get-StatuslineWriteCount must be exactly 1). The
      right side may hold no variable other than $true, $false and $null, no
      command, no $( ), no script block and no nested assignment, and nothing may
      exit. The caller clears the variable in its own scope and runs the text there.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .PARAMETER Name
      Variable name without $.
    .EXAMPLE
      Get-StatuslineBinding -Ast (Get-StatuslineAst) -Name 'ShellWordStops'
    #>
    param($Ast, [string]$Name)
    try {
        if ((Get-StatuslineWriteCount $Ast $Name) -ne 1) { return $null }
        $source = $null
        foreach ($statement in $Ast.EndBlock.Statements) {
            if ($statement -isnot [System.Management.Automation.Language.AssignmentStatementAst]) { continue }
            if ($statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
            if ($statement.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if (-not $statement.Left.VariablePath.IsUnqualified) { continue }
            if ([string]::Equals((Get-AstVariableName $statement.Left), $Name, [System.StringComparison]::OrdinalIgnoreCase)) { $source = $statement }
        }
        if ($null -eq $source) { return $null }
        $forbidden = $source.Right.Find({
                param($n)
                ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and @('true', 'false', 'null') -notcontains [string]$n.VariablePath.UserPath) -or
                $n -is [System.Management.Automation.Language.CommandAst] -or
                $n -is [System.Management.Automation.Language.SubExpressionAst] -or
                $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
                $n -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true)
        if ($null -ne $forbidden) { return $null }
        if (-not (Test-NoExitCode @($source))) { return $null }
        return [string]$source.Extent.Text + "`n"
    } catch { return $null }
}

function Get-StatuslineHomeBinding {
    <#
    .SYNOPSIS
      statusline.ps1's two $HomeDir statements as script text, or $null.
    .DESCRIPTION
      The one exception to Get-StatuslineBinding's rules, and only for this pair:
      each statement must appear exactly once in the script body with exactly
      this text (ordinal), the second directly after the first, and nothing else
      in the file may write $HomeDir.
    .PARAMETER Ast
      Parsed statusline.ps1.
    .EXAMPLE
      Get-StatuslineHomeBinding -Ast (Get-StatuslineAst)
    #>
    param($Ast)
    try {
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
        if ($assignCount -ne 1 -or $fallbackCount -ne 1 -or ($assignAt + 1) -ge $statements.Count) { return $null }
        if (-not [string]::Equals([string]$statements[$assignAt + 1].Extent.Text, $fallbackText, [System.StringComparison]::Ordinal)) { return $null }
        if ((Get-StatuslineWriteCount $Ast 'HomeDir') -ne 2) { return $null }
        if (-not (Test-NoExitCode @($statements[$assignAt], $statements[$assignAt + 1]))) { return $null }
        return $assignText + "`n" + $fallbackText + "`n"
    } catch { return $null }
}

function Test-OmpShellCanary {
    <#
    .SYNOPSIS
      True when statusline.ps1's Decode-ShellWord, already defined by the caller, decodes a fixed word to the expected value.
    .DESCRIPTION
      Checks what the bound quoting tables actually do, not just their type. Any
      failure, including Decode-ShellWord being absent, returns $false. Local names
      carry an omp prefix so the decoder cannot pick them up through dynamic scope.
    .PARAMETER OmpWord
      Config value text.
    .PARAMETER OmpWant
      Expected decoded value.
    .EXAMPLE
      Test-OmpShellCanary -OmpWord "'x y'" -OmpWant 'x y'
    #>
    param([string]$OmpWord, [string]$OmpWant)
    try {
        $ompDecoded = Decode-ShellWord $OmpWord $false
        return ($ompDecoded.Success -eq $true -and [string]::Equals([string]$ompDecoded.Value, $OmpWant, [System.StringComparison]::Ordinal))
    } catch { return $false }
}

function Get-OmpEnvironment {
    <#
    .SYNOPSIS
      Interpret the payload with coralline's own code and build the Oh-My-Posh input.
    .DESCRIPTION
      Returns @{ Payload = <ordered map>; Env = <name -> value>; FhPct; FhRst; WdPct;
      WdRst }, the last four being statusline.ps1's own rate-limit strings for the
      state layer, or $null when statusline.ps1 cannot supply the parsing code; the
      caller then passes the raw stdin through. It must not run inside try/catch:
      statusline.ps1 relies on a failing statement being skipped under
      SilentlyContinue, and an enclosing catch would abort the whole interpretation
      instead.
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
    # The state layer reads these four strings; keep them before $Cfg is stubbed below.
    $rateStrings = @{ FhPct = [string]$fhPct; FhRst = [string]$fhRst; WdPct = [string]$wdPct; WdRst = [string]$wdRst }

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
    return @{ Payload = $payload; Env = $envMap; FhPct = $rateStrings.FhPct; FhRst = $rateStrings.FhRst; WdPct = $rateStrings.WdPct; WdRst = $rateStrings.WdRst }
}

function Get-OmpState {
    <#
    .SYNOPSIS
      Load coralline.conf and run coralline's burn and limit state layer once; returns plain values for the payload, the environment and the float file.
    .DESCRIPTION
      Everything statusline.ps1-specific is extracted from it through the AST and
      run in this function's scope, under a local SilentlyContinue exactly as
      statusline.ps1 runs it, and never inside try/catch (an enclosing catch would
      abort the chain where statusline.ps1 skips one statement):
        1. the config helpers; $HomeDir and the three quoting tables, each bound
           from its one statusline.ps1 statement and checked by type and by
           decoding a fixed word per quoting context; the defaults and the
           config-loading statements; then the wrapper's own files are appended to
           $ConfigVisitedPaths, so no state path (and no float target) may point at
           them;
        2. the state-layer functions and Format-Eta, each defined exactly once, and
           the gate statements, matched one by one against a fixed list; the burn
           reader's row pattern, long-record pattern and Latin-1 encoding, bound
           the same way and checked by what they match and decode;
        3. a check of every free variable the state layer reads;
        4. the gates and Get-CorallineState, which reads and writes the stores.
      A failure in 1 returns $null. A failure in 2 or 3 leaves the stores alone and
      reports no state. Only the wrapper's own post-processing after 4 (the burn
      values and the synced windows) runs inside try; if it fails, burn and, under
      VL_LIMIT_SYNC=1, both limit windows are reported absent.

      The result holds only strings, booleans, longs and string lists:
        Cfg (the float keys of the loaded config), ConfigPath, ConfigVisitedPaths,
        FloatFileRootAuthorized, HomeDir, ScriptDir; LimitSync, FiveShow, FivePct,
        FiveReset, SevenShow, SevenPct, SevenReset; Burn, BurnTone, BurnEta.
    .PARAMETER FiveHourPct
      statusline.ps1's $fhPct for this payload.
    .PARAMETER FiveHourReset
      statusline.ps1's $fhRst.
    .PARAMETER SevenDayPct
      statusline.ps1's $wdPct.
    .PARAMETER SevenDayReset
      statusline.ps1's $wdRst.
    .PARAMETER MainConfig
      Main Oh-My-Posh config of this render.
    .PARAMETER FloatConfigPath
      Float Oh-My-Posh config of this render.
    .PARAMETER ExePath
      Oh-My-Posh executable of this render.
    .EXAMPLE
      Get-OmpState -FiveHourPct '40' -FiveHourReset '1790009030' -SevenDayPct '' -SevenDayReset '' -MainConfig .\coralline.omp.json -FloatConfigPath .\coralline.float.omp.json -ExePath .\oh-my-posh.exe
    #>
    param([string]$FiveHourPct, [string]$FiveHourReset, [string]$SevenDayPct, [string]$SevenDayReset,
        [string]$MainConfig, [string]$FloatConfigPath, [string]$ExePath)
    # Local names carry an omp prefix: the extracted code resolves free variables
    # dynamically, and none of its own names may be shadowed from here.
    $ompAst = Get-StatuslineAst
    if ($null -eq $ompAst) { return $null }
    $ErrorActionPreference = 'SilentlyContinue'

    # ---- 1. config ----------------------------------------------------------------
    $ompConfigNames = @('Glyph', 'Remove-ControlChars', 'Copy-Config', 'Add-Utf8Text', 'Read-WordChar', 'Decode-ShellWord',
        'Add-Utf8Run', 'Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath', 'Test-PathInside',
        'Test-NoReparseComponents', 'Test-SafeRegularFile', 'Read-StrictUtf8File', 'Import-ConfigFile',
        'Get-BoundedInt', 'Test-Color', 'Get-SegmentTokens')
    $ompConfigDefinitions = Select-StatuslineFunctions $ompAst $ompConfigNames
    $ompConfigCode = Get-StatuslineConfigCode $ompAst
    if ($null -eq $ompConfigDefinitions -or $null -eq $ompConfigCode) { return $null }
    foreach ($ompDefinition in $ompConfigDefinitions) { . ([scriptblock]::Create($ompDefinition.Extent.Text)) }
    $ompDefined = 0
    foreach ($ompName in $ompConfigNames) { if (Get-Command -Name $ompName -CommandType Function -ErrorAction SilentlyContinue) { $ompDefined++ } }
    if ($ompDefined -ne $ompConfigNames.Count) { return $null }

    # Script-level values the config helpers read, bound from statusline.ps1's own
    # statements: $HomeDir from its fixed two-statement pair, and the quoting tables
    # Decode-ShellWord scans with from their single constant assignment each. A
    # binding that is missing, ambiguous or not a constant stays $null here.
    $ompHomeCode = Get-StatuslineHomeBinding $ompAst
    $HomeDir = $null
    if ($null -ne $ompHomeCode) { . ([scriptblock]::Create($ompHomeCode)) }
    foreach ($ompName in @('ShellWordStops', 'ShellDoubleQuoteStops', 'ShellAnsiQuoteStops')) {
        $ompBindingCode = Get-StatuslineBinding $ompAst $ompName
        Set-Variable -Name $ompName -Value $null
        if ($null -ne $ompBindingCode) { . ([scriptblock]::Create($ompBindingCode)) }
    }
    # A statement that throws here is skipped and leaves its entry absent, which
    # counts as a failure: every check below fails closed.
    $ompBindingOk = @{}
    $ompBindingOk.HomeDir = ($HomeDir -is [string] -and $HomeDir.Length -gt 0)
    $ompBindingOk.ShellWordStops = ($ShellWordStops -is [char[]] -and $ShellWordStops.Length -gt 0)
    $ompBindingOk.ShellDoubleQuoteStops = ($ShellDoubleQuoteStops -is [char[]] -and $ShellDoubleQuoteStops.Length -gt 0)
    $ompBindingOk.ShellAnsiQuoteStops = ($ShellAnsiQuoteStops -is [char[]] -and $ShellAnsiQuoteStops.Length -gt 0)
    $ompBound = 0
    foreach ($ompName in @('HomeDir', 'ShellWordStops', 'ShellDoubleQuoteStops', 'ShellAnsiQuoteStops')) { if ($ompBindingOk[$ompName] -eq $true) { $ompBound++ } }
    if ($ompBound -ne 4) { return $null }
    # What the tables do, not only their type: one word per quoting context.
    $ompCanaryOk = @{}
    $ompCanaryOk.Bare = (Test-OmpShellCanary 'abc  # note' 'abc')
    $ompCanaryOk.DoubleQuote = (Test-OmpShellCanary '"a b\"c"' 'a b"c')
    $ompCanaryOk.AnsiQuote = (Test-OmpShellCanary "`$'a\tb'" "a`tb")
    $ompCanaryOk.SingleQuote = (Test-OmpShellCanary "'x y'" 'x y')
    $ompBound = 0
    foreach ($ompName in @('Bare', 'DoubleQuote', 'AnsiQuote', 'SingleQuote')) { if ($ompCanaryOk[$ompName] -eq $true) { $ompBound++ } }
    if ($ompBound -ne 4) { return $null }

    $visited = $null
    . ([scriptblock]::Create([string]$ompConfigCode.Defaults))
    # The native script's own folder and path, not this wrapper's: $ScriptDir roots
    # the approved themes folder, and $ScriptPath is the free variable the state and
    # float collision checks read to protect statusline.ps1.
    $ScriptDir = Split-Path -Path $StatuslinePath -Parent
    $ScriptPath = $StatuslinePath
    . ([scriptblock]::Create([string]$ompConfigCode.Config))
    # The wrapper's own files join the paths statusline.ps1 already protects. Only the
    # state collision check (Get-CorallineState) and Test-FloatCollision read this
    # array, so appending can only add collisions. Each path goes in as given and as
    # the full path a state path resolves to. The HashSet $visited, which
    # Import-ConfigFile uses for include cycles, is left alone.
    if ($ConfigVisitedPaths -is [array]) {
        foreach ($ompProtected in @($WrapperPath, $GeneratorPath, $MainConfig, $FloatConfigPath, $ExePath)) {
            if ([string]::IsNullOrEmpty([string]$ompProtected)) { continue }
            $ConfigVisitedPaths += [string]$ompProtected
            $ompFull = ConvertTo-LocalFullPath ([string]$ompProtected) ([Environment]::CurrentDirectory)
            if (-not [string]::IsNullOrEmpty($ompFull)) { $ConfigVisitedPaths += [string]$ompFull }
        }
    }

    $ompFloatCfg = [ordered]@{}
    foreach ($ompKey in @('VL_FLOAT', 'VL_FLOAT_SEGMENTS', 'VL_FLOAT_SEP', 'VL_FLOAT_FILE', 'BURN_FILE', 'RL5H_FILE', 'RL7D_FILE')) { $ompFloatCfg[$ompKey] = [string]$Cfg[$ompKey] }
    $ompVisited = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ompPath in @($ConfigVisitedPaths)) { if (-not [string]::IsNullOrEmpty([string]$ompPath)) { [void]$ompVisited.Add([string]$ompPath) } }
    $ompResult = @{
        Cfg = $ompFloatCfg; ConfigPath = [string]$ConfigPath; ConfigVisitedPaths = $ompVisited.ToArray()
        FloatFileRootAuthorized = ($FloatFileRootAuthorized -eq $true); HomeDir = [string]$HomeDir; ScriptDir = [string]$ScriptDir
        LimitSync = $false; FiveShow = $false; FivePct = 0L; FiveReset = 0L; SevenShow = $false; SevenPct = 0L; SevenReset = 0L
        Burn = ''; BurnTone = ''; BurnEta = ''
    }
    if ([string]$Cfg.VL_LIMIT_SYNC -eq '1') { $ompResult.LimitSync = $true }

    # ---- 2. state layer and gates ------------------------------------------------------
    $ompStateNames = @('ConvertTo-Epoch', 'Try-BoundedDouble', 'Get-BoundedInt', 'ConvertTo-LocalFullPath', 'Test-LocalPathSyntax',
        'Test-DosDeviceComponent', 'Test-PathInside', 'Test-NoReparseComponents',
        'ConvertTo-StatePct', 'ConvertTo-StateEpoch', 'ConvertTo-StatePayloadEpoch', 'Get-RoundEvenInt64', 'Format-StateRate',
        'Format-StatePct', 'Format-BurnPct', 'Get-StatePaths', 'Test-StateRoot', 'Test-StateRegularFile',
        'Get-EmptyStateDirectoryStatus', 'Test-EmptyStateDirectory', 'Test-StateObjectExists', 'ConvertFrom-CanonicalStatePct',
        'ConvertFrom-LimitName', 'Get-StateDirectorySnapshot', 'Remove-BurnTemporaries',
        'Write-BurnState', 'Read-BurnState', 'Append-BurnState', 'Sort-StateEntries', 'Get-LimitRetention',
        'Test-LimitDeleteCandidate', 'Remove-StateCandidates', 'Get-CurrentLimit', 'Select-LimitResult', 'Publish-LimitState',
        'Get-Burn5Estimate', 'Get-Burn7Estimate', 'Get-BurnBinding', 'Get-CorallineState', 'Format-Eta')
    $ompGateStarts = @('$MainSegmentNames = ', '$MainSegmentLists = ', 'foreach ($list in $MainSegmentLists)',
        '$FloatSegmentNames = ', '$FloatTokens = ', '$FloatEnabled = ', 'if ($FloatEnabled)', '$ProbeSegmentNames = ',
        'foreach ($name in $MainSegmentNames)', 'foreach ($name in $FloatSegmentNames)', '$AllStatePaths = ',
        'foreach ($base in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE))', '$BurnStateGate = ', '$Limit5StateGate = ',
        '$Limit7StateGate = ', '$State = $null', 'if ($BurnStateGate -or $Limit5StateGate -or $Limit7StateGate)')
    $ompStateDefinitions = Select-StatuslineFunctions $ompAst $ompStateNames
    $ompGateCode = Select-StatuslineStatements $ompAst $ompGateStarts
    $ompReady = $false
    if ($null -ne $ompStateDefinitions -and $null -ne $ompGateCode) { $ompReady = $true }
    if ($ompReady) {
        foreach ($ompDefinition in $ompStateDefinitions) {
            if ($ompConfigNames -notcontains $ompDefinition.Name) { . ([scriptblock]::Create($ompDefinition.Extent.Text)) }
        }
        $ompDefined = 0
        foreach ($ompName in $ompStateNames) { if (Get-Command -Name $ompName -CommandType Function -ErrorAction SilentlyContinue) { $ompDefined++ } }
        if ($ompDefined -ne $ompStateNames.Count) { $ompReady = $false }
    }
    # The burn reader's script-level pattern and encoding, bound like the quoting
    # tables above, then checked for what they match and decode.
    foreach ($ompName in @('BurnRowPattern', 'BurnLongRecordPattern', 'Latin1')) {
        $ompBindingCode = Get-StatuslineBinding $ompAst $ompName
        Set-Variable -Name $ompName -Value $null
        if ($null -ne $ompBindingCode) { . ([scriptblock]::Create($ompBindingCode)) }
    }
    $ompStateOk = @{}
    $ompStateOk.BurnRowPattern = ($BurnRowPattern -is [regex] -and $BurnRowPattern.IsMatch("1700000000`t12.345`t1700003600") -eq $true -and $BurnRowPattern.IsMatch('x') -eq $false)
    $ompStateOk.BurnLongRecordPattern = ($BurnLongRecordPattern -is [regex] -and $BurnLongRecordPattern.IsMatch([string]::new([char]'a', 4097)) -eq $true -and $BurnLongRecordPattern.IsMatch([string]::new([char]'a', 4096)) -eq $false)
    $ompStateOk.Latin1 = ($Latin1 -is [System.Text.Encoding] -and $Latin1.CodePage -eq 28591)
    $ompBound = 0
    foreach ($ompName in @('BurnRowPattern', 'BurnLongRecordPattern', 'Latin1')) { if ($ompStateOk[$ompName] -eq $true) { $ompBound++ } }
    if ($ompBound -ne 3) { $ompReady = $false }

    # ---- 3. free variables the state layer reads ---------------------------------------
    # $fhPct and friends are statusline.ps1's own rate-limit strings for this payload.
    $fhPct = $FiveHourPct
    $fhRst = $FiveHourReset
    $wdPct = $SevenDayPct
    $wdRst = $SevenDayReset
    $ompGuard = 0
    if ($Now -is [long] -and $Now -gt 1700000000L) { $ompGuard++ }
    if ($ScriptPath -is [string] -and [string]::Equals($ScriptPath, $StatuslinePath, [System.StringComparison]::Ordinal) -and [System.IO.File]::Exists($ScriptPath)) { $ompGuard++ }
    if ($Cfg -is [System.Collections.IDictionary] -and $Cfg.Contains('BURN_FILE') -and $Cfg.Contains('RL5H_FILE') -and $Cfg.Contains('RL7D_FILE') -and $Cfg.Contains('VL_LIMIT_SYNC') -and $Cfg.Contains('BURN_SLACK')) { $ompGuard++ }
    if ($ConfigVisitedPaths -is [array]) { $ompGuard++ }
    if ($null -ne $Invariant -and $null -ne $IntegerStyle -and $null -ne $FloatStyle -and $null -ne $Utf8NoBom -and $null -ne $StrictUtf8) { $ompGuard++ }
    if ($ompGuard -ne 5) { $ompReady = $false }

    # ---- 4. gates and Get-CorallineState: statusline.ps1's own statements ---------------
    $ompRan = $false
    if ($ompReady) {
        . ([scriptblock]::Create([string]$ompGateCode))
        $ompRan = $true
    }

    # ---- wrapper post-processing: burn values and the synced windows --------------------
    try {
        if ($ompRan -and $null -ne $State -and $State -isnot [System.Collections.IDictionary]) {
            if ($ompResult.LimitSync) {
                # Add-Limit5Segment / Add-Limit7Segment under VL_LIMIT_SYNC=1.
                switch ($true) {
                    ($State.Limit5.Valid -eq $true) { $ompResult.FiveShow = $true; $ompResult.FivePct = [long](Get-RoundEvenInt64 ([long]$State.Limit5.Pct) 1000L); $ompResult.FiveReset = [long]$State.Limit5.Reset; break }
                    ($State.Current5.Elapsed -eq $true) { $ompResult.FiveShow = $true; $ompResult.FivePct = [long](Get-RoundEvenInt64 ([long]$State.Current5.ElapsedPct) 1000L); $ompResult.FiveReset = [long]$State.Current5.ElapsedReset; break }
                }
                switch ($true) {
                    ($State.Limit7.Valid -eq $true) { $ompResult.SevenShow = $true; $ompResult.SevenPct = [long](Get-RoundEvenInt64 ([long]$State.Limit7.Pct) 1000L); $ompResult.SevenReset = [long]$State.Limit7.Reset; break }
                    ($State.Current7.Elapsed -eq $true) { $ompResult.SevenShow = $true; $ompResult.SevenPct = [long](Get-RoundEvenInt64 ([long]$State.Current7.ElapsedPct) 1000L); $ompResult.SevenReset = [long]$State.Current7.ElapsedReset; break }
                }
            }
            # Add-BurnSegment.
            if ($State.Burn.Reported -eq $true) {
                $ompBurn = ''
                $ompTone = ''
                $ompEta = ''
                switch ([string]$State.Burn.State) {
                    'active' {
                        $ompWindow = 604800L
                        if ([string]$State.Burn.Label -eq '5h') { $ompWindow = 18000L }
                        $ompEtaSeconds = [long]$State.Burn.Eta
                        $ompTtr = [long]$State.Burn.Ttr
                        switch ($true) {
                            ($ompEtaSeconds -gt $ompWindow) { $ompBurn = 'done'; $ompTone = 'ok'; break }
                            ($ompEtaSeconds -le $ompTtr) { $ompBurn = 'active'; $ompTone = 'hot'; break }
                            ((10L * $ompTtr) -ge (8L * $ompEtaSeconds)) { $ompBurn = 'active'; $ompTone = 'warn'; break }
                            default { $ompBurn = 'active'; $ompTone = 'ok' }
                        }
                        if ($ompBurn -eq 'active') { $ompEta = [string]$State.Burn.Label + ' ' + [string](Format-Eta $ompEtaSeconds) }
                    }
                    'warming' { $ompBurn = 'warming'; $ompTone = 'dim' }
                    default { $ompBurn = 'idle'; $ompTone = 'dim' }
                }
                # Only these exact shapes reach Oh-My-Posh; anything else shows no burn.
                $ompValid = @('warming', 'idle', 'done', 'active') -ccontains $ompBurn -and @('dim', 'ok', 'warn', 'hot') -ccontains $ompTone
                switch ($ompBurn) {
                    'active' { $ompValid = $ompValid -and $ompEta -cmatch '\A(5h|7d) [0-9]+(d[0-9]{2}h|h[0-9]{2}m|m)\z' }
                    default { $ompValid = $ompValid -and $ompEta -eq '' }
                }
                if ($ompValid) {
                    $ompResult.Burn = $ompBurn
                    $ompResult.BurnTone = $ompTone
                    $ompResult.BurnEta = $ompEta
                }
            }
        }
    } catch {
        $ompResult.FiveShow = $false
        $ompResult.SevenShow = $false
        $ompResult.Burn = ''
        $ompResult.BurnTone = ''
        $ompResult.BurnEta = ''
    }
    return $ompResult
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
      The config comes from Get-OmpState, loaded once for this render, so relative
      VL_FLOAT_FILE values follow the current directory of this render exactly as
      they do natively. coralline's float target resolution, collision check, text
      check and atomic writer are extracted from statusline.ps1 unchanged and
      evaluated here. On top of statusline.ps1's own collision set, the target may
      not be statusline.ps1, this script, the generator, either Oh-My-Posh config or
      the Oh-My-Posh executable.

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
      Float config from Get-FloatConfigPath.
    .PARAMETER Payload
      The stdin bytes the main render received.
    .PARAMETER Environment
      The CORALLINE_OMP_* flags the main render received.
    .PARAMETER Context
      Result of Get-OmpState; without one no float file is written.
    .EXAMPLE
      Invoke-OmpFloat -ExePath $OmpExe -MainConfig $Config -FloatConfigPath $FloatConfig -Payload $payloadBytes -Environment $envMap -Context $ompState
    #>
    param([string]$ExePath, [string]$MainConfig, [string]$FloatConfigPath, [byte[]]$Payload, $Environment, $Context)
    if ($null -eq $Context -or $Context.Cfg -isnot [System.Collections.IDictionary]) { return }
    $ast = Get-StatuslineAst
    if ($null -eq $ast) { return }

    # Every function the float path reaches, including transitive helpers. A missing
    # one skips the float file instead of failing inside the chain.
    $names = @('Test-DosDeviceComponent', 'Test-LocalPathSyntax', 'ConvertTo-LocalFullPath', 'Test-NoReparseComponents',
        'Test-SafeRegularFile', 'Get-SegmentTokens', 'Get-StatePaths', 'Test-StateObjectExists',
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
    # $FloatTokens, $FloatEnabled and the $AllStatePaths derivation.
    $statements = $ast.EndBlock.Statements
    $floatCode = New-Object System.Text.StringBuilder
    $floatStarts = @('$FloatTokens = ', '$FloatEnabled = ', '$AllStatePaths = ', 'foreach ($base in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE))')
    $floatFound = 0
    foreach ($statement in $statements) {
        $text = $statement.Extent.Text
        if ($floatFound -lt $floatStarts.Count -and $text.StartsWith($floatStarts[$floatFound], [System.StringComparison]::Ordinal)) {
            [void]$floatCode.AppendLine($text)
            $floatFound++
        }
    }
    if ($floatFound -ne $floatStarts.Count) { return }

    # statusline.ps1 runs under SilentlyContinue; the caller's catch still ends the
    # float path on anything that would otherwise terminate a statement.
    $ErrorActionPreference = 'SilentlyContinue'
    # The free variables of the extracted float code, from the config Get-OmpState
    # loaded for this render. $ConfigVisitedPaths already holds the wrapper's files.
    $Cfg = $Context.Cfg
    $ConfigPath = [string]$Context.ConfigPath
    $ConfigVisitedPaths = @($Context.ConfigVisitedPaths)
    $FloatFileRootAuthorized = ($Context.FloatFileRootAuthorized -eq $true)
    # The native script's path, not this wrapper's: $ScriptPath is the free variable
    # Test-FloatCollision reads to protect statusline.ps1.
    $ScriptPath = $StatuslinePath
    . ([scriptblock]::Create($floatCode.ToString()))
    if ($FloatEnabled -ne $true) { return }
    $target = Get-FloatTarget
    if ([string]::IsNullOrEmpty($target)) { return }

    # Explicit collision set, independent of $ScriptPath above.
    $protected = @($StatuslinePath, $WrapperPath, $GeneratorPath, $MainConfig, $FloatConfigPath, $ExePath)
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

# ---- the render's one clock sample, taken after stdin as statusline.ps1 takes it -----
# A slow stdin must not age this render's own sample: the state layer judges every
# stored row against this value.
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

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
$FloatConfig = Get-FloatConfigPath -MainConfig $Config -FloatConfigPath $FloatConfig

# ---- normalise, falling back to the raw stdin ----------------------------------------
$payloadBytes = $rawBytes
$envMap = [ordered]@{}
$ompState = $null
$result = Get-OmpEnvironment $decoded
if ($result -is [hashtable] -and $result.Payload -is [System.Collections.IDictionary]) {
    # Not inside try: see Get-OmpState.
    $ompState = Get-OmpState -FiveHourPct $result.FhPct -FiveHourReset $result.FhRst -SevenDayPct $result.WdPct -SevenDayReset $result.WdRst `
        -MainConfig $Config -FloatConfigPath $FloatConfig -ExePath $OmpExe
    try {
        if ($null -ne $ompState -and $ompState.LimitSync -eq $true) {
            # VL_LIMIT_SYNC=1: the gauges show the synced windows, or hide.
            $syncedLimits = [ordered]@{}
            if ($ompState.FiveShow -eq $true) { $syncedLimits.five_hour = [ordered]@{ used_percentage = [long]$ompState.FivePct; resets_at = [long]$ompState.FiveReset } }
            if ($ompState.SevenShow -eq $true) { $syncedLimits.seven_day = [ordered]@{ used_percentage = [long]$ompState.SevenPct; resets_at = [long]$ompState.SevenReset } }
            switch ($syncedLimits.Count -gt 0) {
                $true { $result.Payload.rate_limits = $syncedLimits }
                default { $result.Payload.Remove('rate_limits') }
            }
        }
        if ($null -ne $ompState -and -not [string]::IsNullOrEmpty([string]$ompState.Burn)) {
            $result.Env.CORALLINE_OMP_BURN = [string]$ompState.Burn
            $result.Env.CORALLINE_OMP_BURN_TONE = [string]$ompState.BurnTone
            if (-not [string]::IsNullOrEmpty([string]$ompState.BurnEta)) { $result.Env.CORALLINE_OMP_BURN_ETA = [string]$ompState.BurnEta }
        }
    } catch {
        foreach ($name in @('CORALLINE_OMP_BURN', 'CORALLINE_OMP_BURN_TONE', 'CORALLINE_OMP_BURN_ETA')) { $result.Env.Remove($name) }
        if ($null -ne $ompState -and $ompState.LimitSync -eq $true) { $result.Payload.Remove('rate_limits') }
    }
    $payloadBytes = $Utf8NoBom.GetBytes((ConvertTo-JsonText $result.Payload))
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
try { Invoke-OmpFloat $OmpExe $Config $FloatConfig $payloadBytes $envMap $ompState } catch { }
exit 0
