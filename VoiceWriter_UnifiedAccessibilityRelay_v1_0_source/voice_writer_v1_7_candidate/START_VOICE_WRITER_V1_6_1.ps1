#requires -version 5.1
<#
START_VOICE_WRITER_V1_6_1.ps1

AnthBlackSystems Voice Writer provenance/bootstrap launcher.
V1.6.1 bugfix: hardened Git discovery and provenance-gate diagnostics.

Accepted Voice Writer rollback baseline:
    3f001ee

Design boundary:
- Voice Writer source is never silently modified, repaired, checked out, reset, or cleaned.
- pyproject.toml, uv.lock and src\wpt are authoritative project material.
- uv, Python 3.12 and .venv are disposable runtime infrastructure.
- Missing runtime infrastructure may be restored automatically.
- Dependencies are reconciled against uv.lock using --locked.
- Every launch creates a provenance session under D:\Kaiku\logs\voice_writer.
- Raw PowerShell transcript is primary terminal evidence.
- WPT metadata audit is enabled only when the installed WPT CLI exposes --audit-log.
- No retained microphone audio is added in V1.6.
#>

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------------------

$VWVersion = '1.6.1'
$Organisation = 'AnthBlackSystems'
$SystemName = 'VOICE_WRITER_PROVENANCE'
$AcceptedBaseline = '3f001ee'
$RuntimeTarget = 'Python 3.12'

$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    throw 'Cannot determine the Voice Writer project directory.'
}

$KaikuRoot = 'D:\Kaiku'
$VoiceWriterLogRoot = Join-Path $KaikuRoot 'logs\voice_writer'
$VoiceWriterOpenRoot = Join-Path $KaikuRoot 'provenance\voice_writer\open'

$PyProject = Join-Path $ProjectRoot 'pyproject.toml'
$UvLock = Join-Path $ProjectRoot 'uv.lock'
$SrcWpt = Join-Path $ProjectRoot 'src\wpt'
$VenvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'
$DefaultUv = Join-Path $HOME '.local\bin\uv.exe'

$AcceptedSourcePaths = @(
    'src/wpt/app.py',
    'src/wpt/core.py',
    'src/wpt/audit.py',
    'src/wpt/__main__.py',
    'start_voice_writer.bat',
    '.gitignore',
    'tests'
)

# ---------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------

function Get-VWNow {
    $now = Get-Date
    return [pscustomobject][ordered]@{
        local = $now.ToString('o')
        utc = $now.ToUniversalTime().ToString('o')
    }
}

function Write-VWUtf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-VWJsonAtomic {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $tmp = $Path + '.tmp'
    $json = $Object | ConvertTo-Json -Depth 20
    Write-VWUtf8File -Path $tmp -Content $json
    Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
}

function Get-VWSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    }
    catch {
        return $null
    }
}

function Get-VWEnvironment {
    $osCaption = $null
    $osVersion = $null
    $osBuild = $null
    $displayVersion = $null
    $architecture = $env:PROCESSOR_ARCHITECTURE

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $osCaption = $os.Caption
        $osVersion = $os.Version
        $osBuild = $os.BuildNumber
        if ($os.OSArchitecture) {
            $architecture = $os.OSArchitecture
        }
    }
    catch {
        $osVersion = [System.Environment]::OSVersion.VersionString
    }

    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $displayVersion = $cv.DisplayVersion
        if (-not $osBuild) {
            $osBuild = $cv.CurrentBuild
        }
    }
    catch {}

    $processStartedUtc = $null
    try {
        $processStartedUtc = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')
    }
    catch {}

    return [pscustomobject][ordered]@{
        evidence_class = 'OBS'
        windows_user = $env:USERNAME
        windows_identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        computer_name = $env:COMPUTERNAME
        os_caption = $osCaption
        os_version = $osVersion
        os_display_version = $displayVersion
        os_build = $osBuild
        architecture = $architecture
        powershell_edition = $PSVersionTable.PSEdition
        powershell_version = $PSVersionTable.PSVersion.ToString()
        powershell_host = $Host.Name
        process_id = $PID
        process_started_at_utc = $processStartedUtc
        profile_path = $PROFILE.CurrentUserCurrentHost
        project_root = $ProjectRoot
    }
}

function Resolve-VWGitExecutable {
    # First use the inherited PATH.
    $command = Get-Command git -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    # A retained Explorer/BAT process can have a stale PATH after Git install.
    # Refresh from the current machine + user environment, then retry.
    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $combinedPath = @($machinePath, $userPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        if ($combinedPath.Count -gt 0) {
            $env:Path = ($combinedPath -join ';')
        }
    }
    catch {}

    $command = Get-Command git -ErrorAction SilentlyContinue
    if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    # Narrow, conventional Git-for-Windows fallbacks only.
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path $env:ProgramFiles 'Git\bin\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    return $null
}

function Invoke-VWGitCapture {
    param(
        [Parameter(Mandatory = $true)][string]$GitExe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $output = @(& $GitExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE

        return [pscustomobject][ordered]@{
            exit_code = $exitCode
            output = @($output | ForEach-Object { $_.ToString() })
        }
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Get-VWGitState {
    param([string]$GitExe)

    if ([string]::IsNullOrWhiteSpace($GitExe) -or -not (Test-Path -LiteralPath $GitExe -PathType Leaf)) {
        return $null
    }

    $rootResult = Invoke-VWGitCapture -GitExe $GitExe -Arguments @('-C', $ProjectRoot, 'rev-parse', '--show-toplevel')
    if ($rootResult.exit_code -ne 0 -or $rootResult.output.Count -eq 0) {
        return $null
    }

    $headResult = Invoke-VWGitCapture -GitExe $GitExe -Arguments @('-C', $ProjectRoot, 'rev-parse', 'HEAD')
    $branchResult = Invoke-VWGitCapture -GitExe $GitExe -Arguments @('-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', 'HEAD')
    $statusResult = Invoke-VWGitCapture -GitExe $GitExe -Arguments @('-C', $ProjectRoot, 'status', '--porcelain')
    $versionResult = Invoke-VWGitCapture -GitExe $GitExe -Arguments @('--version')

    if ($headResult.exit_code -ne 0 -or $branchResult.exit_code -ne 0 -or $statusResult.exit_code -ne 0) {
        return $null
    }

    return [pscustomobject][ordered]@{
        evidence_class = 'OBS'
        repository = $rootResult.output[0]
        branch = $(if ($branchResult.output.Count -gt 0) { $branchResult.output[0] } else { $null })
        head_commit = $(if ($headResult.output.Count -gt 0) { $headResult.output[0] } else { $null })
        dirty = [bool]($statusResult.output.Count -gt 0)
        git_version = $(if ($versionResult.output.Count -gt 0) { $versionResult.output[0] } else { $null })
        executable = $GitExe
    }
}

function Test-VWPointerProcessAlive {
    param($Pointer)

    if (-not $Pointer -or -not $Pointer.process_id) {
        return $false
    }

    try {
        $process = Get-Process -Id ([int]$Pointer.process_id) -ErrorAction Stop

        if (-not $Pointer.process_started_at_utc) {
            return $true
        }

        $actual = $process.StartTime.ToUniversalTime()
        $expected = [datetime]::Parse($Pointer.process_started_at_utc).ToUniversalTime()

        return ([math]::Abs(($actual - $expected).TotalSeconds) -lt 2)
    }
    catch {
        return $false
    }
}

function Recover-VWOpenSessions {
    if (-not (Test-Path -LiteralPath $VoiceWriterOpenRoot)) {
        return
    }

    Get-ChildItem -LiteralPath $VoiceWriterOpenRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $pointerPath = $_.FullName

        try {
            $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 | ConvertFrom-Json

            if (-not (Test-VWPointerProcessAlive -Pointer $pointer)) {
                if ($pointer.session_json_path -and (Test-Path -LiteralPath $pointer.session_json_path)) {
                    $prior = Get-Content -LiteralPath $pointer.session_json_path -Raw -Encoding UTF8 | ConvertFrom-Json

                    if ($prior.session_status -eq 'OPEN') {
                        $now = Get-VWNow
                        $prior.session_status = 'INTERRUPTED_OR_UNCLEAN_EXIT'
                        $prior | Add-Member -NotePropertyName recovery_detected_at_local -NotePropertyValue $now.local -Force
                        $prior | Add-Member -NotePropertyName recovery_detected_at_utc -NotePropertyValue $now.utc -Force
                        $prior | Add-Member -NotePropertyName record_modified_at_local -NotePropertyValue $now.local -Force
                        $prior | Add-Member -NotePropertyName record_modified_at_utc -NotePropertyValue $now.utc -Force
                        Write-VWJsonAtomic -Object $prior -Path $pointer.session_json_path
                    }
                }

                Remove-Item -LiteralPath $pointerPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Host ('  Recovery warning: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Get-VWAuditSummary {
    param(
        [Parameter(Mandatory = $true)][string]$AuditPath,
        [Parameter(Mandatory = $true)][string]$TranscriptPath
    )

    $records = @()
    $invalidAuditLines = 0

    if (Test-Path -LiteralPath $AuditPath) {
        Get-Content -LiteralPath $AuditPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                try {
                    $records += ($_ | ConvertFrom-Json -ErrorAction Stop)
                }
                catch {
                    $invalidAuditLines++
                }
            }
        }
    }

    $recordingCount = 0
    $transcriptionCount = 0
    $pasteCount = 0
    $noSpeechCount = 0
    $errorCount = 0
    $audioSeconds = 0.0
    $deviceIndex = $null
    $modelName = $null

    foreach ($record in $records) {
        $event = ''
        if ($record.PSObject.Properties.Name -contains 'event') {
            $event = [string]$record.event
        }
        elseif ($record.PSObject.Properties.Name -contains 'type') {
            $event = [string]$record.type
        }

        $outcome = ''
        if ($record.PSObject.Properties.Name -contains 'outcome') {
            $outcome = [string]$record.outcome
        }

        if ($event -eq 'recording.started') {
            $recordingCount++
        }

        if ($event -eq 'transcription.finished') {
            $transcriptionCount++

            if ($record.PSObject.Properties.Name -contains 'seconds' -and $record.seconds -ne $null) {
                try {
                    $audioSeconds += [double]$record.seconds
                }
                catch {}
            }
        }

        if ($event -match 'paste|typing\.finished' -and $outcome -match 'paste|typed|success') {
            $pasteCount++
        }

        if ($outcome -in @('no_speech_detected','no_audio')) {
            $noSpeechCount++
        }

        if ($event -match 'error' -or $outcome -match 'error|state_error') {
            $errorCount++
        }

        if (-not $deviceIndex -and $record.PSObject.Properties.Name -contains 'device_index') {
            $deviceIndex = $record.device_index
        }

        if (-not $modelName -and $record.PSObject.Properties.Name -contains 'model_name') {
            $modelName = [string]$record.model_name
        }
    }

    $transcriptText = ''
    if (Test-Path -LiteralPath $TranscriptPath) {
        try {
            $transcriptText = Get-Content -LiteralPath $TranscriptPath -Raw -Encoding UTF8 -ErrorAction Stop
        }
        catch {}
    }

    if ($recordingCount -eq 0 -and $transcriptText) {
        $recordingCount = ([regex]::Matches($transcriptText, '(?m)^RECORDING(?:\s|\(|$)')).Count
    }

    if ($transcriptionCount -eq 0 -and $transcriptText) {
        $transcriptionCount = ([regex]::Matches($transcriptText, '(?m)^TRANSCRIBING(?:\s|$)')).Count
    }

    if ($pasteCount -eq 0 -and $transcriptText) {
        $pasteCount = ([regex]::Matches($transcriptText, '(?m)^(?:PASTED|DRAFT_TYPED)(?::|\s|$)')).Count
    }

    if ($noSpeechCount -eq 0 -and $transcriptText) {
        $noSpeechCount = ([regex]::Matches($transcriptText, '(?m)^(?:NO_SPEECH_DETECTED|NO_AUDIO)\s*$')).Count
    }

    if ($errorCount -eq 0 -and $transcriptText) {
        $errorCount = ([regex]::Matches($transcriptText, '(?m)^(?:TRANSCRIPTION_ERROR|TYPING_ERROR|STATE_ERROR|ERROR)(?:\s|:)')).Count
    }

    $derivedVoiceLines = @()
    if ($transcriptText) {
        $matches = [regex]::Matches(
            $transcriptText,
            '(?m)^(?:PASTED|DRAFT_READY|DRAFT_EDITED|TRANSCRIPT|TRANSCRIPTION)(?::\s*)(.+)$'
        )

        foreach ($match in $matches) {
            $candidate = $match.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $derivedVoiceLines += $candidate
            }
        }
    }

    return [pscustomobject][ordered]@{
        evidence_class = 'CALC'
        audit_records = $records.Count
        invalid_audit_lines = $invalidAuditLines
        recordings_started = $recordingCount
        transcriptions_finished = $transcriptionCount
        paste_events = $pasteCount
        no_speech_or_no_audio = $noSpeechCount
        error_events = $errorCount
        recorded_audio_seconds_from_audit = [math]::Round($audioSeconds, 3)
        device_index_from_audit = $deviceIndex
        model_name_from_audit = $modelName
        derived_voice_text_line_count = $derivedVoiceLines.Count
        derived_voice_text_lines = $derivedVoiceLines
    }
}

function New-VWSessionSummary {
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $gitLine = '[UN] Git state unavailable.'
    if ($Session.git_start) {
        $gitLine = '[OBS] Branch={0}; HEAD={1}; dirty={2}' -f $Session.git_start.branch, $Session.git_start.head_commit, $Session.git_start.dirty
    }

    $repairText = @()
    if ($Session.bootstrap.uv_installed_this_session) {
        $repairText += '- [OBS] uv was installed during this launch.'
    }
    if ($Session.bootstrap.venv_rebuilt_this_session) {
        $repairText += '- [OBS] `.venv` was rebuilt during this launch.'
    }
    if ($Session.bootstrap.dependency_sync_attempted) {
        $repairText += '- [OBS] Dependencies were reconciled against `uv.lock` using `--locked --no-install-project`.'
    }
    if ($repairText.Count -eq 0) {
        $repairText += '- [OBS] No runtime repair action was required.'
    }

    $md = @"
---
title: "$($Session.session_id)_VOICE_WRITER_SESSION_SUMMARY"
document_type: voice_writer_session_summary
organisation: AnthBlackSystems
system: VOICE_WRITER_PROVENANCE
schema_version: "1.6.1"
session_id: "$($Session.session_id)"
status: "$($Session.session_status)"
accepted_baseline: "$($Session.accepted_baseline)"
created_at: "$($Session.session_ended_at_local)"
generation_method: DETERMINISTIC_TEMPLATE
tags:
  - anthblacksystems
  - voice_writer
  - provenance
---

# VOICE WRITER SESSION SUMMARY

## Record control

- **Session:** ``$($Session.session_id)``
- **Status:** ``$($Session.session_status)``
- **Accepted rollback baseline:** ``$($Session.accepted_baseline)``
- **Project root:** ``$($Session.project_root)``
- **Started:** ``$($Session.session_started_at_local)``
- **Ended:** ``$($Session.session_ended_at_local)``
- **Duration seconds:** ``$($Session.duration_seconds)``

## Source state

$gitLine

- **Accepted source verification:** ``$($Session.source_verification.status)``
- **Untracked files inside accepted source path:** ``$($Session.source_verification.untracked_source_count)``

## Runtime

- **Python:** ``$($Session.runtime.python_version)``
- **Python path:** ``$($Session.runtime.python_path)``
- **uv:** ``$($Session.runtime.uv_version)``
- **uv path:** ``$($Session.runtime.uv_path)``
- **PowerShell:** ``$($Session.environment.powershell_version)``
- **Windows build:** ``$($Session.environment.os_build)``

## Bootstrap / repair

$($repairText -join [Environment]::NewLine)

## Voice Writer configuration

- **Auto-paste:** ``$($Session.voice_writer.auto_paste)``
- **Hotkeys:** ``Ctrl+Alt+O`` record; ``Ctrl+Alt+P`` stop/transcribe/paste; ``Ctrl+Alt+X`` exit
- **WPT metadata audit supported:** ``$($Session.voice_writer.wpt_audit_supported)``
- **WPT metadata audit enabled:** ``$($Session.voice_writer.wpt_audit_enabled)``
- **Model observed from WPT audit:** ``$($Session.activity.model_name_from_audit)``
- **Device index observed from WPT audit:** ``$($Session.activity.device_index_from_audit)``

## Activity summary

These counts are deterministic derivatives of the WPT metadata audit when available, with terminal-pattern fallback where required.

- **Recordings started:** ``$($Session.activity.recordings_started)``
- **Transcriptions finished:** ``$($Session.activity.transcriptions_finished)``
- **Paste events:** ``$($Session.activity.paste_events)``
- **No speech / no audio:** ``$($Session.activity.no_speech_or_no_audio)``
- **Error events:** ``$($Session.activity.error_events)``
- **Recorded audio seconds represented in audit:** ``$($Session.activity.recorded_audio_seconds_from_audit)``
- **Derived voice-text lines detected in raw transcript:** ``$($Session.activity.derived_voice_text_line_count)``

## Evidence files

- **Raw terminal transcript:** ``$($Session.outputs.transcript)``
- **WPT metadata audit:** ``$($Session.outputs.wpt_audit)``
- **Machine-readable session record:** ``$($Session.outputs.session_json)``
- **SHA-256 manifest:** ``$($Session.outputs.manifest)``
- **PowerShell profile wrapper snapshot:** ``$($Session.outputs.profile_wrapper_snapshot)``
- **Active Kaiku profile snapshot:** ``$($Session.outputs.active_profile_snapshot)``
- **Launcher snapshot:** ``$($Session.outputs.launcher_ps1_snapshot)``

## Integrity

- **Transcript SHA-256:** ``$($Session.integrity.transcript_sha256)``
- **pyproject.toml SHA-256:** ``$($Session.integrity.pyproject_sha256)``
- **uv.lock SHA-256:** ``$($Session.integrity.uv_lock_sha256)``
- **Launcher SHA-256:** ``$($Session.integrity.launcher_sha256)``

Hashes are integrity references only; they do not establish truth, authorship, or originality.

## Known limitations

- [OBS] V1.6.1 does not retain microphone audio.
- [OBS] PowerShell `Start-Transcript` records terminal-visible host activity; it is not a whole-machine activity recorder.
- [OBS] WPT operational audit is enabled only when the installed WPT CLI reports support for `--audit-log`.
- [CALC] Activity counts are derived records and do not replace the raw transcript or WPT JSONL.
- [UN] If Windows terminates the process without allowing finalisation, the next launch marks the prior open session as interrupted, but some final hashes/summary fields may remain unavailable.
"@

    Write-VWUtf8File -Path $Path -Content $md
}

function New-VWManifest {
    param(
        [Parameter(Mandatory = $true)][string]$SessionDir,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $lines = @(
        'VOICE_WRITER_SESSION_MANIFEST_V1_6_1',
        ('session_id=' + $SessionId),
        ('generated_at_utc=' + (Get-Date).ToUniversalTime().ToString('o')),
        'algorithm=SHA256',
        'hash_meaning=integrity_reference_only'
    )

    Get-ChildItem -LiteralPath $SessionDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $ManifestPath } |
        Sort-Object Name |
        ForEach-Object {
            try {
                $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop
                $lines += ('SHA256 {0} {1}' -f $hash.Hash, $_.Name)
            }
            catch {
                $lines += ('HASH_ERROR {0} {1}' -f $_.Name, $_.Exception.Message)
            }
        }

    Write-VWUtf8File -Path $ManifestPath -Content ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------
# AUTHORITATIVE ROOT AND SESSION INITIALISATION
# ---------------------------------------------------------------------

if (-not (Test-Path -LiteralPath 'D:\')) {
    throw 'D:\ is required for Voice Writer provenance. No fallback location is permitted.'
}

New-Item -ItemType Directory -Path $VoiceWriterLogRoot -Force -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $VoiceWriterOpenRoot -Force -ErrorAction Stop | Out-Null

Recover-VWOpenSessions

$started = Get-Date
$sessionHex = ([guid]::NewGuid().ToString('N').Substring(0,4)).ToUpperInvariant()
$sessionId = '{0}_{1}' -f $started.ToString('yyyyMMdd_HHmmss'), $sessionHex
$year = $started.ToString('yyyy')
$day = $started.ToString('yyyyMMdd')
$sessionDir = Join-Path (Join-Path (Join-Path $VoiceWriterLogRoot $year) $day) $sessionId

New-Item -ItemType Directory -Path $sessionDir -Force -ErrorAction Stop | Out-Null

$sessionJsonPath = Join-Path $sessionDir 'SESSION.json'
$transcriptPath = Join-Path $sessionDir 'TRANSCRIPT.txt'
$summaryPath = Join-Path $sessionDir 'SESSION_SUMMARY.md'
$manifestPath = Join-Path $sessionDir 'SESSION_MANIFEST.txt'
$wptAuditPath = Join-Path $sessionDir 'WPT_AUDIT.jsonl'
$voiceTextDerivedPath = Join-Path $sessionDir 'VOICE_TEXT_DERIVED.txt'
$profileWrapperSnapshot = Join-Path $sessionDir 'PROFILE_WRAPPER.ps1'
$activeProfileSnapshot = Join-Path $sessionDir 'ACTIVE_KAIKU_PROFILE.ps1'
$launcherPs1Snapshot = Join-Path $sessionDir 'LAUNCHER_V1_6_1.ps1'
$launcherBatSnapshot = Join-Path $sessionDir 'LAUNCHER_V1_6_1.bat'
$pointerPath = Join-Path $VoiceWriterOpenRoot ($sessionId + '.json')

$launcherBatSource = Join-Path $ProjectRoot 'START_VOICE_WRITER_V1_6_1.bat'
Copy-Item -LiteralPath $MyInvocation.MyCommand.Path -Destination $launcherPs1Snapshot -Force -ErrorAction Stop
if (Test-Path -LiteralPath $launcherBatSource) {
    Copy-Item -LiteralPath $launcherBatSource -Destination $launcherBatSnapshot -Force -ErrorAction Stop
}

$currentProfilePath = $PROFILE.CurrentUserCurrentHost
$resolvedActiveProfile = $null

if (Test-Path -LiteralPath $currentProfilePath) {
    Copy-Item -LiteralPath $currentProfilePath -Destination $profileWrapperSnapshot -Force -ErrorAction SilentlyContinue

    try {
        $profileWrapperText = Get-Content -LiteralPath $currentProfilePath -Raw -ErrorAction Stop
        $loaderMatch = [regex]::Match($profileWrapperText, '(?m)^\s*\.\s+["'']([^"'']+\.ps1)["'']\s*$')

        if ($loaderMatch.Success) {
            $resolvedActiveProfile = $loaderMatch.Groups[1].Value

            if (Test-Path -LiteralPath $resolvedActiveProfile) {
                Copy-Item -LiteralPath $resolvedActiveProfile -Destination $activeProfileSnapshot -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $resolvedActiveProfile = $null
    }
}

$timestamps = Get-VWNow
$environment = Get-VWEnvironment

$session = [pscustomobject][ordered]@{
    schema_version = '1.6.1'
    organisation = $Organisation
    system_name = $SystemName
    record_type = 'VOICE_WRITER_SESSION'
    session_id = $sessionId

    record_created_at_local = $timestamps.local
    record_created_at_utc = $timestamps.utc
    record_modified_at_local = $timestamps.local
    record_modified_at_utc = $timestamps.utc

    session_started_at_local = $timestamps.local
    session_started_at_utc = $timestamps.utc
    session_ended_at_local = $null
    session_ended_at_utc = $null
    duration_seconds = $null
    session_status = 'OPEN'
    failure = $null

    accepted_baseline = $AcceptedBaseline
    runtime_target = $RuntimeTarget
    project_root = $ProjectRoot

    environment = $environment
    git_start = $null
    git_end = $null

    source_verification = [pscustomobject][ordered]@{
        evidence_class = 'OBS'
        status = 'NOT_YET_CHECKED'
        baseline_commit_present = $null
        baseline_is_ancestor = $null
        accepted_paths_match_baseline = $null
        untracked_source_count = $null
        untracked_source_paths = @()
        git_check_limitation = $null
    }

    bootstrap = [pscustomobject][ordered]@{
        uv_found_at_start = $false
        uv_installed_this_session = $false
        network_bootstrap_attempted = $false
        venv_found_at_start = (Test-Path -LiteralPath $VenvPython)
        venv_rebuilt_this_session = $false
        dependency_sync_attempted = $false
        dependency_sync_exit_code = $null
    }

    runtime = [pscustomobject][ordered]@{
        uv_path = $null
        uv_version = $null
        python_path = $null
        python_version = $null
    }

    voice_writer = [pscustomobject][ordered]@{
        auto_paste = $true
        hotkeys = [pscustomobject][ordered]@{
            record = 'Ctrl+Alt+O'
            stop_transcribe_paste = 'Ctrl+Alt+P'
            exit = 'Ctrl+Alt+X'
        }
        wpt_help_checked = $false
        wpt_audit_supported = $false
        wpt_audit_enabled = $false
    }

    activity = [pscustomobject][ordered]@{
        evidence_class = 'CALC'
        audit_records = 0
        invalid_audit_lines = 0
        recordings_started = 0
        transcriptions_finished = 0
        paste_events = 0
        no_speech_or_no_audio = 0
        error_events = 0
        recorded_audio_seconds_from_audit = 0.0
        device_index_from_audit = $null
        model_name_from_audit = $null
        derived_voice_text_line_count = 0
    }

    outputs = [pscustomobject][ordered]@{
        session_directory = $sessionDir
        session_json = $sessionJsonPath
        transcript = $transcriptPath
        session_summary = $summaryPath
        manifest = $manifestPath
        wpt_audit = $wptAuditPath
        voice_text_derived = $voiceTextDerivedPath
        profile_wrapper_snapshot = $(if (Test-Path -LiteralPath $profileWrapperSnapshot) { $profileWrapperSnapshot } else { $null })
        active_profile_snapshot = $(if (Test-Path -LiteralPath $activeProfileSnapshot) { $activeProfileSnapshot } else { $null })
        launcher_ps1_snapshot = $launcherPs1Snapshot
        launcher_bat_snapshot = $(if (Test-Path -LiteralPath $launcherBatSnapshot) { $launcherBatSnapshot } else { $null })
    }

    integrity = [pscustomobject][ordered]@{
        algorithm = 'SHA256'
        pyproject_sha256 = Get-VWSha256 -Path $PyProject
        uv_lock_sha256 = Get-VWSha256 -Path $UvLock
        launcher_sha256 = Get-VWSha256 -Path $MyInvocation.MyCommand.Path
        transcript_sha256 = $null
        wpt_audit_sha256 = $null
        profile_wrapper_sha256 = Get-VWSha256 -Path $profileWrapperSnapshot
        active_profile_sha256 = Get-VWSha256 -Path $activeProfileSnapshot
    }

    known_limitations = @(
        'V1.6.1 does not retain microphone audio.',
        'PowerShell Start-Transcript records terminal-visible host activity, not all machine activity.',
        'WPT metadata audit is enabled only if the installed WPT CLI exposes --audit-log.',
        'Activity counts are derived from WPT JSONL with terminal-pattern fallback.',
        'Hashes are integrity references and do not establish truth, authorship, ownership, or originality.'
    )
}

Write-VWJsonAtomic -Object $session -Path $sessionJsonPath

$pointer = [pscustomobject][ordered]@{
    session_id = $sessionId
    session_json_path = $sessionJsonPath
    process_id = $PID
    process_started_at_utc = $environment.process_started_at_utc
    computer_name = $env:COMPUTERNAME
    created_at_utc = $timestamps.utc
}

Write-VWJsonAtomic -Object $pointer -Path $pointerPath

$transcriptStarted = $false
$fatalError = $null
$finalizationError = $null
$finalRecordWritten = $false
$voiceWriterExit = $null

try {
    Start-Transcript -LiteralPath $transcriptPath -Force -ErrorAction Stop | Out-Null
    $transcriptStarted = $true

    Write-Host ''
    Write-Host '          <>          []' -ForegroundColor DarkCyan
    Write-Host '      []      <>  <>      []' -ForegroundColor Cyan
    Write-Host '    <>  []  <>      []  <>  ' -ForegroundColor DarkCyan
    Write-Host '      []      <>  <>      []' -ForegroundColor Cyan
    Write-Host '          <>          []' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    ANTHBLACKSYSTEMS' -ForegroundColor Gray
    Write-Host '    VOICE WRITER PROVENANCE' -ForegroundColor DarkCyan
    Write-Host ('    PROFILE V{0}' -f $VWVersion) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('    SESSION  {0}' -f $sessionId) -ForegroundColor Gray
    Write-Host ('    ROOT     {0}' -f $ProjectRoot) -ForegroundColor Gray
    Write-Host ('    RECORD   {0}' -f $sessionJsonPath) -ForegroundColor DarkGray
    Write-Host '    CAPTURE  ACTIVE' -ForegroundColor Gray
    Write-Host ''

    # -----------------------------------------------------------------
    # GATE 1 — AUTHORITATIVE PROJECT MATERIAL
    # -----------------------------------------------------------------

    foreach ($required in @($PyProject, $UvLock, $SrcWpt)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "Authoritative Voice Writer project component is missing: $required"
        }
    }

    Write-Host '  [ok] project definition, lockfile and WPT source present' -ForegroundColor Green

    # -----------------------------------------------------------------
    # GATE 2 — GIT / ACCEPTED-SOURCE VERIFICATION WHEN AVAILABLE
    # -----------------------------------------------------------------
    # V1.6.1 deliberately separates:
    #   1. "Can Git inspect this repository?" from
    #   2. optional Git metadata collection.
    # A metadata helper failure must not generate a false "Git unavailable"
    # provenance warning.

    $gitExe = Resolve-VWGitExecutable

    if ($gitExe) {
        $repoProbe = Invoke-VWGitCapture -GitExe $gitExe -Arguments @(
            '-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree'
        )

        $gitUsable = (
            $repoProbe.exit_code -eq 0 -and
            $repoProbe.output.Count -gt 0 -and
            $repoProbe.output[0].Trim().ToLowerInvariant() -eq 'true'
        )

        if ($gitUsable) {
            $session.git_start = Get-VWGitState -GitExe $gitExe

            $baselineProbe = Invoke-VWGitCapture -GitExe $gitExe -Arguments @(
                '-C', $ProjectRoot, 'cat-file', '-e', "$AcceptedBaseline^{commit}"
            )
            $baselinePresent = ($baselineProbe.exit_code -eq 0)

            $baselineAncestor = $false
            if ($baselinePresent) {
                $ancestorProbe = Invoke-VWGitCapture -GitExe $gitExe -Arguments @(
                    '-C', $ProjectRoot, 'merge-base', '--is-ancestor', $AcceptedBaseline, 'HEAD'
                )
                $baselineAncestor = ($ancestorProbe.exit_code -eq 0)
            }

            $diffArguments = @('-C', $ProjectRoot, 'diff', '--quiet', $AcceptedBaseline, '--') + $AcceptedSourcePaths
            $diffProbe = Invoke-VWGitCapture -GitExe $gitExe -Arguments $diffArguments
            $pathsMatch = ($baselinePresent -and $diffProbe.exit_code -eq 0)

            $untrackedProbe = Invoke-VWGitCapture -GitExe $gitExe -Arguments @(
                '-C', $ProjectRoot, 'ls-files', '--others', '--exclude-standard', '--', 'src/wpt'
            )

            $untrackedSource = @()
            if ($untrackedProbe.exit_code -eq 0) {
                $untrackedSource = @(
                    $untrackedProbe.output |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }

            $session.source_verification.baseline_commit_present = $baselinePresent
            $session.source_verification.baseline_is_ancestor = $baselineAncestor
            $session.source_verification.accepted_paths_match_baseline = $pathsMatch
            $session.source_verification.untracked_source_count = $untrackedSource.Count
            $session.source_verification.untracked_source_paths = $untrackedSource

            if (-not $baselinePresent) {
                $session.source_verification.status = 'FAIL_BASELINE_MISSING'
                throw "Accepted baseline commit $AcceptedBaseline is missing. Source was NOT modified."
            }

            if (-not $baselineAncestor) {
                $session.source_verification.status = 'FAIL_BASELINE_NOT_ANCESTOR'
                throw "Accepted baseline $AcceptedBaseline is not an ancestor of current HEAD. Source was NOT modified."
            }

            if (-not $pathsMatch) {
                $session.source_verification.status = 'FAIL_ACCEPTED_SOURCE_CHANGED'
                throw "Accepted Voice Writer source differs from baseline $AcceptedBaseline. Source was NOT modified."
            }

            if ($untrackedProbe.exit_code -ne 0) {
                $session.source_verification.status = 'FAIL_UNTRACKED_SOURCE_CHECK'
                throw ('Git could not inspect untracked src/wpt files: {0}' -f ($untrackedProbe.output -join ' | '))
            }

            if ($untrackedSource.Count -gt 0) {
                $session.source_verification.status = 'FAIL_UNTRACKED_SOURCE_FILES'
                throw ('Untracked files exist inside src/wpt: {0}' -f ($untrackedSource -join ', '))
            }

            $session.source_verification.status = 'PASS'

            if (-not $session.git_start) {
                # Provenance gate passed; only ancillary metadata collection failed.
                $session.source_verification.git_check_limitation = 'Repository/source gate passed, but optional Git metadata collection returned no record.'
                Write-Host ('  [ok] accepted source matches baseline {0}' -f $AcceptedBaseline) -ForegroundColor Green
                Write-Host '  [warn] optional Git metadata record unavailable; source verification itself passed.' -ForegroundColor Yellow
            }
            else {
                Write-Host ('  [ok] accepted source matches baseline {0}' -f $AcceptedBaseline) -ForegroundColor Green
                Write-Host ('  [ok] Git {0} via {1}' -f $session.git_start.git_version, $gitExe) -ForegroundColor Green
            }
        }
        else {
            $session.source_verification.status = 'UNVERIFIED_GIT_REPOSITORY_PROBE_FAILED'
            $session.source_verification.git_check_limitation = (
                'Git executable resolved, but repository probe failed. Exit={0}; Output={1}' -f
                $repoProbe.exit_code,
                ($repoProbe.output -join ' | ')
            )

            Write-Host (
                '  [warn] Git executable found, but repository probe failed: exit {0}; {1}' -f
                $repoProbe.exit_code,
                ($repoProbe.output -join ' | ')
            ) -ForegroundColor Yellow
        }
    }
    else {
        $session.source_verification.status = 'UNVERIFIED_GIT_EXECUTABLE_NOT_FOUND'
        $session.source_verification.git_check_limitation = 'Git executable could not be resolved from inherited PATH, refreshed PATH, or narrow Git-for-Windows locations.'
        Write-Host '  [warn] Git executable could not be resolved; runtime recovery may continue.' -ForegroundColor Yellow
    }

    Write-VWJsonAtomic -Object $session -Path $sessionJsonPath

    # -----------------------------------------------------------------
    # GATE 3 — UV BOOTSTRAP
    # -----------------------------------------------------------------

    $uvCommand = Get-Command uv -ErrorAction SilentlyContinue

    if ($uvCommand) {
        $uvExe = $uvCommand.Source
        $session.bootstrap.uv_found_at_start = $true
    }
    elseif (Test-Path -LiteralPath $DefaultUv) {
        $uvExe = $DefaultUv
        $session.bootstrap.uv_found_at_start = $true
    }
    else {
        $session.bootstrap.network_bootstrap_attempted = $true
        Write-Host '  [repair] uv missing -> installing official uv...' -ForegroundColor Yellow

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command 'irm https://astral.sh/uv/install.ps1 | iex'
        $uvInstallExit = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference

        if ($uvInstallExit -ne 0) {
            throw "uv installer failed with exit code $uvInstallExit"
        }

        if (Test-Path -LiteralPath $DefaultUv) {
            $uvExe = $DefaultUv
        }
        else {
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
            $uvCommand = Get-Command uv -ErrorAction SilentlyContinue

            if (-not $uvCommand) {
                throw 'uv installation completed but uv.exe could not be located.'
            }

            $uvExe = $uvCommand.Source
        }

        $session.bootstrap.uv_installed_this_session = $true
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $uvVersionText = & $uvExe --version 2>&1
    $uvVersionExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if ($uvVersionExit -ne 0) {
        throw "uv exists but could not execute: $(($uvVersionText | Out-String).Trim())"
    }

    $session.runtime.uv_path = $uvExe
    $session.runtime.uv_version = (($uvVersionText | Out-String).Trim())
    Write-Host ('  [ok] {0}' -f $session.runtime.uv_version) -ForegroundColor Green

    # -----------------------------------------------------------------
    # GATE 4 — PYTHON 3.12 / VENV
    # -----------------------------------------------------------------

    $needVenvRepair = $false
    $existingPythonVersion = $null

    if (-not (Test-Path -LiteralPath $VenvPython)) {
        $needVenvRepair = $true
    }
    else {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $existingPythonVersion = & $VenvPython --version 2>&1
        $existingPythonExit = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference

        $existingPythonVersion = (($existingPythonVersion | Out-String).Trim())

        if ($existingPythonExit -ne 0 -or $existingPythonVersion -notmatch '^Python 3\.12(\.|$)') {
            $needVenvRepair = $true
        }
    }

    if ($needVenvRepair) {
        Write-Host '  [repair] Python 3.12 environment missing/orphaned/wrong -> rebuilding .venv...' -ForegroundColor Yellow

        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $uvExe venv '.venv' --python 3.12 --clear
        $venvExit = $LASTEXITCODE
        $ErrorActionPreference = $oldPreference

        if ($venvExit -ne 0) {
            throw "uv could not create the Python 3.12 environment (exit code $venvExit)"
        }

        $session.bootstrap.venv_rebuilt_this_session = $true
    }
    else {
        Write-Host ('  [ok] existing runtime: {0}' -f $existingPythonVersion) -ForegroundColor Green
    }

    # -----------------------------------------------------------------
    # GATE 5 — LOCKED DEPENDENCY CONVERGENCE
    # -----------------------------------------------------------------

    Write-Host '  [sync] checking locked Voice Writer dependencies...' -ForegroundColor Gray
    $session.bootstrap.dependency_sync_attempted = $true

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $uvExe sync --locked --no-install-project
    $syncExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    $session.bootstrap.dependency_sync_exit_code = $syncExit

    if ($syncExit -ne 0) {
        throw "Dependency sync from uv.lock failed with exit code $syncExit"
    }

    Write-Host '  [ok] locked dependencies ready' -ForegroundColor Green

    # -----------------------------------------------------------------
    # GATE 6 — FINAL RUNTIME CHECK
    # -----------------------------------------------------------------

    $VenvPython = Join-Path $ProjectRoot '.venv\Scripts\python.exe'

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $pythonVersionText = & $VenvPython --version 2>&1
    $pythonVersionExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    $pythonVersionText = (($pythonVersionText | Out-String).Trim())

    if ($pythonVersionExit -ne 0 -or $pythonVersionText -notmatch '^Python 3\.12(\.|$)') {
        throw "Voice Writer runtime verification failed: $pythonVersionText"
    }

    $session.runtime.python_path = $VenvPython
    $session.runtime.python_version = $pythonVersionText
    Write-Host ('  [ok] final runtime: {0}' -f $pythonVersionText) -ForegroundColor Green

    # -----------------------------------------------------------------
    # GATE 7 — WPT CAPABILITY CHECK
    # -----------------------------------------------------------------

    $env:PYTHONPATH = Join-Path $ProjectRoot 'src'

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $wptHelp = & $VenvPython -m wpt --help 2>&1
    $wptHelpExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    $session.voice_writer.wpt_help_checked = $true

    if ($wptHelpExit -eq 0) {
        $wptHelpText = ($wptHelp | Out-String)
        $session.voice_writer.wpt_audit_supported = ($wptHelpText -match '(?m)--audit-log(?:\s|$)')
    }
    else {
        Write-Host '  [warn] WPT help probe failed; continuing without WPT metadata audit.' -ForegroundColor Yellow
    }

    $wptArgs = @('-m', 'wpt', '--auto-paste')

    if ($session.voice_writer.wpt_audit_supported) {
        $wptArgs += @('--audit-log', $wptAuditPath)
        $session.voice_writer.wpt_audit_enabled = $true
        Write-Host '  [ok] WPT metadata audit enabled' -ForegroundColor Green
    }
    else {
        Write-Host '  [warn] installed WPT does not expose --audit-log; raw terminal transcript remains active.' -ForegroundColor Yellow
    }

    Write-VWJsonAtomic -Object $session -Path $sessionJsonPath

    # -----------------------------------------------------------------
    # GATE 8 — START VOICE WRITER
    # -----------------------------------------------------------------

    Write-Host ''
    Write-Host '    READY TO START VOICE WRITER' -ForegroundColor Green
    Write-Host '    Ctrl+Alt+O  record' -ForegroundColor Cyan
    Write-Host '    Ctrl+Alt+P  stop / transcribe / paste' -ForegroundColor Cyan
    Write-Host '    Ctrl+Alt+X  exit' -ForegroundColor Cyan
    Write-Host ''

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $VenvPython @wptArgs
    $voiceWriterExit = $LASTEXITCODE
    $ErrorActionPreference = $oldPreference

    if ($voiceWriterExit -ne 0) {
        throw "Voice Writer exited with code $voiceWriterExit"
    }
}
catch {
    $fatalError = $_

    try {
        Write-Host ''
        Write-Host ('    VOICE WRITER FAILURE: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
    catch {}

    $session.failure = [pscustomobject][ordered]@{
        evidence_class = 'OBS'
        exception_type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        script_line = $_.InvocationInfo.ScriptLineNumber
        code = $_.InvocationInfo.Line
    }
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {}
        $transcriptStarted = $false
    }

    $ended = Get-VWNow
    $session.session_ended_at_local = $ended.local
    $session.session_ended_at_utc = $ended.utc

    try {
        $session.duration_seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 3)
    }
    catch {}

    if ($fatalError) {
        $session.session_status = 'FAILED'
    }
    else {
        $session.session_status = 'CLEAN_CLOSE'
    }

    $session.git_end = Get-VWGitState -GitExe (Resolve-VWGitExecutable)

    $activity = Get-VWAuditSummary -AuditPath $wptAuditPath -TranscriptPath $transcriptPath

    foreach ($property in $activity.PSObject.Properties) {
        if ($property.Name -ne 'derived_voice_text_lines') {
            $session.activity.$($property.Name) = $property.Value
        }
    }

    if ($activity.derived_voice_text_lines.Count -gt 0) {
        $voiceTextContent = @(
            'VOICE_TEXT_DERIVED_V1',
            'source=TRANSCRIPT.txt',
            'derivation=terminal_prefix_pattern_extraction',
            'status=DERIVED_NOT_PRIMARY_EVIDENCE',
            ''
        ) + @($activity.derived_voice_text_lines)

        Write-VWUtf8File -Path $voiceTextDerivedPath -Content ($voiceTextContent -join [Environment]::NewLine)
    }
    else {
        $session.outputs.voice_text_derived = $null
    }

    $session.integrity.transcript_sha256 = Get-VWSha256 -Path $transcriptPath
    $session.integrity.wpt_audit_sha256 = Get-VWSha256 -Path $wptAuditPath

    $modified = Get-VWNow
    $session.record_modified_at_local = $modified.local
    $session.record_modified_at_utc = $modified.utc

    try {
        Write-VWJsonAtomic -Object $session -Path $sessionJsonPath
        $finalRecordWritten = $true
    }
    catch {
        $finalizationError = $_
    }

    if (-not $finalizationError) {
        try {
            New-VWSessionSummary -Session $session -Path $summaryPath
        }
        catch {
            $finalizationError = $_
        }
    }

    if (-not $finalizationError) {
        try {
            New-VWManifest -SessionDir $sessionDir -ManifestPath $manifestPath -SessionId $sessionId
        }
        catch {
            $finalizationError = $_
        }
    }

    if ($finalRecordWritten) {
        try {
            if (Test-Path -LiteralPath $pointerPath) {
                Remove-Item -LiteralPath $pointerPath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }

    try {
        Write-Host ''
        Write-Host '    SESSION CLOSED' -ForegroundColor DarkCyan
        Write-Host ('    STATUS   {0}' -f $session.session_status) -ForegroundColor Gray
        Write-Host ('    RECORD   {0}' -f $sessionJsonPath) -ForegroundColor DarkGray
        Write-Host ('    SUMMARY  {0}' -f $summaryPath) -ForegroundColor DarkGray
        Write-Host ('    LOG      {0}' -f $transcriptPath) -ForegroundColor DarkGray

        if ($finalizationError) {
            Write-Host ('    RECORDING FINALISATION ERROR: {0}' -f $finalizationError.Exception.Message) -ForegroundColor Red
        }

        Write-Host ''
    }
    catch {}
}

if ($fatalError) {
    exit 1
}

if ($finalizationError) {
    exit 2
}

if ($voiceWriterExit -ne $null) {
    exit ([int]$voiceWriterExit)
}

exit 0
