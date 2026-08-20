#Requires -Version 5.1
<#
.SYNOPSIS
    Offline tests for the BCM-012 BC API helper module (no live Business Central calls).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'BCApi.psd1'
Import-Module $modulePath -Force

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

$base = 'https://api.businesscentral.dynamics.com/v2.0/tenant-guid/sandbox'

$companies = Get-BCApiUri -Path 'companies' -BaseUrl $base
Assert-True 'GET companies URL' ($companies -eq "$base/api/v2.0/companies") $companies

$full = Get-BCApiUri -Path 'https://example.com/api/v2.0/companies' -Filter "name eq 'Apex'"
Assert-True 'full URL keeps host and adds $filter' ($full -match '^https://example.com/api/v2.0/companies\?\$filter=') $full

$companyId = '11111111-1111-1111-1111-111111111111'
$items = Get-BCApiUri -Path 'items' -CompanyId $companyId -BaseUrl $base -Top 20 -Filter "number eq 'FG-001'"
Assert-True 'company-scoped items URL' ($items.StartsWith("$base/api/v2.0/companies($companyId)/items?")) $items
Assert-True 'includes $top' ($items -match '\$top=20') $items
Assert-True 'includes encoded $filter' ($items -match '\$filter=') $items

$apex = Get-BCApiUri -Path 'workCenters' -CompanyId $companyId -BaseUrl $base -ApiPublisher 'apex' -ApiGroup 'manufacturing' -ApiVersion 'v1.0'
Assert-True 'custom apex manufacturing URL' ($apex -eq "$base/api/apex/manufacturing/v1.0/companies($companyId)/workCenters") $apex

$noScope = Get-BCApiUri -Path "companies($companyId)" -BaseUrl $base
Assert-True 'does not double-prefix companies()' ($noScope -eq "$base/api/v2.0/companies($companyId)") $noScope

$err = Get-BCApiErrorMessage -StatusCode 400 -Method PATCH -Uri 'https://example.com/items?access_token=secret' -Body '{"error":{"code":"Internal_InvalidInput","message":"The field is invalid."}}'
Assert-True 'error includes HTTP status' ($err -match 'HTTP 400') $err
Assert-True 'error includes BC code' ($err -match 'Internal_InvalidInput') $err
Assert-True 'error includes BC message' ($err -match 'The field is invalid') $err
Assert-True 'error redacts access_token' ($err -notmatch 'secret') $err

try {
    $null = Get-BCCompanyId -CompanyId '00000000-0000-0000-0000-000000000000'
    Assert-True 'placeholder company id throws' $false 'did not throw'
}
catch {
    Assert-True 'placeholder company id throws' ($_.Exception.Message -match 'BC_COMPANY_ID') $_.Exception.Message
}

Clear-BCApiLog
Set-BCApiHttpHandler -Handler {
    param($Method, $Uri, $Headers, $Body)
    if ($Uri -match 'page=1' -or $Uri -match '/items$') {
        return [pscustomobject]@{
            StatusCode = 200
            Reason     = 'OK'
            Content    = '{"value":[{"id":"1"}],"@odata.nextLink":"https://example.com/api/v2.0/items?page=2"}'
            ETag       = $null
            IsSuccess  = $true
        }
    }
    if ($Uri -match 'page=2') {
        return [pscustomobject]@{
            StatusCode = 200
            Reason     = 'OK'
            Content    = '{"value":[{"id":"2"}]}'
            ETag       = $null
            IsSuccess  = $true
        }
    }
    throw "unexpected URI $Uri"
}

$fakeToken = [pscustomobject]@{
    AccessToken = 'test-token'
    TokenType   = 'Bearer'
    ExpiresOn   = (Get-Date).ToUniversalTime().AddHours(1)
}

$page = Invoke-BCApiGet -Uri 'https://example.com/api/v2.0/items' -Token $fakeToken
Assert-True 'GET first page has one value' (@($page.value).Count -eq 1) (@($page.value).Count)
Assert-True 'GET first page has nextLink' ([bool]$page.'@odata.nextLink') ([string]$page.'@odata.nextLink')

$all = @(Invoke-BCApiGet -Uri 'https://example.com/api/v2.0/items' -AllPages -Token $fakeToken)
Assert-True 'GET -AllPages concatenates pages' ($all.Count -eq 2) ($all.Count)

Set-BCApiHttpHandler -Handler {
    param($Method, $Uri, $Headers, $Body)
    if ($Body -notmatch 'FG-001') { throw "POST body missing FG-001: $Body" }
    [pscustomobject]@{
        StatusCode = 201
        Reason     = 'Created'
        Content    = '{"id":"new","number":"FG-001"}'
        ETag       = 'W/"etag"'
        IsSuccess  = $true
    }
}
$created = Invoke-BCApiPost -Path 'https://example.com/api/v2.0/items' -Body @{ number = 'FG-001' } -Token $fakeToken
Assert-True 'POST returns created entity' ($created.number -eq 'FG-001') ($created.number)

Set-BCApiHttpHandler -Handler {
    param($Method, $Uri, $Headers, $Body)
    if ($Method -ne 'PATCH') { throw "expected PATCH, got $Method" }
    if ($Headers['If-Match'] -ne 'W/"abc"') { throw "If-Match was $($Headers['If-Match'])" }
    return [pscustomobject]@{
        StatusCode = 200
        Reason     = 'OK'
        Content    = '{"displayName":"Updated"}'
        ETag       = 'W/"abc"'
        IsSuccess  = $true
    }
}
$patched = Invoke-BCApiPatch -Path 'https://example.com/api/v2.0/items(1)' -Body @{ displayName = 'Updated' } -IfMatch 'W/"abc"' -Token $fakeToken
Assert-True 'PATCH returns entity' ($patched.displayName -eq 'Updated') ($patched.displayName)

Set-BCApiHttpHandler -Handler {
    param($Method, $Uri, $Headers, $Body)
    if ($Method -ne 'DELETE') { throw "expected DELETE, got $Method" }
    return [pscustomobject]@{
        StatusCode = 204
        Reason     = 'No Content'
        Content    = $null
        ETag       = $null
        IsSuccess  = $true
    }
}
$deleted = Invoke-BCApiDelete -Path 'https://example.com/api/v2.0/items(1)' -IfMatch '*' -Token $fakeToken
Assert-True 'DELETE returns true' ($deleted -eq $true) ([string]$deleted)

Set-BCApiHttpHandler -Handler {
    param($Method, $Uri, $Headers, $Body)
    return [pscustomobject]@{
        StatusCode = 404
        Reason     = 'Not Found'
        Content    = '{"error":{"code":"Internal_EntityNotFound","message":"Item missing."}}'
        ETag       = $null
        IsSuccess  = $false
    }
}
try {
    $null = Invoke-BCApiGet -Uri 'https://example.com/api/v2.0/items(missing)' -Token $fakeToken
    Assert-True 'GET error is thrown' $false 'did not throw'
}
catch {
    Assert-True 'GET error surfaces BC code' ($_.Exception.Message -match 'Internal_EntityNotFound') $_.Exception.Message
}

$log = @(Get-BCApiLog)
Assert-True 'logging captured requests' ($log.Count -gt 0) ($log.Count)
Assert-True 'log has no raw test-token as query' (-not ($log | Where-Object { $_.Uri -match 'test-token=' })) (($log | Select-Object -ExpandProperty Uri) -join ';')

Set-BCApiHttpHandler -Handler $null
Clear-BCApiLog

Write-Output ""
Write-Output "Passed: $passed  Failed: $failed"
if ($failed -gt 0) {
    exit 1
}
