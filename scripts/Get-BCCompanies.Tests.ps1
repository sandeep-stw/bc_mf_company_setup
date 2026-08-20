#Requires -Version 5.1
<#
.SYNOPSIS
    Offline tests for BCM-013 company lookup (no live Business Central calls).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Get-BCCompanies.ps1')
Import-Module (Join-Path $PSScriptRoot 'BCApi.psd1') -Force

$failed = 0
$passed = 0

function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) {
        $script:passed++
        Write-Output "PASS  $Name"
    }
    else {
        $script:failed++
        Write-Output "FAIL  $Name  $Detail"
    }
}

$cronus = [pscustomobject]@{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; name = 'CRONUS USA, Inc.'; displayName = 'CRONUS USA, Inc.' }
$apex = [pscustomobject]@{ id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; name = 'Apex Manufacturing'; displayName = 'Apex Manufacturing' }
$otherApex = [pscustomobject]@{ id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'; name = 'Apex East'; displayName = 'Apex East' }

$normalized = @(
    (ConvertTo-BCCompany -Row $cronus),
    (ConvertTo-BCCompany -Row $apex)
)
$found = Find-BCApexCompany -Company $normalized
Assert-True 'exact Apex Manufacturing match' ($found.Id -eq $apex.id) $found.Id

$partialOnly = @(
    (ConvertTo-BCCompany -Row $cronus),
    (ConvertTo-BCCompany -Row ([pscustomobject]@{ id = $apex.id; name = 'APEX MFG'; displayName = 'APEX MFG' }))
)
$partial = Find-BCApexCompany -Company $partialOnly
Assert-True 'partial Apex match when exact name missing' ($partial.Id -eq $apex.id) $partial.Id

try {
    $null = Find-BCApexCompany -Company @((ConvertTo-BCCompany -Row $cronus))
    Assert-True 'missing Apex throws' $false 'did not throw'
}
catch {
    Assert-True 'missing Apex lists available companies' ($_.Exception.Message -match 'CRONUS') $_.Exception.Message
}

try {
    $dupes = @(
        (ConvertTo-BCCompany -Row $apex),
        (ConvertTo-BCCompany -Row $otherApex)
    )
    $null = Find-BCApexCompany -Name 'Apex' -Company $dupes
    Assert-True 'ambiguous Apex throws' $false 'did not throw'
}
catch {
    Assert-True 'ambiguous Apex asks for exact name' ($_.Exception.Message -match 'BC_COMPANY_NAME') $_.Exception.Message
}

$fakeToken = [pscustomobject]@{
    AccessToken = 'test-token'
    TokenType   = 'Bearer'
    ExpiresOn   = (Get-Date).ToUniversalTime().AddHours(1)
}

$previousBaseUrl = $env:BC_API_BASE_URL
$previousCompanyId = $env:BC_COMPANY_ID
$env:BC_API_BASE_URL = 'https://api.businesscentral.dynamics.com/v2.0/11111111-1111-1111-1111-111111111111/sandbox'

try {
    Clear-BCApiLog
    Set-BCApiHttpHandler -Handler {
        param($Method, $Uri, $Headers, $Body)
        if ($Method -ne 'GET' -or $Uri -notmatch '/companies') {
            throw "unexpected $Method $Uri"
        }
        return [pscustomobject]@{
            StatusCode = 200
            Reason     = 'OK'
            Content    = '{"value":[{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"Apex Manufacturing","displayName":"Apex Manufacturing"},{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"CRONUS USA, Inc.","displayName":"CRONUS USA, Inc."}]}'
            ETag       = $null
            IsSuccess  = $true
        }
    }

    $companyRows = @(Get-BCCompanies -Token $fakeToken)
    Assert-True 'Get-BCCompanies returns two rows' ($companyRows.Count -eq 2) ($companyRows.Count)

    $fromApi = Find-BCApexCompany -Token $fakeToken
    Assert-True 'Find-BCApexCompany uses companies API' ($fromApi.Id -eq 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') $fromApi.Id

    $envFile = Join-Path ([System.IO.Path]::GetTempPath()) ("bc-company-{0}.env" -f [guid]::NewGuid())
    @(
        'BC_TENANT_ID=11111111-1111-1111-1111-111111111111'
        'BC_COMPANY_ID=00000000-0000-0000-0000-000000000000'
        'BC_CLIENT_SECRET=not-a-real-secret'
    ) | Set-Content -LiteralPath $envFile -Encoding utf8
    try {
        Set-BCCompanyIdInEnv -CompanyId $fromApi.Id -Path $envFile
        $written = Get-Content -LiteralPath $envFile
        Assert-True 'UpdateEnv writes company id' ($written -contains "BC_COMPANY_ID=$($fromApi.Id)") (($written | Where-Object { $_ -like 'BC_COMPANY_ID=*' }) -join ';')
        Assert-True 'UpdateEnv leaves other keys' ($written -contains 'BC_CLIENT_SECRET=not-a-real-secret') 'secret line missing'
        Assert-True 'process env updated' ($env:BC_COMPANY_ID -eq $fromApi.Id) $env:BC_COMPANY_ID
    }
    finally {
        Remove-Item -LiteralPath $envFile -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Set-BCApiHttpHandler -Handler $null
    Clear-BCApiLog
    if ($null -eq $previousBaseUrl) {
        Remove-Item Env:BC_API_BASE_URL -ErrorAction SilentlyContinue
    }
    else {
        $env:BC_API_BASE_URL = $previousBaseUrl
    }
    if ($null -eq $previousCompanyId) {
        Remove-Item Env:BC_COMPANY_ID -ErrorAction SilentlyContinue
    }
    else {
        $env:BC_COMPANY_ID = $previousCompanyId
    }
}

Write-Output ""
Write-Output "Passed: $passed  Failed: $failed"
if ($failed -gt 0) {
    exit 1
}
