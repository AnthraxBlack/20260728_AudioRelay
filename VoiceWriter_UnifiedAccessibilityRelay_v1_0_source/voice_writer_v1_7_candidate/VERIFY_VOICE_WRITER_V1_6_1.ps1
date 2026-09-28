#requires -version 5.1
<#
VERIFY_VOICE_WRITER_V1_6_1.ps1

Read-only verifier for Voice Writer V1.6.1.
It does not launch recording, mutate source, install dependencies, or alter Git.
#>

$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$Launcher = Join-Path $ProjectRoot 'START_VOICE_WRITER_V1_6_1.ps1'
$LauncherBat = Join-Path $ProjectRoot 'START_VOICE_WRITER_V1_6_1.bat'
$AcceptedBaseline = '3f001ee'
$LogRoot = 'D:\Kaiku\logs\voice_writer'
$VenvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'

$Failures = 0
$Warnings = 0

function Pass([string]$Text) {
    Write-Host ('[PASS] {0}' -f $Text) -ForegroundColor Green
}

function Warn([string]$Text) {
    $script:Warnings++
    Write-Host ('[WARN] {0}' -f $Text) -ForegroundColor Yellow
}

function Fail([string]$Text) {
    $script:Failures++
    Write-Host ('[FAIL] {0}' -f $Text) -ForegroundColor Red
}

Write-Host ''
Write-Host 'VOICE WRITER V1.6.1 VERIFIER' -ForegroundColor Cyan
Write-Host '--------------------------' -ForegroundColor DarkGray

# 1. Required launcher files.
foreach ($path in @($Launcher, $LauncherBat)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Pass "Present: $path"
    }
    else {
        Fail "Missing: $path"
    }
}

# 2. PowerShell parser check.
if (Test-Path -LiteralPath $Launcher) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors) | Out-Null

    if (@($errors).Count -eq 0) {
        Pass 'Launcher parses with zero PowerShell syntax errors.'
    }
    else {
        foreach ($error in @($errors)) {
            Fail ('Parser: {0} at {1}' -f $error.Message, $error.Extent.Text)
        }
    }
}

# 3. Required authoritative project inputs.
$required = @(
    (Join-Path $ProjectRoot 'pyproject.toml'),
    (Join-Path $ProjectRoot 'uv.lock'),
    (Join-Path $ProjectRoot 'src\wpt')
)

foreach ($path in $required) {
    if (Test-Path -LiteralPath $path) {
        Pass "Authoritative input present: $path"
    }
    else {
        Fail "Authoritative input missing: $path"
    }
}

# 4. Static no-source-mutation guard.
if (Test-Path -LiteralPath $Launcher) {
    $launcherText = Get-Content -LiteralPath $Launcher -Raw -Encoding UTF8

    $forbidden = @(
        'git\s+checkout',
        'git\s+reset',
        'git\s+clean',
        'git\s+restore',
        'git\s+commit',
        'git\s+add'
    )

    $forbiddenFound = $false

    foreach ($pattern in $forbidden) {
        if ($launcherText -match $pattern) {
            $forbiddenFound = $true
            Fail "Launcher contains forbidden source-control mutation pattern: $pattern"
        }
    }

    if (-not $forbiddenFound) {
        Pass 'No forbidden Git source-mutation command detected in launcher.'
    }
}

# 5. Git baseline/source check when Git can inspect this repo.
# V1.6.1 regression test: the same no-profile-style direct Git repository
# probe used by the launcher must work independently of metadata collection.
$git = Get-Command git -ErrorAction SilentlyContinue

if (-not $git) {
    try {
        $env:Path = (
            [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
        )
    }
    catch {}
    $git = Get-Command git -ErrorAction SilentlyContinue
}

if ($git) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $repoProbeOutput = @(& $git.Source -C $ProjectRoot rev-parse --is-inside-work-tree 2>&1)
    $repoProbeExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if (
        $repoProbeExit -eq 0 -and
        $repoProbeOutput.Count -gt 0 -and
        $repoProbeOutput[0].ToString().Trim().ToLowerInvariant() -eq 'true'
    ) {
        Pass ('Direct Git repository probe passed via {0}' -f $git.Source)
    }
    else {
        Fail ('Direct Git repository probe failed: exit={0}; output={1}' -f $repoProbeExit, ($repoProbeOutput -join ' | '))
    }
}
else {
    Warn 'Git executable could not be resolved for the direct regression probe.'
}

$git = Get-Command git -ErrorAction SilentlyContinue

if ($git) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    & git -C $ProjectRoot rev-parse --is-inside-work-tree *> $null
    $gitUsable = ($LASTEXITCODE -eq 0)

    $ErrorActionPreference = $oldPreference

    if ($gitUsable) {
        $acceptedPaths = @(
            'src/wpt/app.py',
            'src/wpt/core.py',
            'src/wpt/audit.py',
            'src/wpt/__main__.py',
            'start_voice_writer.bat',
            '.gitignore',
            'tests'
        )

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        & git -C $ProjectRoot cat-file -e "$AcceptedBaseline^{commit}" *> $null
        $baselinePresent = ($LASTEXITCODE -eq 0)

        & git -C $ProjectRoot merge-base --is-ancestor $AcceptedBaseline HEAD *> $null
        $baselineAncestor = ($LASTEXITCODE -eq 0)

        & git -C $ProjectRoot diff --quiet $AcceptedBaseline -- @acceptedPaths
        $pathsMatch = ($LASTEXITCODE -eq 0)

        $untrackedSource = @(& git -C $ProjectRoot ls-files --others --exclude-standard -- 'src/wpt')
        $untrackedSource = @($untrackedSource | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $ErrorActionPreference = $oldPreference

        if ($baselinePresent) { Pass "Accepted baseline $AcceptedBaseline exists." } else { Fail "Accepted baseline $AcceptedBaseline missing." }
        if ($baselineAncestor) { Pass "Accepted baseline $AcceptedBaseline is an ancestor of HEAD." } else { Fail "Accepted baseline is not an ancestor of HEAD." }
        if ($pathsMatch) { Pass 'Accepted Voice Writer source matches baseline.' } else { Fail 'Accepted Voice Writer source differs from baseline.' }

        if ($untrackedSource.Count -eq 0) {
            Pass 'No untracked files inside src/wpt.'
        }
        else {
            Fail ('Untracked src/wpt files: {0}' -f ($untrackedSource -join ', '))
        }
    }
    else {
        Warn 'Git exists but cannot inspect this repository in the current session.'
    }
}
else {
    Warn 'Git is unavailable; Git provenance verification skipped.'
}

# 6. Existing runtime and WPT CLI capability check.
if (Test-Path -LiteralPath $VenvPython) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $pythonVersion = & $VenvPython --version 2>&1
    $pythonExit = $LASTEXITCODE

    $ErrorActionPreference = $oldPreference
    $pythonVersion = (($pythonVersion | Out-String).Trim())

    if ($pythonExit -eq 0 -and $pythonVersion -match '^Python 3\.12(\.|$)') {
        Pass "Runtime is $pythonVersion."

        $env:PYTHONPATH = Join-Path $ProjectRoot 'src'

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        $help = & $VenvPython -m wpt --help 2>&1
        $helpExit = $LASTEXITCODE

        $ErrorActionPreference = $oldPreference

        if ($helpExit -eq 0) {
            Pass 'WPT CLI --help executes successfully.'

            $helpText = ($help | Out-String)

            if ($helpText -match '(?m)--auto-paste(?:\s|$)') {
                Pass 'WPT exposes --auto-paste.'
            }
            else {
                Fail 'WPT does not expose --auto-paste.'
            }

            if ($helpText -match '(?m)--audit-log(?:\s|$)') {
                Pass 'WPT exposes --audit-log.'
            }
            else {
                Warn 'WPT does not expose --audit-log; V1.6 will retain raw terminal transcript only.'
            }
        }
        else {
            Fail 'WPT CLI --help failed.'
        }
    }
    else {
        Warn "Current .venv is not a healthy Python 3.12 runtime: $pythonVersion"
    }
}
else {
    Warn '.venv is absent. This is valid after a reset; V1.6 should bootstrap it on launch.'
}

# 7. Validate newest completed session if one exists.
if (Test-Path -LiteralPath $LogRoot) {
    $latestSession = Get-ChildItem -LiteralPath $LogRoot -Recurse -Filter 'SESSION.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($latestSession) {
        try {
            $session = Get-Content -LiteralPath $latestSession.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            Pass "Latest SESSION.json parses: $($latestSession.FullName)"

            if ($session.schema_version -eq '1.6.1') {
                Pass 'Latest session schema is V1.6.1.'
            }
            else {
                Warn "Latest session is schema $($session.schema_version), not V1.6.1."
            }

            if ($session.schema_version -eq '1.6.1') {
                if ($session.session_status -eq 'OPEN') {
                    Warn 'Latest V1.6.1 session is still OPEN.'
                }
                elseif ($session.session_status -in @('CLEAN_CLOSE','FAILED','INTERRUPTED_OR_UNCLEAN_EXIT')) {
                    Pass "Latest V1.6.1 session has explicit terminal state: $($session.session_status)"
                }
                else {
                    Fail "Unexpected session_status: $($session.session_status)"
                }

                foreach ($outputProperty in @('transcript','session_summary','manifest','launcher_ps1_snapshot')) {
                    $path = $session.outputs.$outputProperty
                    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                        Pass "Session artifact present: $outputProperty"
                    }
                    else {
                        Fail "Session artifact missing: $outputProperty"
                    }
                }

                if ($session.integrity.transcript_sha256 -and (Test-Path -LiteralPath $session.outputs.transcript)) {
                    $actual = (Get-FileHash -LiteralPath $session.outputs.transcript -Algorithm SHA256).Hash
                    if ($actual -eq $session.integrity.transcript_sha256) {
                        Pass 'Transcript SHA-256 matches SESSION.json.'
                    }
                    else {
                        Fail 'Transcript SHA-256 does not match SESSION.json.'
                    }
                }

                if ($session.outputs.manifest -and (Test-Path -LiteralPath $session.outputs.manifest)) {
                    $manifestLines = Get-Content -LiteralPath $session.outputs.manifest -Encoding UTF8
                    $manifestFailures = 0

                    foreach ($line in $manifestLines) {
                        if ($line -match '^SHA256\s+([A-Fa-f0-9]{64})\s+(.+)$') {
                            $expectedHash = $matches[1].ToUpperInvariant()
                            $fileName = $matches[2]
                            $filePath = Join-Path $session.outputs.session_directory $fileName

                            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                                $manifestFailures++
                                Fail "Manifest file missing: $fileName"
                                continue
                            }

                            $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash

                            if ($actualHash -ne $expectedHash) {
                                $manifestFailures++
                                Fail "Manifest hash mismatch: $fileName"
                            }
                        }
                    }

                    if ($manifestFailures -eq 0) {
                        Pass 'All manifest SHA-256 entries verified.'
                    }
                }
            }
        }
        catch {
            Fail "Latest session validation failed: $($_.Exception.Message)"
        }
    }
    else {
        Warn 'No Voice Writer session record found yet.'
    }
}
else {
    Warn 'Voice Writer log root does not exist yet.'
}

Write-Host ''
Write-Host ('RESULT: {0} failure(s), {1} warning(s)' -f $Failures, $Warnings) -ForegroundColor $(if ($Failures -eq 0) { 'Green' } else { 'Red' })

if ($Failures -gt 0) {
    exit 1
}

exit 0
