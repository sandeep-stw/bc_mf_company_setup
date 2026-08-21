#Requires -Version 5.1
<#
.SYNOPSIS
    Lists Business Central companies and resolves the Apex demo company ID.

.DESCRIPTION
    BCM-013. Uses the standard companies API (v2.0) via scripts/BCApi.psd1.

    Required environment (see .env.example):
      BC_TENANT_ID, BC_CLIENT_ID, BC_CLIENT_SECRET
      BC_API_BASE_URL (or BC_TENANT_ID + BC_ENVIRONMENT_NAME)

    Optional:
      BC_COMPANY_NAME   Display name to match (default: Apex Manufacturing)

    Dot-source to call the functions:
      . ./scripts/Get-BCCompanies.ps1
      $companies = Get-BCCompanies
      $apex = Find-BCApexCompany
      $apex.Id

.PARAMETER Name
    Company name or display name to match. Defaults to BC_COMPANY_NAME or Apex Manufacturing.

.PARAMETER List
    Print all companies (Id and display name) instead of resolving Apex.

.PARAMETER UpdateEnv
    Write the resolved company ID to BC_COMPANY_ID in the gitignored .env and the process environment.

.EXAMPLE
    pwsh -File scripts/Get-BCCompanies.ps1

.EXAMPLE
    pwsh -File scripts/Get-BCCompanies.ps1 -List

.EXAMPLE
    pwsh -File scripts/Get-BCCompanies.ps1 -UpdateEnv
#>

[CmdletBinding()]
param(
    [string] $Name,
    [switch] $List,
    [switch] $UpdateEnv,
    [string] $EnvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DefaultApexCompanyName = 'Apex Manufacturing'
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

function Get-BCCompanyNameCandidate {
    param(
        [string] $Name
    )

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name.Trim()
    }
    if (Get-Command Import-BCDotEnv -ErrorAction SilentlyContinue) {
        Import-BCDotEnv
    }
    if (-not [string]::IsNullOrWhiteSpace($env:BC_COMPANY_NAME)) {
        return $env:BC_COMPANY_NAME.Trim()
    }
    return $script:DefaultApexCompanyName
}

function ConvertTo-BCCompany {
    param(
        [Parameter(Mandatory = $true)]
        $Row
    )

    $id = $null
    if ($Row.PSObject.Properties['id'] -and $Row.id) {
        $id = [string]$Row.id
    }

    $name = ''
    if ($Row.PSObject.Properties['name'] -and $Row.name) {
        $name = [string]$Row.name
    }

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

function Test-BCCompanyNameMatch {
    param(
        [Parameter(Mandatory = $true)]
        $Company,
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [switch] $Partial
    )

    $candidates = @($Company.Name, $Company.DisplayName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($candidate in $candidates) {
        if ($Partial) {
            if ($candidate.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
        elseif ([string]::Equals($candidate, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Get-BCCompanies {
    <#
    .SYNOPSIS
        Retrieves all companies from the standard Business Central companies API.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [pscustomobject] $Token
    )

    Import-BCApiModule
    $rows = @(Invoke-BCApiGet -Path 'companies' -AllPages -Token $Token)
    $companies = foreach ($row in $rows) {
        ConvertTo-BCCompany -Row $row
    }
    return @($companies)
}

function Find-BCApexCompany {
    <#
    .SYNOPSIS
        Finds the Apex demo company and returns Id, Name, and DisplayName.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Name,
        [pscustomobject] $Token,
        [object[]] $Company
    )

    $resolvedName = Get-BCCompanyNameCandidate -Name $Name
    if ($PSBoundParameters.ContainsKey('Company')) {
        $companies = @($Company | Where-Object { $null -ne $_ })
    }
    else {
        $companies = @(Get-BCCompanies -Token $Token)
    }

    if (@($companies).Count -eq 0) {
        throw 'No companies were returned by the Business Central companies API.'
    }

    $exact = @($companies | Where-Object { Test-BCCompanyNameMatch -Company $_ -Name $resolvedName })
    if ($exact.Count -eq 1) {
        return $exact[0]
    }
    if ($exact.Count -gt 1) {
        $names = ($exact | ForEach-Object { $_.DisplayName }) -join ', '
        throw "Multiple companies match '$resolvedName': $names"
    }

    $usePartial = $resolvedName.IndexOf('Apex', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($usePartial) {
        $partial = @($companies | Where-Object { Test-BCCompanyNameMatch -Company $_ -Name 'Apex' -Partial })
        if ($partial.Count -eq 1) {
            Write-Verbose "No exact match for '$resolvedName'; using partial Apex match '$($partial[0].DisplayName)'."
            return $partial[0]
        }
        if ($partial.Count -gt 1) {
            $names = ($partial | ForEach-Object { $_.DisplayName }) -join ', '
            throw "Multiple companies contain 'Apex' ($names). Set BC_COMPANY_NAME to the exact display name."
        }
    }

    $available = ($companies | ForEach-Object {
            if ($_.DisplayName) { $_.DisplayName } else { $_.Name }
        }) -join ', '
    throw "Apex demo company '$resolvedName' was not found. Available companies: $available"
}

function Set-BCCompanyIdInEnv {
    <#
    .SYNOPSIS
        Updates BC_COMPANY_ID in .env and the current process. Does not print .env contents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $CompanyId,
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($CompanyId) -or $CompanyId -eq $script:PlaceholderGuid) {
        throw 'Refusing to write a missing or placeholder company ID to .env.'
    }

    [Environment]::SetEnvironmentVariable('BC_COMPANY_ID', $CompanyId, 'Process')

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
    $replaced = $false
    $updated = foreach ($line in $lines) {
        if ($line -match '^\s*BC_COMPANY_ID\s*=') {
            $replaced = $true
            "BC_COMPANY_ID=$CompanyId"
        }
        else {
            $line
        }
    }
    if (-not $replaced) {
        $updated += "BC_COMPANY_ID=$CompanyId"
    }

    Set-Content -LiteralPath $envFile -Value $updated -Encoding utf8
    Write-Verbose "Updated BC_COMPANY_ID in $(Split-Path -Leaf $envFile)."
}

$script:IsDotSourced = $MyInvocation.InvocationName -eq '.' -or $MyInvocation.Line -match '^\s*\.\s+'
if (-not $script:IsDotSourced) {
    Import-BCApiModule
    if ($List) {
        $companies = Get-BCCompanies
        $companies | ForEach-Object {
            '{0}  {1}' -f $_.Id, $(if ($_.DisplayName) { $_.DisplayName } else { $_.Name })
        }
    }
    else {
        $apex = Find-BCApexCompany -Name $Name
        if ($UpdateEnv) {
            Set-BCCompanyIdInEnv -CompanyId $apex.Id -Path $EnvPath
        }
        else {
            [Environment]::SetEnvironmentVariable('BC_COMPANY_ID', $apex.Id, 'Process')
        }
        Write-Output $apex.Id
    }
}
