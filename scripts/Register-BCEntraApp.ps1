#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or updates) the Microsoft Entra application used for Business Central S2S access.

.DESCRIPTION
    BCM-010 helper. Reads config/entra-app.json and uses Azure CLI to:
      1. Create an app registration (or reuse an existing one by display name / appId)
      2. Assign Dynamics 365 Business Central application permissions
      3. Create a client secret
      4. Optionally grant admin consent

    Prerequisites:
      - Azure CLI (az) installed and logged in with rights to create app registrations
      - Application administrator (or Global administrator) for admin consent

    The script never writes the client secret to disk. Copy the printed values into
    your local gitignored .env. Business Central "Microsoft Entra Applications"
    card setup remains a manual step (see config/entra-app-checklist.md).

.PARAMETER ConfigPath
    Path to entra-app.json. Defaults to config/entra-app.json next to the repo root.

.PARAMETER DisplayName
    Override the app display name from config.

.PARAMETER AppId
    Existing Application (client) ID to update instead of creating a new registration.

.PARAMETER SecretValidityMonths
    Client secret lifetime in months. Defaults to config (24).

.PARAMETER GrantAdminConsent
    Grant admin consent for the assigned application permissions.

.PARAMETER AllowNoSubscriptions
    Pass --allow-no-subscriptions to az login guidance when the tenant has no Azure subscription.

.EXAMPLE
    az login --allow-no-subscriptions
    pwsh -File scripts/Register-BCEntraApp.ps1 -GrantAdminConsent
#>

[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $DisplayName,
    [string] $AppId,
    [int] $SecretValidityMonths,
    [switch] $GrantAdminConsent,
    [switch] $AllowNoSubscriptions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RepoRoot {
    if ($PSScriptRoot) {
        return (Split-Path -Parent $PSScriptRoot)
    }
    return (Get-Location).Path
}

function Read-EntraAppConfig {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Entra app config not found: $Path"
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $config = $raw | ConvertFrom-Json
    if (-not $config.displayName) {
        throw "Config is missing displayName: $Path"
    }
    if (-not $config.businessCentralResource -or -not $config.businessCentralResource.resourceAppId) {
        throw "Config is missing businessCentralResource.resourceAppId: $Path"
    }
    if (-not $config.applicationPermissions -or @($config.applicationPermissions).Count -lt 1) {
        throw "Config must declare at least one applicationPermissions entry: $Path"
    }

    return $config
}

function Assert-AzCli {
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) {
        throw @"
Azure CLI (az) was not found on PATH.
Install Azure CLI, then sign in:
  az login$(if ($AllowNoSubscriptions) { ' --allow-no-subscriptions' })
See config/entra-app-checklist.md for the manual portal steps.
"@
    }
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $AzArgs
    )

    $output = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($output | Out-String).Trim()
        throw "Azure CLI failed ($LASTEXITCODE): az $($AzArgs -join ' ')`n$text"
    }

    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq 'None' -or $text -eq 'null') {
        return $null
    }

    return ($text | ConvertFrom-Json)
}

function Get-SignedInTenantId {
    $account = Invoke-AzJson -AzArgs @('account', 'show', '-o', 'json')
    if (-not $account -or -not $account.tenantId) {
        $hint = 'az login'
        if ($AllowNoSubscriptions) {
            $hint = 'az login --allow-no-subscriptions'
        }
        throw "Unable to read the signed-in tenant. Run: $hint"
    }
    return [string]$account.tenantId
}

function Find-AppByDisplayName {
    param([Parameter(Mandatory = $true)][string] $Name)

    $filter = "displayName eq '$Name'"
    $apps = Invoke-AzJson -AzArgs @(
        'ad', 'app', 'list',
        '--filter', $filter,
        '-o', 'json'
    )
    if (-not $apps) {
        return $null
    }

    $list = @($apps)
    if ($list.Count -eq 0) {
        return $null
    }
    if ($list.Count -gt 1) {
        $ids = ($list | ForEach-Object { $_.appId }) -join ', '
        throw "Multiple app registrations named '$Name' were found ($ids). Pass -AppId to select one."
    }
    return $list[0]
}

function New-RequiredResourceAccessJson {
    param(
        [Parameter(Mandatory = $true)] $Config
    )

    $resourceAccess = @()
    foreach ($permission in @($Config.applicationPermissions)) {
        if (-not $permission.id -or -not $permission.type) {
            throw "Each applicationPermissions entry needs id and type."
        }
        $resourceAccess += @{
            id   = [string]$permission.id
            type = [string]$permission.type
        }
    }

    $payload = @(
        @{
            resourceAppId  = [string]$Config.businessCentralResource.resourceAppId
            resourceAccess = $resourceAccess
        }
    )

    return ($payload | ConvertTo-Json -Depth 6 -Compress)
}

function Ensure-AppRegistration {
    param(
        [Parameter(Mandatory = $true)] $Config,
        [string] $ExistingAppId,
        [string] $Name
    )

    if ($ExistingAppId) {
        $app = Invoke-AzJson -AzArgs @('ad', 'app', 'show', '--id', $ExistingAppId, '-o', 'json')
        if (-not $app) {
            throw "No app registration found for AppId $ExistingAppId."
        }
        Write-Host "Using existing app registration $($app.appId) ($($app.displayName))."
        return $app
    }

    $existing = Find-AppByDisplayName -Name $Name
    if ($existing) {
        Write-Host "Reusing existing app registration $($existing.appId) ($Name)."
        return $existing
    }

    Write-Host "Creating app registration '$Name'..."
    $createArgs = @(
        'ad', 'app', 'create',
        '--display-name', $Name,
        '--sign-in-audience', ([string]$Config.signInAudience),
        '-o', 'json'
    )

    if ($Config.redirectUris -and @($Config.redirectUris).Count -gt 0) {
        $uriArgs = @()
        foreach ($uri in @($Config.redirectUris)) {
            $uriArgs += [string]$uri
        }
        $createArgs += @('--web-redirect-uris') + $uriArgs
    }

    return (Invoke-AzJson -AzArgs $createArgs)
}

function Set-AppPermissions {
    param(
        [Parameter(Mandatory = $true)][string] $ApplicationId,
        [Parameter(Mandatory = $true)] $Config
    )

    $resourceAppId = [string]$Config.businessCentralResource.resourceAppId
    $permissionArgs = @()
    foreach ($permission in @($Config.applicationPermissions)) {
        if (-not $permission.id -or -not $permission.type) {
            throw "Each applicationPermissions entry needs id and type."
        }
        $permissionArgs += ("{0}={1}" -f [string]$permission.id, [string]$permission.type)
    }

    Write-Host "Assigning Business Central application permissions..."
    # permission add is idempotent enough for re-runs; ignore "already exists" style failures.
    $addOutput = & az ad app permission add `
        --id $ApplicationId `
        --api $resourceAppId `
        --api-permissions @permissionArgs `
        2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($addOutput | Out-String).Trim()
        if ($text -notmatch '(?i)already|conflict|exists') {
            throw "Failed to add API permissions: $text"
        }
        Write-Host 'Permissions already present; continuing.'
    }

    # Keep requiredResourceAccess in sync for portal visibility on older CLI builds.
    $json = New-RequiredResourceAccessJson -Config $Config
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temp, $json)
        & az ad app update --id $ApplicationId --required-resource-accesses "@$temp" 2>&1 | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function New-AppClientSecret {
    param(
        [Parameter(Mandatory = $true)][string] $ApplicationId,
        [Parameter(Mandatory = $true)][string] $SecretDisplayName,
        [Parameter(Mandatory = $true)][int] $ValidityMonths
    )

    $endDate = (Get-Date).ToUniversalTime().AddMonths($ValidityMonths).ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "Creating client secret '$SecretDisplayName' (valid until $endDate)..."
    $credential = Invoke-AzJson -AzArgs @(
        'ad', 'app', 'credential', 'reset',
        '--id', $ApplicationId,
        '--append',
        '--display-name', $SecretDisplayName,
        '--end-date', $endDate,
        '-o', 'json'
    )

    if (-not $credential -or -not $credential.password) {
        throw 'Client secret was created but Azure CLI did not return password.'
    }

    return [string]$credential.password
}

function Grant-AppAdminConsent {
    param(
        [Parameter(Mandatory = $true)][string] $ApplicationId
    )

    Write-Host "Granting admin consent for $ApplicationId..."
    & az ad app permission admin-consent --id $ApplicationId 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning @"
Admin consent via Azure CLI failed. Grant consent in the Entra portal
(API permissions → Grant admin consent) or from Business Central
(Microsoft Entra Applications → Grant Consent).
"@
    }
    else {
        Write-Host 'Admin consent granted.'
    }
}

function Write-EnvGuidance {
    param(
        [Parameter(Mandatory = $true)][string] $TenantId,
        [Parameter(Mandatory = $true)][string] $ClientId,
        [Parameter(Mandatory = $true)][string] $ClientSecret,
        [Parameter(Mandatory = $true)][string] $EnvironmentName
    )

    $apiBase = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$EnvironmentName"

    Write-Host ''
    Write-Host 'Entra application is ready. Copy these values into your local .env (never commit .env):'
    Write-Host "BC_TENANT_ID=$TenantId"
    Write-Host "BC_CLIENT_ID=$ClientId"
    Write-Host "BC_CLIENT_SECRET=$ClientSecret"
    Write-Host "BC_ENVIRONMENT_NAME=$EnvironmentName"
    Write-Host "BC_API_BASE_URL=$apiBase"
    Write-Host ''
    Write-Host 'Still required in Business Central (manual):'
    Write-Host '  Microsoft Entra Applications → New → Client ID + Enabled'
    Write-Host '  Permission sets: D365 AUTOMATION, EXTEN. MGT. - ADMIN (not SUPER)'
    Write-Host 'See config/entra-app-checklist.md for the full checklist.'
}

# --- main ---

Assert-AzCli

$repoRoot = Get-RepoRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'config/entra-app.json'
}

$config = Read-EntraAppConfig -Path $ConfigPath
$name = if ($DisplayName) { $DisplayName } else { [string]$config.displayName }
if ($PSBoundParameters.ContainsKey('SecretValidityMonths')) {
    if ($SecretValidityMonths -lt 1 -or $SecretValidityMonths -gt 24) {
        throw 'SecretValidityMonths must be between 1 and 24.'
    }
    $months = $SecretValidityMonths
}
elseif ($config.clientSecret -and $config.clientSecret.defaultValidityMonths) {
    $months = [int]$config.clientSecret.defaultValidityMonths
}
else {
    $months = 24
}

$secretName = 'apex-bc-automation'
if ($config.clientSecret -and $config.clientSecret.displayName) {
    $secretName = [string]$config.clientSecret.displayName
}

$tenantId = Get-SignedInTenantId
$app = Ensure-AppRegistration -Config $config -ExistingAppId $AppId -Name $name
$applicationObjectOrAppId = [string]$app.appId

Set-AppPermissions -ApplicationId $applicationObjectOrAppId -Config $config

# Ensure a service principal exists before admin consent.
try {
    $sp = Invoke-AzJson -AzArgs @('ad', 'sp', 'show', '--id', $applicationObjectOrAppId, '-o', 'json')
}
catch {
    $sp = $null
}
if (-not $sp) {
    Write-Host 'Creating service principal for the app registration...'
    Invoke-AzJson -AzArgs @(
        'ad', 'sp', 'create',
        '--id', $applicationObjectOrAppId,
        '-o', 'json'
    ) | Out-Null
}

$clientSecret = New-AppClientSecret -ApplicationId $applicationObjectOrAppId -SecretDisplayName $secretName -ValidityMonths $months

if ($GrantAdminConsent) {
    Grant-AppAdminConsent -ApplicationId $applicationObjectOrAppId
}
else {
    Write-Host 'Skipping admin consent (pass -GrantAdminConsent to attempt it).'
}

$environmentName = $env:BC_ENVIRONMENT_NAME
if ([string]::IsNullOrWhiteSpace($environmentName)) {
    $environmentName = 'sandbox'
}

Write-EnvGuidance -TenantId $tenantId -ClientId $applicationObjectOrAppId -ClientSecret $clientSecret -EnvironmentName $environmentName

[pscustomobject]@{
    TenantId          = $tenantId
    ClientId          = $applicationObjectOrAppId
    DisplayName       = $name
    SecretDisplayName = $secretName
    SecretExpiresMonths = $months
    GrantAdminConsent = [bool]$GrantAdminConsent
    ConfigPath        = $ConfigPath
}
