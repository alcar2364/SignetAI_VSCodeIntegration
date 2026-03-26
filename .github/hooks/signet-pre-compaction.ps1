param(
    [string]$AgentId = "signet-vscode-custom-agent"
)

$ErrorActionPreference = "SilentlyContinue"

$harnessName = "vscode-custom-agent"
$daemonUrl = "http://127.0.0.1:3850"
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

function Get-FirstNonEmptyValue {
    param(
        [object[]]$Values,
        [string]$Default = ""
    )

    foreach ($value in $Values) {
        if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return $Default
}

function Get-HookSessionKey {
    param(
        [object]$HookInput
    )

    return Get-FirstNonEmptyValue -Values @(
        $HookInput.sessionKey,
        $HookInput.sessionId,
        $HookInput.session_key,
        $HookInput.session_id
    )
}

try {
    $hookInput = Get-HookInputObject
    $sessionKey = Get-HookSessionKey -HookInput $hookInput
    $body = @{
        harness = $harnessName
    }

    if (-not [string]::IsNullOrWhiteSpace($sessionKey)) {
        $body.sessionKey = $sessionKey
        $body.sessionId = $sessionKey
    }

    $sessionContext = Get-FirstNonEmptyValue -Values @(
        $hookInput.sessionContext,
        $hookInput.session_context,
        $hookInput.summary,
        $hookInput.compactionSummary
    )
    if (-not [string]::IsNullOrWhiteSpace($sessionContext)) {
        $body.sessionContext = $sessionContext
    }

    $messageCount = $null
    foreach ($candidate in @($hookInput.messageCount, $hookInput.message_count)) {
        if ($candidate -ne $null) {
            try {
                $messageCount = [int]$candidate
                break
            }
            catch {
            }
        }
    }

    if ($messageCount -ne $null) {
        $body.messageCount = $messageCount
    }

    try {
        Invoke-RestMethod -Method Post -Uri "$daemonUrl/api/hooks/pre-compaction" -ContentType "application/json" -Body ($body | ConvertTo-Json -Depth 10) -TimeoutSec 10 | Out-Null
    }
    catch {
        # Signet unavailable or timeout — not fatal, continue
    }
}
catch {
}

@{
    continue = $true
} | ConvertTo-Json -Depth 3
