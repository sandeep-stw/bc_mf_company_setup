#Requires -Version 5.1
<#
.SYNOPSIS
    Offline tests for BCM-040 Apex company creation (no live Business Central calls).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'New-BCApexCompany.ps1')
Import-Module (Join-Path $PSScriptRoot 'BCApi.psd1') -Force

$failed = 0
$passed = 0

function Assert-True {
    param([string] $Label, [bool] $Condition, [string] $Detail)
    if ($Condition) {
        $script:passed++
        Write-Output "PASS  $Label"
    }
    else {
        $script:failed++
        Write-Output "FAIL  $Label  $Detail"
    }
}

$config = Get-BCApexCompanyConfig
Assert-True 'config default name is APEX' ($config.Name -eq 'APEX') $config.Name
Assert-True 'config display name is Apex Furniture Manufacturing Pvt. Ltd.' ($config.DisplayName -eq 'Apex Furniture Manufacturing Pvt. Ltd.') $config.DisplayName

$cronus = ConvertTo-BCCompanyRecord -Row ([pscustomobject]@{
        id          = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        name        = 'CRONUS USA, Inc.'
        displayName = 'CRONUS USA, Inc.'
    })
$apex = ConvertTo-BCCompanyRecord -Row ([pscustomobject]@{
        id          = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        name        = 'APEX'
        displayName = 'Apex Furniture Manufacturing Pvt. Ltd.'
    })

$seed = Select-BCSeedCompanyId -Company @($cronus, $apex) -Name 'APEX' -DisplayName $config.DisplayName
Assert-True 'seed prefers CRONUS' ($seed -eq $cronus.Id) $seed

try {
    $null = Select-BCSeedCompanyId -Company @($apex) -Name 'APEX' -DisplayName $config.DisplayName
    Assert-True 'seed missing throws' $false 'did not throw'
}
catch {
    Assert-True 'seed missing throws' ($_.Exception.Message -match 'seed company') $_.Exception.Message
}

$fakeToken = [pscustomobject]@{
    AccessToken = 'test-token'
    TokenType   = 'Bearer'
    ExpiresOn   = (Get-Date).ToUniversalTime().AddHours(1)
}

$previousBaseUrl = $env:BC_API_BASE_URL
$previousCompanyId = $env:BC_COMPANY_ID
$global:ApexCompanyTestState = @{ Posted = $false; PostBody = $null }
$env:BC_API_BASE_URL = 'https://api.businesscentral.dynamics.com/v2.0/11111111-1111-1111-1111-111111111111/sandbox'

try {
    Set-BCApiHttpHandler -Handler {
        param($Method, $Uri, $Headers, $Body)
        if ($Method -eq 'GET' -and $Uri -match '/api/v2.0/companies' -and $Uri -notmatch 'automation') {
            return [pscustomobject]@{
                StatusCode = 200
                Reason     = 'OK'
                Content    = '{"value":[{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"APEX","displayName":"Apex Furniture Manufacturing Pvt. Ltd."},{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"CRONUS USA, Inc.","displayName":"CRONUS USA, Inc."}]}'
                ETag       = $null
                IsSuccess  = $true
            }
        }
        if ($Method -eq 'POST') {
            $global:ApexCompanyTestState.Posted = $true
            throw "POST should not run when Apex already exists: $Uri"
        }
        throw "unexpected $Method $Uri"
    }

    $existing = New-BCApexCompany -Token $fakeToken -TimeoutSeconds 0
    Assert-True 'idempotent skip when Apex exists' ($existing.Created -eq $false) ([string]$existing.Created)
    Assert-True 'returns existing Apex id' ($existing.Id -eq $apex.Id) $existing.Id
    Assert-True 'did not POST when existing' (-not $global:ApexCompanyTestState.Posted) ([string]$global:ApexCompanyTestState.Posted)

    $global:ApexCompanyTestState.Posted = $false
    Set-BCApiHttpHandler -Handler {
        param($Method, $Uri, $Headers, $Body)
        if ($Method -eq 'GET' -and $Uri -match '/api/v2.0/companies' -and $Uri -notmatch 'automation') {
            if ($global:ApexCompanyTestState.Posted) {
                $content = '{"value":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"CRONUS USA, Inc.","displayName":"CRONUS USA, Inc."},{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"APEX","displayName":"Apex Furniture Manufacturing Pvt. Ltd."}]}'
            }
            else {
                $content = '{"value":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"CRONUS USA, Inc.","displayName":"CRONUS USA, Inc."}]}'
            }
            return [pscustomobject]@{
                StatusCode = 200
                Reason     = 'OK'
                Content    = $content
                ETag       = $null
                IsSuccess  = $true
            }
        }
        if ($Method -eq 'POST' -and $Uri -match '/api/microsoft/automation/v2.0/companies\(' -and $Uri -match 'automationCompanies') {
            $global:ApexCompanyTestState.Posted = $true
            $global:ApexCompanyTestState.PostBody = $Body
            return [pscustomobject]@{
                StatusCode = 201
                Reason     = 'Created'
                Content    = '{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"APEX","displayName":"Apex Furniture Manufacturing Pvt. Ltd.","evaluationCompany":false,"businessProfileId":""}'
                ETag       = $null
                IsSuccess  = $true
            }
        }
        throw "unexpected $Method $Uri"
    }

    $created = New-BCApexCompany -Token $fakeToken -TimeoutSeconds 0
    Assert-True 'creates when missing' ($created.Created -eq $true) ([string]$created.Created)
    Assert-True 'create uses automationCompanies' ($global:ApexCompanyTestState.Posted -eq $true) ([string]$global:ApexCompanyTestState.Posted)
    Assert-True 'POST body has APEX name' ($global:ApexCompanyTestState.PostBody -match '"name":"APEX"') $global:ApexCompanyTestState.PostBody
    Assert-True 'POST body has full displayName' ($global:ApexCompanyTestState.PostBody -match 'Apex Furniture Manufacturing Pvt. Ltd.') $global:ApexCompanyTestState.PostBody
    Assert-True 'returns new company id' ($created.Id -eq $apex.Id) $created.Id
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
