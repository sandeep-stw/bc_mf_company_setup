#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
    Business Central REST/OData API helpers (BCM-012).

.DESCRIPTION
    Dot-sourced token helper from BCM-011. Callers Import-Module this file (or BCApi.psd1).

    Standard first-party APIs (default):
      {BC_API_BASE_URL}/api/v2.0/...

    Custom Apex manufacturing APIs:
      {BC_API_BASE_URL}/api/apex/manufacturing/v1.0/...
#>

if (-not (Get-Command Get-BCAccessToken -ErrorAction SilentlyContinue)) {
    $tokenScript = Join-Path $PSScriptRoot 'Get-BCAccessToken.ps1'
    if (Test-Path -LiteralPath $tokenScript) {
        . $tokenScript
    }
}

Add-Type -AssemblyName System.Net.Http | Out-Null

$script:CachedToken = $null
$script:HttpClient = $null
$script:BCHttpHandler = $null
$script:BCApiLog = New-Object System.Collections.Generic.List[object]
$script:PlaceholderGuid = '00000000-0000-0000-0000-000000000000'
$script:MaxLogEntries = 500

function Initialize-BCApiTls {
    $tls12 = [System.Net.SecurityProtocolType]::Tls12
    $protocols = [System.Net.ServicePointManager]::SecurityProtocol
    if (($protocols -band $tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols -bor $tls12
    }
}

function Import-BCApiEnvironment {
    if (Get-Command Import-BCDotEnv -ErrorAction SilentlyContinue) {
        Import-BCDotEnv
        return
    }

    $tokenScript = Join-Path $PSScriptRoot 'Get-BCAccessToken.ps1'
    if (Test-Path -LiteralPath $tokenScript) {
        . $tokenScript
        if (Get-Command Import-BCDotEnv -ErrorAction SilentlyContinue) {
            Import-BCDotEnv
        }
    }
}

function Get-BCHttpClient {
    if ($null -eq $script:HttpClient) {
        Initialize-BCApiTls
        $handler = New-Object System.Net.Http.HttpClientHandler
        $script:HttpClient = New-Object System.Net.Http.HttpClient($handler)
        $script:HttpClient.Timeout = [TimeSpan]::FromMinutes(2)
    }
    return $script:HttpClient
}

function Get-BCSanitizedApiUri {
    param([string] $Uri)
    if ([string]::IsNullOrWhiteSpace($Uri)) {
        return $Uri
    }
    $text = $Uri
    $text = $text -replace '(?i)([?&](access_token|client_secret)=)[^&]+', '$1***'
    return $text
}

function Write-BCApiLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,
        [string] $Method,
        [string] $Uri,
        [Nullable[int]] $StatusCode,
        [Nullable[long]] $DurationMs,
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string] $Level = 'Information'
    )

    $entry = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime()
        Level        = $Level
        Message      = $Message
        Method       = $Method
        Uri          = (Get-BCSanitizedApiUri -Uri $Uri)
        StatusCode   = $StatusCode
        DurationMs   = $DurationMs
    }

    $script:BCApiLog.Add($entry)
    while ($script:BCApiLog.Count -gt $script:MaxLogEntries) {
        $script:BCApiLog.RemoveAt(0)
    }

    switch ($Level) {
        'Error' { Write-Error -Message $Message -ErrorAction Continue }
        'Warning' { Write-Warning $Message }
        'Verbose' { Write-Verbose $Message }
        default {
            Write-Verbose $Message
            Write-Information -MessageData $Message -Tags 'BCApi'
        }
    }
}

function Get-BCApiLog {
    <#
    .SYNOPSIS
        Returns in-memory BC API request log entries (no secrets).
    #>
    [CmdletBinding()]
    param()
    return @($script:BCApiLog.ToArray())
}

function Clear-BCApiLog {
    [CmdletBinding()]
    param()
    $script:BCApiLog.Clear()
}

function Set-BCApiHttpHandler {
    <#
    .SYNOPSIS
        Replaces the HTTP transport (for tests). Pass $null to restore HttpClient.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [scriptblock] $Handler
    )
    $script:BCHttpHandler = $Handler
}

function Get-BCApiErrorMessage {
    <#
    .SYNOPSIS
        Builds a safe error string from an HTTP status and OData error body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int] $StatusCode,
        [string] $Body,
        [string] $Method = 'REQUEST',
        [string] $Uri
    )

    $safeUri = Get-BCSanitizedApiUri -Uri $Uri
    $code = $null
    $message = $null

    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        try {
            $json = $Body | ConvertFrom-Json
            if ($json -and $json.PSObject.Properties['error'] -and $json.error) {
                $err = $json.error
                if ($err.PSObject.Properties['code'] -and $err.code) {
                    $code = [string]$err.code
                }
                if ($err.PSObject.Properties['message'] -and $err.message) {
                    $message = [string]$err.message
                }
            }
        }
        catch {
            # Non-JSON body is included truncated below.
        }
    }

    $parts = @("BC API $Method $(if ($safeUri) { $safeUri } else { '(url omitted)' }) failed (HTTP $StatusCode)")
    if ($code) { $parts += $code }
    if ($message) {
        $parts += $message
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Body)) {
        $snippet = $Body.Trim()
        if ($snippet.Length -gt 500) {
            $snippet = $snippet.Substring(0, 500) + '...'
        }
        $snippet = $snippet -replace '(?i)client_secret=[^&\s]+', 'client_secret=***'
        $parts += $snippet
    }

    return ($parts -join ' — ')
}

function Test-BCPlaceholderGuid {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value.Trim() -eq $script:PlaceholderGuid
}

function Get-BCApiBaseUrl {
    <#
    .SYNOPSIS
        Resolves BC_API_BASE_URL (or tenant + environment) without a trailing slash.
    #>
    [CmdletBinding()]
    param(
        [string] $BaseUrl,
        [string] $TenantId,
        [string] $EnvironmentName
    )

    Import-BCApiEnvironment

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = $env:BC_API_BASE_URL }
    if ([string]::IsNullOrWhiteSpace($TenantId)) { $TenantId = $env:BC_TENANT_ID }
    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { $EnvironmentName = $env:BC_ENVIRONMENT_NAME }

    if ([string]::IsNullOrWhiteSpace($BaseUrl) -and -not [string]::IsNullOrWhiteSpace($TenantId) -and -not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
        $BaseUrl = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$EnvironmentName"
    }

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        throw 'Set BC_API_BASE_URL, or both BC_TENANT_ID and BC_ENVIRONMENT_NAME, in .env.'
    }

    return $BaseUrl.Trim().TrimEnd('/')
}

function Get-BCCompanyId {
    <#
    .SYNOPSIS
        Returns BC_COMPANY_ID after loading .env. Throws on missing or placeholder values.
    #>
    [CmdletBinding()]
    param(
        [string] $CompanyId
    )

    Import-BCApiEnvironment
    if ([string]::IsNullOrWhiteSpace($CompanyId)) {
        $CompanyId = $env:BC_COMPANY_ID
    }
    if ([string]::IsNullOrWhiteSpace($CompanyId) -or (Test-BCPlaceholderGuid -Value $CompanyId)) {
        throw 'BC_COMPANY_ID is missing or still the placeholder from .env.example. Run company lookup (BCM-013) first.'
    }
    return $CompanyId.Trim()
}

function ConvertTo-BCOdataQueryString {
    param(
        [hashtable] $Query,
        [string] $Filter,
        [string] $Select,
        [string] $Expand,
        [string] $OrderBy,
        [Nullable[int]] $Top,
        [Nullable[int]] $Skip,
        [switch] $Count
    )

    $pairs = New-Object System.Collections.Generic.List[string]

    function Add-QueryPair {
        param([string] $Name, [string] $Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return }
        $pairs.Add(('{0}={1}' -f $Name, [Uri]::EscapeDataString($Value)))
    }

    if ($Query) {
        foreach ($key in $Query.Keys) {
            Add-QueryPair -Name ([string]$key) -Value ([string]$Query[$key])
        }
    }

    Add-QueryPair -Name '$filter' -Value $Filter
    Add-QueryPair -Name '$select' -Value $Select
    Add-QueryPair -Name '$expand' -Value $Expand
    Add-QueryPair -Name '$orderby' -Value $OrderBy
    if ($PSBoundParameters.ContainsKey('Top') -and $null -ne $Top) {
        Add-QueryPair -Name '$top' -Value ([string][int]$Top)
    }
    if ($PSBoundParameters.ContainsKey('Skip') -and $null -ne $Skip) {
        Add-QueryPair -Name '$skip' -Value ([string][int]$Skip)
    }
    if ($Count) {
        Add-QueryPair -Name '$count' -Value 'true'
    }

    if ($pairs.Count -eq 0) {
        return $null
    }
    return ($pairs -join '&')
}

function Get-BCApiUri {
    <#
    .SYNOPSIS
        Builds a Business Central API URL from a resource path.

    .PARAMETER Path
        Resource path such as 'companies', 'items', or 'items(id)'. A full http(s) URL is returned as-is (query still appended).

    .PARAMETER CompanyId
        When set, company-scopes paths that do not already start with 'companies'.

    .PARAMETER ApiPublisher
        Empty (default) uses first-party api/{ApiVersion}. Use 'apex' for custom manufacturing APIs.

    .PARAMETER ApiGroup
        Required with ApiPublisher (manufacturing).

    .PARAMETER ApiVersion
        Default v2.0 for standard APIs; use v1.0 with publisher apex.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $CompanyId,
        [string] $ApiPublisher,
        [string] $ApiGroup,
        [string] $ApiVersion,
        [string] $BaseUrl,
        [hashtable] $Query,
        [string] $Filter,
        [string] $Select,
        [string] $Expand,
        [string] $OrderBy,
        [Nullable[int]] $Top,
        [Nullable[int]] $Skip,
        [switch] $Count
    )

    $queryString = ConvertTo-BCOdataQueryString -Query $Query -Filter $Filter -Select $Select -Expand $Expand -OrderBy $OrderBy -Top $Top -Skip $Skip -Count:$Count

    $trimmedPath = $Path.Trim()
    if ($trimmedPath -match '^https?://') {
        $uri = $trimmedPath
        if ($queryString) {
            $join = $(if ($uri.Contains('?')) { '&' } else { '?' })
            $uri = $uri + $join + $queryString
        }
        return $uri
    }

    $resolvedBase = Get-BCApiBaseUrl -BaseUrl $BaseUrl
    $trimmedPath = $trimmedPath.TrimStart('/')

    if ([string]::IsNullOrWhiteSpace($ApiVersion)) {
        if (-not [string]::IsNullOrWhiteSpace($ApiPublisher)) {
            $ApiVersion = 'v1.0'
        }
        else {
            $ApiVersion = 'v2.0'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ApiPublisher)) {
        if ([string]::IsNullOrWhiteSpace($ApiGroup)) {
            $ApiGroup = 'manufacturing'
        }
        $prefix = "api/$ApiPublisher/$ApiGroup/$ApiVersion"
    }
    else {
        $prefix = "api/$ApiVersion"
    }

    if (-not [string]::IsNullOrWhiteSpace($CompanyId) -and ($trimmedPath -notmatch '^companies(\(|$)')) {
        $CompanyId = Get-BCCompanyId -CompanyId $CompanyId
        $trimmedPath = "companies($CompanyId)/$trimmedPath"
    }

    $uri = "$resolvedBase/$prefix/$trimmedPath"
    if ($queryString) {
        $uri = $uri + '?' + $queryString
    }
    return $uri
}

function Resolve-BCApiAccessToken {
    param(
        [pscustomobject] $Token
    )

    if ($Token -and $Token.PSObject.Properties['AccessToken'] -and $Token.AccessToken) {
        return $Token
    }

    $now = (Get-Date).ToUniversalTime()
    if ($script:CachedToken -and $script:CachedToken.PSObject.Properties['AccessToken'] -and $script:CachedToken.AccessToken) {
        $expiresOn = $null
        if ($script:CachedToken.PSObject.Properties['ExpiresOn'] -and $script:CachedToken.ExpiresOn) {
            $expiresOn = [datetime]$script:CachedToken.ExpiresOn
            if ($expiresOn.Kind -ne [DateTimeKind]::Utc) {
                $expiresOn = $expiresOn.ToUniversalTime()
            }
        }
        if ($expiresOn -and $expiresOn -gt $now.AddMinutes(2)) {
            return $script:CachedToken
        }
    }

    if (-not (Get-Command Get-BCAccessToken -ErrorAction SilentlyContinue)) {
        throw 'Get-BCAccessToken is not available. Complete BCM-011 (scripts/Get-BCAccessToken.ps1) first.'
    }

    $script:CachedToken = Get-BCAccessToken
    return $script:CachedToken
}

function ConvertTo-BCJsonBody {
    param($Body)

    if ($null -eq $Body) {
        return $null
    }
    if ($Body -is [string]) {
        return $Body
    }
    return ($Body | ConvertTo-Json -Depth 20 -Compress)
}

function Invoke-BCHttp {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        [hashtable] $Headers,
        [string] $Body
    )

    if ($script:BCHttpHandler) {
        $handlerOutput = @(& $script:BCHttpHandler $Method $Uri $Headers $Body)
        return ($handlerOutput | Select-Object -Last 1)
    }

    $client = Get-BCHttpClient
    $request = New-Object System.Net.Http.HttpRequestMessage(
        (New-Object System.Net.Http.HttpMethod ($Method.ToUpperInvariant())),
        $Uri
    )

    try {
        if ($Headers) {
            foreach ($key in $Headers.Keys) {
                $name = [string]$key
                $value = [string]$Headers[$key]
                if ($name -eq 'Content-Type') { continue }
                [void]$request.Headers.TryAddWithoutValidation($name, $value)
            }
        }

        if ($null -ne $Body -and $Method -in @('POST', 'PATCH', 'PUT')) {
            $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, 'application/json')
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $null
        if ($null -ne $response.Content) {
            $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }

        $etag = $null
        if ($response.Headers -and $response.Headers.ETag) {
            $etag = $response.Headers.ETag.ToString()
        }
        elseif ($response.Content -and $response.Content.Headers -and $response.Content.Headers.Contains('ETag')) {
            $etag = [string]($response.Content.Headers.GetValues('ETag') | Select-Object -First 1)
        }

        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Reason     = [string]$response.ReasonPhrase
            Content    = $content
            ETag       = $etag
            IsSuccess  = [bool]$response.IsSuccessStatusCode
        }
    }
    finally {
        $request.Dispose()
    }
}

function ConvertFrom-BCApiResponseBody {
    param([string] $Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }
    return ($Content | ConvertFrom-Json)
}

function Invoke-BCApiRequest {
    <#
    .SYNOPSIS
        Sends one authenticated Business Central API request with error handling and logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
        [string] $Method,
        [Parameter(Mandatory = $true)]
        [string] $Uri,
        $Body,
        [string] $IfMatch,
        [pscustomobject] $Token,
        [switch] $ReturnRepresentation
    )

    if ($Uri -like "*$($script:PlaceholderGuid)*") {
        throw 'BC API URL still contains the placeholder tenant or company GUID from .env.example.'
    }

    $jsonBody = ConvertTo-BCJsonBody -Body $Body
    $attempt = 0
    $maxAttempts = 2

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $tokenObj = Resolve-BCApiAccessToken -Token $Token
        $tokenType = 'Bearer'
        if ($tokenObj.PSObject.Properties['TokenType'] -and $tokenObj.TokenType) {
            $tokenType = [string]$tokenObj.TokenType
        }

        $headers = @{
            Authorization = "$tokenType $($tokenObj.AccessToken)"
            Accept        = 'application/json'
        }

        $preferParts = @('odata.include-annotations="*"')
        if ($ReturnRepresentation -and $Method -in @('POST', 'PATCH', 'PUT')) {
            $preferParts += 'return=representation'
        }
        $headers['Prefer'] = ($preferParts -join ', ')

        if (-not [string]::IsNullOrWhiteSpace($IfMatch) -and $Method -in @('PATCH', 'PUT', 'DELETE')) {
            $headers['If-Match'] = $IfMatch
        }

        $safeUri = Get-BCSanitizedApiUri -Uri $Uri
        Write-BCApiLog -Level Verbose -Method $Method -Uri $Uri -Message "BC API $Method $safeUri (attempt $attempt)"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-BCHttp -Method $Method -Uri $Uri -Headers $headers -Body $jsonBody
        }
        catch {
            $sw.Stop()
            Write-BCApiLog -Level Warning -Method $Method -Uri $Uri -DurationMs $sw.ElapsedMilliseconds -Message "BC API $Method $safeUri transport error: $($_.Exception.Message)"
            throw "BC API $Method $safeUri transport error: $($_.Exception.Message)"
        }
        $sw.Stop()

        Write-BCApiLog -Level Information -Method $Method -Uri $Uri -StatusCode $resp.StatusCode -DurationMs $sw.ElapsedMilliseconds -Message ("BC API {0} {1} -> HTTP {2} in {3}ms" -f $Method, $safeUri, $resp.StatusCode, $sw.ElapsedMilliseconds)

        if ($resp.StatusCode -eq 401 -and $attempt -lt $maxAttempts) {
            Write-BCApiLog -Level Warning -Method $Method -Uri $Uri -StatusCode 401 -Message 'BC API received HTTP 401; refreshing access token and retrying once.'
            $script:CachedToken = $null
            $Token = $null
            continue
        }

        if (-not $resp.IsSuccess) {
            throw (Get-BCApiErrorMessage -StatusCode $resp.StatusCode -Body $resp.Content -Method $Method -Uri $Uri)
        }

        $parsed = ConvertFrom-BCApiResponseBody -Content $resp.Content
        return [pscustomobject]@{
            StatusCode = $resp.StatusCode
            ETag       = $resp.ETag
            Content    = $resp.Content
            Data       = $parsed
        }
    }

    throw "BC API $Method $(Get-BCSanitizedApiUri -Uri $Uri) failed after retry."
}

function Get-BCCollectionValue {
    param($Data)

    if ($null -eq $Data) {
        return @()
    }
    if ($Data.PSObject.Properties['value']) {
        return @($Data.value)
    }
    return @($Data)
}

function Invoke-BCApiGet {
    <#
    .SYNOPSIS
        GET helper with optional OData pagination.

    .PARAMETER AllPages
        Follow @odata.nextLink until complete (capped by MaxPages). Returns the combined value array.

    .PARAMETER Path
        Resource path relative to the API prefix, or a full URL.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Path')]
        [string] $Path,
        [Parameter(Mandatory = $true, ParameterSetName = 'Uri')]
        [string] $Uri,
        [string] $CompanyId,
        [string] $ApiPublisher,
        [string] $ApiGroup,
        [string] $ApiVersion,
        [string] $BaseUrl,
        [hashtable] $Query,
        [string] $Filter,
        [string] $Select,
        [string] $Expand,
        [string] $OrderBy,
        [int] $Top,
        [int] $Skip,
        [switch] $Count,
        [switch] $AllPages,
        [int] $MaxPages = 100,
        [pscustomobject] $Token
    )

    if ($MaxPages -lt 1) {
        throw 'MaxPages must be at least 1.'
    }

    $url = if ($PSCmdlet.ParameterSetName -eq 'Uri') {
        $Uri
    }
    else {
        $uriParams = @{
            Path         = $Path
            CompanyId    = $CompanyId
            ApiPublisher = $ApiPublisher
            ApiGroup     = $ApiGroup
            ApiVersion   = $ApiVersion
            BaseUrl      = $BaseUrl
            Query        = $Query
            Filter       = $Filter
            Select       = $Select
            Expand       = $Expand
            OrderBy      = $OrderBy
            Count        = $Count
        }
        if ($PSBoundParameters.ContainsKey('Top')) { $uriParams['Top'] = $Top }
        if ($PSBoundParameters.ContainsKey('Skip')) { $uriParams['Skip'] = $Skip }
        Get-BCApiUri @uriParams
    }

    $page = 0
    $items = New-Object System.Collections.Generic.List[object]
    $first = $null

    do {
        $page++
        if ($page -gt $MaxPages) {
            throw "BC API GET pagination exceeded MaxPages ($MaxPages). Pass a larger MaxPages or page manually with @odata.nextLink."
        }

        $resp = Invoke-BCApiRequest -Method GET -Uri $url -Token $Token
        $data = $resp.Data
        if ($null -eq $first) {
            $first = $data
        }

        $isCollection = $data -and $data.PSObject.Properties['value']
        if (-not $isCollection) {
            return $data
        }

        foreach ($row in @($data.value)) {
            $items.Add($row)
        }

        $next = $null
        if ($data.PSObject.Properties['@odata.nextLink'] -and $data.'@odata.nextLink') {
            $next = [string]$data.'@odata.nextLink'
        }
        $url = $next
    } while ($AllPages -and $url)

    if ($AllPages) {
        return @($items.ToArray())
    }

    return $first
}

function Resolve-BCIfMatch {
    param(
        [string] $IfMatch,
        $Body
    )

    if (-not [string]::IsNullOrWhiteSpace($IfMatch)) {
        return $IfMatch
    }
    if ($Body -and $Body -isnot [string] -and $Body.PSObject -and $Body.PSObject.Properties['@odata.etag'] -and $Body.'@odata.etag') {
        return [string]$Body.'@odata.etag'
    }
    return '*'
}

function Invoke-BCApiPost {
    <#
    .SYNOPSIS
        POST helper. Sends JSON and returns the created entity (Prefer: return=representation).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        $Body,
        [string] $CompanyId,
        [string] $ApiPublisher,
        [string] $ApiGroup,
        [string] $ApiVersion,
        [string] $BaseUrl,
        [hashtable] $Query,
        [pscustomobject] $Token
    )

    $url = Get-BCApiUri -Path $Path -CompanyId $CompanyId -ApiPublisher $ApiPublisher -ApiGroup $ApiGroup -ApiVersion $ApiVersion -BaseUrl $BaseUrl -Query $Query
    $resp = Invoke-BCApiRequest -Method POST -Uri $url -Body $Body -Token $Token -ReturnRepresentation
    return $resp.Data
}

function Invoke-BCApiPatch {
    <#
    .SYNOPSIS
        PATCH helper. Sets If-Match from -IfMatch, the body's @odata.etag, or '*'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        $Body,
        [string] $CompanyId,
        [string] $IfMatch,
        [string] $ApiPublisher,
        [string] $ApiGroup,
        [string] $ApiVersion,
        [string] $BaseUrl,
        [hashtable] $Query,
        [pscustomobject] $Token
    )

    $etag = Resolve-BCIfMatch -IfMatch $IfMatch -Body $Body
    $url = Get-BCApiUri -Path $Path -CompanyId $CompanyId -ApiPublisher $ApiPublisher -ApiGroup $ApiGroup -ApiVersion $ApiVersion -BaseUrl $BaseUrl -Query $Query
    $resp = Invoke-BCApiRequest -Method PATCH -Uri $url -Body $Body -IfMatch $etag -Token $Token -ReturnRepresentation
    return $resp.Data
}

function Invoke-BCApiDelete {
    <#
    .SYNOPSIS
        DELETE helper. Returns $true on success (HTTP 204).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Path,
        [string] $CompanyId,
        [string] $IfMatch = '*',
        [string] $ApiPublisher,
        [string] $ApiGroup,
        [string] $ApiVersion,
        [string] $BaseUrl,
        [hashtable] $Query,
        [pscustomobject] $Token
    )

    $url = Get-BCApiUri -Path $Path -CompanyId $CompanyId -ApiPublisher $ApiPublisher -ApiGroup $ApiGroup -ApiVersion $ApiVersion -BaseUrl $BaseUrl -Query $Query
    $null = Invoke-BCApiRequest -Method DELETE -Uri $url -IfMatch $IfMatch -Token $Token
    return $true
}

Export-ModuleMember -Function @(
    'Get-BCApiBaseUrl',
    'Get-BCApiUri',
    'Get-BCCompanyId',
    'Get-BCApiErrorMessage',
    'Get-BCApiLog',
    'Clear-BCApiLog',
    'Set-BCApiHttpHandler',
    'Invoke-BCApiRequest',
    'Invoke-BCApiGet',
    'Invoke-BCApiPost',
    'Invoke-BCApiPatch',
    'Invoke-BCApiDelete'
)
