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
    $sessionStatePath = Get-SignetTranscriptStatePath -GeneratedDir $generatedDir -HookInput $hookInput -AgentIdentity $AgentId
    $transcriptState = Read-SignetTranscriptState -Path $sessionStatePath
    $transcriptPath = Get-SignetHookTranscriptPath -HookInput $hookInput
    $sessionKey = Get-SignetSessionKey -HookInput $hookInput

    # Stop is the terminal boundary: full transcript extraction for LLM-based memory extraction
    # This is the ONLY place where memory extraction happens, not at PreCompact
    $body = @{
        harness = $harnessName
        agentId = $AgentId
    }

    if (-not [string]::IsNullOrWhiteSpace($sessionKey)) {
        $body.sessionKey = $sessionKey
        $body.sessionId = $sessionKey
    }

    if ($null -ne $hookInput.cwd) {
        $body.cwd = $hookInput.cwd
    }

    # Forward the transcript path as-is (VS Code provides this in the hook input)
    if (-not [string]::IsNullOrWhiteSpace($transcriptPath)) {
        $body.transcript_path = $transcriptPath
    }

    # Fallback: if VS Code hook provided transcript directly, use it
    if (-not [string]::IsNullOrWhiteSpace($transcriptPath)) {
        try {
            $fullTranscript = [System.IO.File]::ReadAllText($transcriptPath)
            if (-not [string]::IsNullOrWhiteSpace($fullTranscript)) {
                $body.transcript = Convert-SignetTranscriptContent -RawTranscript $fullTranscript
            }
        }
        catch {
            # Transcript file unavailable — send path for Signet to read
        }
    }

    # Fallback: if hook provided transcript directly in payload, use it
    if ((-not $body.ContainsKey("transcript")) -and $null -ne $hookInput.transcript) {
        $body.transcript = Convert-SignetTranscriptContent -RawTranscript $hookInput.transcript
    }

    $response = Invoke-RestMethod -Method Post -Uri "$daemonUrl/api/hooks/session-end" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 10

    if (($response.queued -eq $true) -or (($response.memoriesSaved -as [int]) -ge 0)) {
        Clear-SignetTranscriptState -Path $sessionStatePath
    }
}
catch {
}

@{
    continue = $true
} | ConvertTo-Json -Depth 3
