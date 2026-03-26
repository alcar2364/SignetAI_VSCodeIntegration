function Get-SignetSessionIdentity {
    param(
        [object]$HookInput,
        [string]$AgentIdentity
    )

    $sessionIdentityParts = @(
        $AgentIdentity,
        $HookInput.sessionKey,
        $HookInput.session_key,
        $HookInput.sessionId,
        $HookInput.session_id
    ) | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) }

    $sessionIdentity = $sessionIdentityParts -join "|"
    if ([string]::IsNullOrWhiteSpace($sessionIdentity)) {
        return $AgentIdentity
    }

    return $sessionIdentity
}

function Get-SignetTranscriptStatePath {
    param(
        [string]$GeneratedDir,
        [object]$HookInput,
        [string]$AgentIdentity
    )

    $stateDir = Join-Path $GeneratedDir "transcript-state"
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    $sessionIdentity = Get-SignetSessionIdentity -HookInput $HookInput -AgentIdentity $AgentIdentity
    $identityBytes = [System.Text.Encoding]::UTF8.GetBytes($sessionIdentity)
    $identityHash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($identityBytes)).ToLowerInvariant()
    return Join-Path $stateDir ("{0}.json" -f $identityHash)
}

function Read-SignetTranscriptState {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return @{}
    }

    try {
        $parsed = Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 10
        if ($null -eq $parsed) {
            return @{}
        }

        return $parsed
    }
    catch {
        return @{}
    }
}

function Write-SignetTranscriptState {
    param(
        [string]$Path,
        [object]$State
    )

    $json = $State | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Clear-SignetTranscriptState {
    param(
        [string]$Path
    )

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-SignetHookTranscriptPath {
    param(
        [object]$HookInput
    )

    foreach ($candidate in @($HookInput.transcript_path, $HookInput.transcriptPath)) {
        if ($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Get-SignetSessionKey {
    param(
        [object]$HookInput
    )

    foreach ($candidate in @($HookInput.sessionKey, $HookInput.session_key, $HookInput.sessionId, $HookInput.session_id)) {
        if ($candidate -is [string] -and -not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return ""
}

function Get-SignetTranscriptWindow {
    param(
        [string]$TranscriptPath,
        [object]$State
    )

    if ([string]::IsNullOrWhiteSpace($TranscriptPath) -or -not (Test-Path $TranscriptPath)) {
        return @{
            transcriptPath = $TranscriptPath
            content = ""
            currentLength = 0
            startOffset = 0
            exists = $false
        }
    }

    $content = [System.IO.File]::ReadAllText($TranscriptPath)
    $currentLength = $content.Length
    $startOffset = 0

    if ($null -ne $State -and $State.transcriptPath -eq $TranscriptPath -and $null -ne $State.lastProcessedLength) {
        try {
            $startOffset = [Math]::Max([int64]$State.lastProcessedLength, 0)
        }
        catch {
            $startOffset = 0
        }
    }

    if ($currentLength -lt $startOffset) {
        $startOffset = 0
    }

    $segment = if ($startOffset -ge $currentLength) {
        ""
    }
    else {
        $content.Substring([int]$startOffset)
    }

    return @{
        transcriptPath = $TranscriptPath
        content = $segment
        currentLength = $currentLength
        startOffset = $startOffset
        exists = $true
    }
}

function Convert-SignetTranscriptLineText {
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    return (($Text -replace "\r?\n", " ").Trim())
}

function Get-SignetTranscriptRecordText {
    param(
        [object]$Record,
        [string[]]$PropertyNames
    )

    foreach ($propertyName in $PropertyNames) {
        if ($Record.PSObject.Properties.Name -contains $propertyName) {
            $value = $Record.$propertyName
            if ($value -is [string]) {
                $text = Convert-SignetTranscriptLineText -Text $value
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    return $text
                }
            }
        }
    }

    return ""
}

function Convert-SignetTranscriptContent {
    param(
        [string]$RawTranscript
    )

    if ([string]::IsNullOrWhiteSpace($RawTranscript)) {
        return ""
    }

    $lines = $RawTranscript -split "\r?\n"
    $parsedCount = 0
    $conversationLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
            continue
        }

        try {
            $record = $trimmedLine | ConvertFrom-Json -Depth 20
        }
        catch {
            continue
        }

        if ($null -eq $record) {
            continue
        }

        $parsedCount += 1
        $recordType = Get-SignetTranscriptRecordText -Record $record -PropertyNames @("type")
        if ([string]::IsNullOrWhiteSpace($recordType)) {
            continue
        }

        $data = if ($record.PSObject.Properties.Name -contains "data") { $record.data } else { $null }
        if ($recordType -eq "user.message" -and $null -ne $data) {
            $text = Get-SignetTranscriptRecordText -Record $data -PropertyNames @("content", "text", "message")
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $conversationLines.Add("User: $text")
            }

            continue
        }

        if ($recordType -eq "assistant.message" -and $null -ne $data) {
            $text = Get-SignetTranscriptRecordText -Record $data -PropertyNames @("content", "text", "message")
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $conversationLines.Add("Assistant: $text")
            }

            continue
        }
    }

    if ($parsedCount -gt 0 -and $conversationLines.Count -gt 0) {
        return ($conversationLines -join [Environment]::NewLine)
    }

    return $RawTranscript
}

function Get-SignetPreCompactionExtractionSessionKey {
    param(
        [string]$BaseSessionKey,
        [object]$State
    )

    $sequence = 0
    if ($null -ne $State -and $null -ne $State.preCompactionCount) {
        try {
            $sequence = [Math]::Max([int]$State.preCompactionCount, 0)
        }
        catch {
            $sequence = 0
        }
    }

    return "{0}::precompact::{1}" -f $BaseSessionKey, ($sequence + 1)
}