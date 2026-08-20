#Requires -Version 5.1
<#
.SYNOPSIS
    Creates the Apex demo company in a Business Central sandbox (idempotent).

.DESCRIPTION
    BCM-040. Uses the standard companies API to detect an existing company, then
    the Microsoft automation API to create one if needed:

      POST {BC_API_BASE_URL}/api/microsoft/automation/v2.0/companies({seedId})/automationCompanies

    Default identity (config/apex-company.json):
      name         APEX
      displayName  Apex Furniture Manufacturing Pvt. Ltd.

    The seed company is an existing tenant company (typically CRONUS). The created
    company is not initialized (no chart of accounts); later BCM-041+ steps configure it.

    Required environment (see .env.example):
      BC_TENANT_ID, BC_CLIENT_ID, BC_CLIENT_SECRET
      BC_API_BASE_URL or BC_ENVIRONMENT_NAME (sandbox)

.PARAMETER DisplayName
    Override display name from config / BC_COMPANY_NAME.

.PARAMETER CompanyName
    Override internal company name from config (max 30 characters).

.PARAMETER SeedCompanyId
    Existing company GUID used as the automation API parent. Defaults to CRONUS,
    otherwise the first non-Apex company.

.PARAMETER UpdateEnv
    Write BC_COMPANY_ID (and BC_COMPANY_NAME) to the gitignored .env.

.EXAMPLE
    pwsh -File scripts/New-BCApexCompany.ps1 -UpdateEnv
#>

[CmdletBinding()]
param(
    [string] $DisplayName,
    [string] $CompanyName,
    [string] $SeedCompanyId,
    [switch] $UpdateEnv,
    [string] $ConfigPath,
    [string] $EnvPath,
    [int] $TimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PlaceholderGuid = '00000000-0000-0000-0000-000000000000'

function Import-BCApiModule {
    $manifest = Join-Path $PSScriptRoot 'BCApi.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "BC API helper not found: $manifest (complete BCM-012 first)."
    }
    if (-not (Get-Module -Name BCApi)) {
        Import-Module $manifest
    }
}

function Get-BCApexCompanyConfig {
    [CmdletBinding()]
    param(
        [string] $Path,
        [string] $DisplayName,
        [string] $CompanyName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/apex-company.json'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Apex company config not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $config.name -or -not $config.displayName) {
        throw "Config must include name and displayName: $Path"
    }

    if (Get-Command Import-BCDotEnv -ErrorAction SilentlyContinue) {
        Import-BCDotEnv
    }

    $resolvedName = $CompanyName
    if ([string]::IsNullOrWhiteSpace($resolvedName)) { $resolvedName = $env:BC_COMPANY_CODE }
    if ([string]::IsNullOrWhiteSpace($resolvedName)) { $resolvedName = [string]$config.name }

    $resolvedDisplay = $DisplayName
    if ([string]::IsNullOrWhiteSpace($resolvedDisplay)) { $resolvedDisplay = $env:BC_COMPANY_NAME }
    if ([string]::IsNullOrWhiteSpace($resolvedDisplay)) { $resolvedDisplay = [string]$config.displayName }

    $resolvedName = $resolvedName.Trim()
    $resolvedDisplay = $resolvedDisplay.Trim()
    if ($resolvedName.Length -gt 30) {
        throw "Company name '$resolvedName' exceeds the 30-character Business Central company name limit."
    }

    [pscustomobject]@{
        Name        = $resolvedName
        DisplayName = $resolvedDisplay
        ConfigPath  = $Path
    }
}

function ConvertTo-BCCompanyRecord {
    param([Parameter(Mandatory = $true)] $Row)

    $id = $null
    if ($Row.PSObject.Properties['id'] -and $Row.id) { $id = [string]$Row.id }
    $name = ''
    if ($Row.PSObject.Properties['name'] -and $Row.name) { $name = [string]$Row.name }
    $displayName = $name
    if ($Row.PSObject.Properties['displayName'] -and $Row.displayName) {
        $displayName = [string]$Row.displayName
    }

    [pscustomobject]@{
        Id          = $id
        Name        = $name
        DisplayName = $displayName
    }
}

function Test-BCApexCompanyMatch {
    param(
        [Parameter(Mandatory = $true)] $Company,
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] [string] $DisplayName
    )

    $candidates = @($Company.Name, $Company.DisplayName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($candidate in $candidates) {
        if ([string]::Equals($candidate, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ([string]::Equals($candidate, $DisplayName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-BCSandboxCompanies {
    [CmdletBinding()]
    param([pscustomobject] $Token)

    Import-BCApiModule
    $rows = @(Invoke-BCApiGet -Path 'companies' -AllPages -Token $Token)
    $companies = foreach ($row in $rows) {
        ConvertTo-BCCompanyRecord -Row $row
    }
    return @($companies)
}

function Find-ExistingBCApexCompany {
    param(
        [object[]] $Company,
        [string] $Name,
        [string] $DisplayName
    )

    @($Company | Where-Object { Test-BCApexCompanyMatch -Company $_ -Name $Name -DisplayName $DisplayName })
}

function Select-BCSeedCompanyId {
    param(
        [object[]] $Company,
        [string] $SeedCompanyId,
        [string] $Name,
        [string] $DisplayName
    )

    if (-not [string]::IsNullOrWhiteSpace($SeedCompanyId)) {
        if ($SeedCompanyId -eq $script:PlaceholderGuid) {
            throw 'BC seed company ID is still the placeholder GUID.'
        }
        return $SeedCompanyId.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:BC_SEED_COMPANY_ID) -and $env:BC_SEED_COMPANY_ID -ne $script:PlaceholderGuid) {
        return $env:BC_SEED_COMPANY_ID.Trim()
    }

    $others = @($Company | Where-Object { -not (Test-BCApexCompanyMatch -Company $_ -Name $Name -DisplayName $DisplayName) -and $_.Id })
    if ($others.Count -eq 0) {
        throw 'Cannot create the Apex company: the tenant has no existing seed company (for example CRONUS) for the automation API POST.'
    }

    $cronus = @($others | Where-Object {
            $_.Name -match 'CRONUS' -or $_.DisplayName -match 'CRONUS'
        })
    if ($cronus.Count -gt 0) {
        return $cronus[0].Id
    }
    return $others[0].Id
}

function Set-BCApexCompanyIdInEnv {
    param(
        [Parameter(Mandatory = $true)] [string] $CompanyId,
        [string] $DisplayName,
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($CompanyId) -or $CompanyId -eq $script:PlaceholderGuid) {
        throw 'Refusing to write a missing or placeholder company ID to .env.'
    }

    [Environment]::SetEnvironmentVariable('BC_COMPANY_ID', $CompanyId, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($DisplayName)) {
        [Environment]::SetEnvironmentVariable('BC_COMPANY_NAME', $DisplayName, 'Process')
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates += $Path
    }
    else {
        if ($PSScriptRoot) {
            $candidates += (Join-Path (Split-Path -Parent $PSScriptRoot) '.env')
        }
        $candidates += (Join-Path (Get-Location) '.env')
    }

    $envFile = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if (-not $envFile) {
        Write-Verbose 'No .env file found; set BC_COMPANY_ID in the process environment only.'
        return
    }

    $lines = @(Get-Content -LiteralPath $envFile)
    $replacedId = $false
    $replacedName = $false
    $updated = foreach ($line in $lines) {
        if ($line -match '^\s*BC_COMPANY_ID\s*=') {
            $replacedId = $true
            "BC_COMPANY_ID=$CompanyId"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($DisplayName) -and $line -match '^\s*BC_COMPANY_NAME\s*=') {
            $replacedName = $true
            "BC_COMPANY_NAME=$DisplayName"
        }
        else {
            $line
        }
    }
    if (-not $replacedId) { $updated += "BC_COMPANY_ID=$CompanyId" }
    if (-not $replacedName -and -not [string]::IsNullOrWhiteSpace($DisplayName)) {
        $updated += "BC_COMPANY_NAME=$DisplayName"
    }

    Set-Content -LiteralPath $envFile -Value $updated -Encoding utf8
    Write-Verbose "Updated company identity in $(Split-Path -Leaf $envFile)."
}

function New-BCApexCompany {
    <#
    .SYNOPSIS
        Ensures the Apex demo company exists in the Business Central environment.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $DisplayName,
        [string] $CompanyName,
        [string] $SeedCompanyId,
        [string] $ConfigPath,
        [string] $EnvPath,
        [switch] $UpdateEnv,
        [int] $TimeoutSeconds = 120,
        [pscustomobject] $Token
    )

    Import-BCApiModule
    $config = Get-BCApexCompanyConfig -Path $ConfigPath -DisplayName $DisplayName -CompanyName $CompanyName

    Write-Verbose "Ensuring company '$($config.DisplayName)' (name $($config.Name)) exists."

    $companies = Get-BCSandboxCompanies -Token $Token
    $existing = @(Find-ExistingBCApexCompany -Company $companies -Name $config.Name -DisplayName $config.DisplayName)
    if ($existing.Count -gt 1) {
        $names = ($existing | ForEach-Object { $_.DisplayName }) -join ', '
        throw "Multiple companies match Apex ($names). Set BC_COMPANY_NAME to the exact display name."
    }
    if ($existing.Count -eq 1) {
        Write-Verbose "Apex company already exists ($($existing[0].Id)); skipping create."
        $created = $false
        $company = $existing[0]
    }
    else {
        $created = $false
        $createdRow = $null
        $company = $null
        $seedId = Select-BCSeedCompanyId -Company $companies -SeedCompanyId $SeedCompanyId -Name $config.Name -DisplayName $config.DisplayName
        Write-Verbose "Creating Apex company via automation API using seed company $seedId."

        try {
            $createdRow = Invoke-BCApiPost `
                -Path 'automationCompanies' `
                -CompanyId $seedId `
                -ApiPublisher 'microsoft' `
                -ApiGroup 'automation' `
                -ApiVersion 'v2.0' `
                -Body @{
                    name              = $config.Name
                    displayName       = $config.DisplayName
                    businessProfileId = ''
                } `
                -Token $Token
        }
        catch {
            $companies = Get-BCSandboxCompanies -Token $Token
            $existing = @(Find-ExistingBCApexCompany -Company $companies -Name $config.Name -DisplayName $config.DisplayName)
            if ($existing.Count -eq 1) {
                $createdRow = $null
                $company = $existing[0]
                $created = $false
            }
            else {
                throw
            }
        }

        if ($createdRow) {
            $company = ConvertTo-BCCompanyRecord -Row $createdRow
            $created = $true
            $deadline = (Get-Date).AddSeconds([Math]::Max(0, $TimeoutSeconds))
            while ((Get-Date) -lt $deadline) {
                $companies = Get-BCSandboxCompanies -Token $Token
                $found = @(Find-ExistingBCApexCompany -Company $companies -Name $config.Name -DisplayName $config.DisplayName)
                if ($found.Count -ge 1) {
                    $company = $found[0]
                    break
                }
                Start-Sleep -Seconds 2
            }
        }
    }

    if (-not $company.Id) {
        throw "Apex company '$($config.DisplayName)' was created or found but has no id."
    }

    if ($UpdateEnv) {
        Set-BCApexCompanyIdInEnv -CompanyId $company.Id -DisplayName $config.DisplayName -Path $EnvPath
    }
    else {
        [Environment]::SetEnvironmentVariable('BC_COMPANY_ID', $company.Id, 'Process')
        [Environment]::SetEnvironmentVariable('BC_COMPANY_NAME', $config.DisplayName, 'Process')
    }

    [pscustomobject]@{
        Id          = $company.Id
        Name        = $(if ($company.Name) { $company.Name } else { $config.Name })
        DisplayName = $(if ($company.DisplayName) { $company.DisplayName } else { $config.DisplayName })
        Created     = [bool]$created
        Environment = $env:BC_ENVIRONMENT_NAME
    }
}

$script:IsDotSourced = $MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -match '^\s*\.\s+'
if (-not $script:IsDotSourced) {
    $result = New-BCApexCompany -DisplayName $DisplayName -CompanyName $CompanyName -SeedCompanyId $SeedCompanyId -ConfigPath $ConfigPath -EnvPath $EnvPath -UpdateEnv:$UpdateEnv -TimeoutSeconds $TimeoutSeconds
    Write-Output $result.Id
}
