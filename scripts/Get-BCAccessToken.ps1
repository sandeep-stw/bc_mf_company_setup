#Requires -Version 5.1
<#
.SYNOPSIS
    Acquires a Microsoft Entra access token for the Business Central API.

.DESCRIPTION
    Uses the OAuth 2.0 client credentials flow. Credentials are read from the
    environment (or a gitignored .env file). The token is never written to disk.

    Required environment variables:
      BC_TENANT_ID
      BC_CLIENT_ID
      BC_CLIENT_SECRET

    Optional:
      BC_TOKEN_SCOPE   Default: https://api.businesscentral.dynamics.com/.default

    Dot-source this file to use Get-BCAccessToken from other scripts:
      . "$PSScriptRoot/Get-BCAccessToken.ps1"
      $token = Get-BCAccessToken

.EXAMPLE
    pwsh -File scripts/Get-BCAccessToken.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-BCDotEnv {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Path
    )

    if (-not $Path) {
        $candidates = @()
        if ($PSScriptRoot) {
            $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
        }
        $candidates += (Join-Path (Get-Location) '.env')
    }
    else {
        $candidates = @($Path)
    }

    $envFile = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $envFile) {
        return
    }

    Get-Content -LiteralPath $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            return
        }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            return
        }

        $name = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.Length -ge 2 -and (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            return
        }

        $existing = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($existing)) {
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

function Get-BCHttpErrorBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    $response = $ErrorRecord.Exception.Response
    if ($response -is [System.Net.Http.HttpResponseMessage] -and $null -ne $response.Content) {
        try {
            return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch {
            return $null
        }
    }

    if ($response -is [System.Net.HttpWebResponse]) {
        try {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                return $reader.ReadToEnd()
            }
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-BCSafeAuthErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Raw
    )

    $text = $Raw
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'The token endpoint returned an error with no body.'
    }

    try {
        $json = $text | ConvertFrom-Json
        $parts = @()
        if ($json.error) { $parts += [string]$json.error }
        if ($json.error_description) { $parts += [string]$json.error_description }
        if ($json.error_codes) { $parts += ("error_codes=" + ($json.error_codes -join ',')) }
        if ($parts.Count -gt 0) {
            $text = $parts -join ' — '
        }
    }
    catch {
        # Keep the raw body when it is not JSON.
    }

    $text = $text -replace '(?i)client_secret=[^&\s]+', 'client_secret=***'
    $text = $text -replace '(?i)"client_secret"\s*:\s*"[^"]*"', '"client_secret":"***"'
    return $text.Trim()
}

function Get-BCAccessToken {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $TenantId = $env:BC_TENANT_ID,
        [string] $ClientId = $env:BC_CLIENT_ID,
        [string] $ClientSecret = $env:BC_CLIENT_SECRET,
        [string] $Scope = $env:BC_TOKEN_SCOPE
    )

    Import-BCDotEnv

    if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = $env:BC_TENANT_ID }
    if ([string]::IsNullOrWhiteSpace($ClientId)) { $ClientId = $env:BC_CLIENT_ID }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { $ClientSecret = $env:BC_CLIENT_SECRET }
    if ([string]::IsNullOrWhiteSpace($Scope)) { $Scope = $env:BC_TOKEN_SCOPE }
    if ([string]::IsNullOrWhiteSpace($Scope)) {
        $Scope = 'https://api.businesscentral.dynamics.com/.default'
    }

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($TenantId)) { $missing += 'BC_TENANT_ID' }
    if ([string]::IsNullOrWhiteSpace($ClientId)) { $missing += 'BC_CLIENT_ID' }
    if ([string]::IsNullOrWhiteSpace($ClientSecret)) { $missing += 'BC_CLIENT_SECRET' }
    if ($missing.Count -gt 0) {
        throw "Missing required environment variable(s): $($missing -join ', '). Copy .env.example to .env and set values."
    }

    $placeholder = '00000000-0000-0000-0000-000000000000'
    if ($TenantId -eq $placeholder -or $ClientId -eq $placeholder) {
        throw 'BC_TENANT_ID or BC_CLIENT_ID still has the placeholder value from .env.example.'
    }

    $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    $protocols = [System.Net.ServicePointManager]::SecurityProtocol
    if (($protocols -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols -bor $tls12
    }

    Write-Verbose "Requesting Business Central access token from Microsoft Entra (tenant $TenantId)."

    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        $raw = Get-BCHttpErrorBody -ErrorRecord $_
        $safe = if ($raw) { Get-BCSafeAuthErrorMessage -Raw $raw } else { $_.Exception.Message }
        throw "Failed to acquire a Business Central access token. $safe"
    }

    if (-not $response.PSObject.Properties['access_token'] -or -not $response.access_token) {
        throw 'Token endpoint succeeded but did not return access_token.'
    }

    $expiresIn = 0
    if ($response.PSObject.Properties['expires_in'] -and $response.expires_in) {
        $expiresIn = [int]$response.expires_in
    }

    $tokenType = 'Bearer'
    if ($response.PSObject.Properties['token_type'] -and $response.token_type) {
        $tokenType = [string]$response.token_type
    }

    [pscustomobject]@{
        AccessToken = [string]$response.access_token
        TokenType   = $tokenType
        ExpiresIn   = $expiresIn
        ExpiresOn   = (Get-Date).ToUniversalTime().AddSeconds($expiresIn)
        Scope       = $Scope
    }
}

$script:IsDotSourced = $MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -match '^\s*\.\s+'
if (-not $script:IsDotSourced) {
    $result = Get-BCAccessToken
    Write-Output $result.AccessToken
}
