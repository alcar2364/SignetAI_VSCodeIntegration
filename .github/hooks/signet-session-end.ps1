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
    $transcriptPath = Get-SignetHookTranscriptPath -HookInput $hookInput
    $sessionKey = Get-SignetSessionKey -HookInput $hookInput
    $effectiveTranscriptPath = $transcriptPath

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

    if ($null -ne $hookInput.reason) {
        $body.reason = $hookInput.reason
    }

    if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and (Test-Path $transcriptPath)) {
        try {
            $rawTranscript = [System.IO.File]::ReadAllText($transcriptPath)
            $normalizedTranscript = Convert-SignetTranscriptContent -RawTranscript $rawTranscript

            # VS Code custom-agent transcripts are JSONL; Signet's generic parser does not currently
            # recognize their user.message / assistant.message shape, so hand off a normalized file.
            if (-not [string]::IsNullOrWhiteSpace($normalizedTranscript) -and ($normalizedTranscript -ne $rawTranscript)) {
                $normalizedTranscriptDir = Join-Path $generatedDir "normalized-transcripts"
                New-Item -ItemType Directory -Path $normalizedTranscriptDir -Force | Out-Null

                $normalizedTranscriptName = "{0}.session-end.txt" -f [System.IO.Path]::GetFileNameWithoutExtension($transcriptPath)
                $effectiveTranscriptPath = Join-Path $normalizedTranscriptDir $normalizedTranscriptName

                [System.IO.File]::WriteAllText(
                    $effectiveTranscriptPath,
                    $normalizedTranscript + [Environment]::NewLine,
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
        }
        catch {
            $effectiveTranscriptPath = $transcriptPath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($effectiveTranscriptPath)) {
        $body.transcriptPath = $effectiveTranscriptPath
    }

    if ((-not $body.ContainsKey("transcriptPath")) -and $null -ne $hookInput.transcript -and $hookInput.transcript -is [string] -and -not [string]::IsNullOrWhiteSpace($hookInput.transcript)) {
        $body.transcript = $hookInput.transcript
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
