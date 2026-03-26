param(
    [string]$AgentId = "signet-vscode-custom-agent"
)

. (Join-Path $PSScriptRoot "signet-transcript-state.ps1")

$ErrorActionPreference = "SilentlyContinue"

$harnessName = "vscode-custom-agent"
$daemonUrl = "http://127.0.0.1:3850"
$generatedDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\generated"))
$script:HookInputRaw = ($input | Out-String)

function Get-HookInputObject {
    $hookInput = $script:HookInputRaw

    if ([string]::IsNullOrWhiteSpace($hookInput) -and [Console]::IsInputRedirected) {
        $hookInput = [Console]::In.ReadToEnd()
    }

    if ([string]::IsNullOrWhiteSpace($hookInput)) {
        return @{}
    }

    try {
        $parsed = $hookInput | ConvertFrom-Json -Depth 10
        if ($null -eq $parsed) {
            return @{}
        }

        return $parsed
    }
    catch {
        return @{}
    }
}

try {
    $hookInput = Get-HookInputObject
    $sessionKey = Get-SignetSessionKey -HookInput $hookInput
    $sessionStatePath = Get-SignetTranscriptStatePath -GeneratedDir $generatedDir -HookInput $hookInput -AgentIdentity $AgentId
    $transcriptState = Read-SignetTranscriptState -Path $sessionStatePath
    $transcriptPath = Get-SignetHookTranscriptPath -HookInput $hookInput

    # PreCompact is lightweight: only send session metadata for compaction guidance
    # Full transcript extraction happens at Stop, not here
    if (-not [string]::IsNullOrWhiteSpace($sessionKey) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
        $body = @{
            harness = $harnessName
            agentId = $AgentId
            sessionKey = $sessionKey
            sessionId = $sessionKey
            transcript_path = $transcriptPath
            trigger = "pre_compaction"
        }

        if ($null -ne $hookInput.cwd) {
            $body.cwd = $hookInput.cwd
        }

        # Send lightweight metadata to Signet for compaction guidance
        # Failures are soft — compaction must still proceed
        try {
            Invoke-RestMethod -Method Post -Uri "$daemonUrl/api/hooks/pre-compaction" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 5 | Out-Null
        }
        catch {
            # Signet unavailable or timeout — not fatal, continue
        }

        # Track pre-compaction event in state for Stop hook
        $nextCount = 1
        if ($null -ne $transcriptState -and $null -ne $transcriptState.preCompactionCount) {
            try {
                $nextCount = [int]$transcriptState.preCompactionCount + 1
            }
            catch {
                $nextCount = 1
            }
        }

        $nextState = @{
            agentId = $AgentId
            sessionKey = $sessionKey
            sessionId = $hookInput.sessionId
            transcriptPath = $transcriptPath
            preCompactionCount = $nextCount
            updatedAtUtc = [DateTime]::UtcNow.ToString("o")
        }

        Write-SignetTranscriptState -Path $sessionStatePath -State $nextState
    }
}
catch {
}

@{
    continue = $true
} | ConvertTo-Json -Depth 3
