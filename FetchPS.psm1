<#
.SYNOPSIS
    Returns metadata about the fetch-ps library.
.DESCRIPTION
    Returns metadata about the fetch-ps library, including repository, license, and version details.
.OUTPUTS
    [PSCustomObject] Project metadata information.
#>

function Get-ProjectInfo {
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        Name        = "fetchPS"
        Repository  = "https://github.com/tom-briz/fetch-ps"
        Description = "Unified HTTP Fetching & Data Structuring Factory for PowerShell"
        License     = "GNU General Public License v3.0"
        Version     = "1.0.0"
        Author      = "tom-briz"
    }
}


<#
 * ============================================================================
 * INTERNAL HELPER UTILITIES
 * ============================================================================
#>

$script:DEFAULT_CONFIG = @{
    # HTTP Request Defaults
    DefaultMethod = "GET"
    DefaultTimeoutMs = 30000
    DefaultDelayMs = 0
    
    # Security: Default regex patterns to mask sensitive data
    DefaultMaskPatterns = @(
        'key=[^&]+',               
        'Authorization:\s*[^\s]+', 
        'password=[^&]+',          
        'token=[^&]+'              
    )
}

# Check PowerShell version for SkipHttpErrorCheck support (PS 7+)
$script:SupportsSkipHttpErrorCheck = ($PSVersionTable.PSVersion.Major -ge 7)

<#
.SYNOPSIS
    Builds and normalizes HTTP request options for PowerShell web operations.
.DESCRIPTION
    Takes a hashtable of input parameters and structures them into standardized 
    request settings including method casing, headers, timeouts, and error muting behavior.
.PARAMETER Params
    A hashtable containing optional configuration keys: Method, Headers, Payload, and Timeout.
.OUTPUTS
    [PSCustomObject] Normalized configuration object for web request execution.
#>
function Build-RequestOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [hashtable]$Params = @{}
    )

    $method = if ($Params.ContainsKey('Method')) { $Params.Method } else { $script:DEFAULT_CONFIG.DefaultMethod }
    $headers = if ($Params.ContainsKey('Headers')) { $Params.Headers } else { @{} }
    $payload = if ($Params.ContainsKey('Payload')) { $Params.Payload } else { $null }
    $timeout = if ($Params.ContainsKey('Timeout')) { $Params.Timeout } else { $script:DEFAULT_CONFIG.DefaultTimeoutMs }
    
    # Mask patterns: Use custom if provided, else global default
    $maskPatterns = if ($Params.ContainsKey('MaskPatterns')) { $Params.MaskPatterns } else { $script:DEFAULT_CONFIG.DefaultMaskPatterns }

    $contentType = if ($headers.ContainsKey('Content-Type')) { $headers['Content-Type'] } else { $null }

    $options = [ordered]@{
        Method             = $method.ToUpper()
        Headers            = $headers
        Body               = $payload
        MaximumRedirection = 10
        ContentType        = $contentType
        TimeoutSec         = [Math]::Ceiling($timeout / 1000)
    }

    if ($script:SupportsSkipHttpErrorCheck) {
        $options['SkipHttpErrorCheck'] = $true
    }

    # Add mask patterns to options for downstream use
    $options['MaskPatterns'] = $maskPatterns
    return [PSCustomObject]$options
}

<#
.SYNOPSIS
    Converts a WebHeaderCollection to a clean PowerShell Hashtable.
.DESCRIPTION
    Parses the .Headers property from an Invoke-WebRequest response.
    Unwraps single-item arrays to scalars for easier access.
.PARAMETER WebHeaders
    The .Headers property from an Invoke-WebRequest response object.
.OUTPUTS
    [hashtable]
#>
function Convert-WebHeadersToHashtable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $WebHeaders
    )

    $headerMap = @{}
    
    if (-not $WebHeaders) { return $headerMap }

    $WebHeaders.GetEnumerator() | ForEach-Object {
        $key = $_.Key
        $val = $_.Value
        
        # Unwrap single-item arrays (e.g., "Content-Type" is often ["application/json"])
        if ($val -is [array] -and $val.Count -eq 1) {
            $headerMap[$key] = $val[0]
        }
        else {
            $headerMap[$key] = $val
        }
    }

    return $headerMap
}

<#
.SYNOPSIS
    Sanitizes a string by replacing sensitive patterns with [REDACTED].
.DESCRIPTION
    Applies all regex patterns from a given array to a string.
#>
function Sanitize-String {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    if (-not $Text -or -not $Patterns -or $Patterns.Count -eq 0) {
        return $Text
    }

    $sanitized = $Text
    foreach ($pattern in $Patterns) {
        try {
            $regex = New-Object System.Text.RegularExpressions.Regex($pattern)
            $sanitized = $regex.Replace($sanitized, '[REDACTED]')
        }
        catch {
            # Silently ignore invalid regex
            Write-Warning "Invalid mask pattern: $pattern"
        }
    }
    return $sanitized
}

<#
.SYNOPSIS
    Centralized parser and formatting factory for PowerShell web responses.
.DESCRIPTION
    Accepts raw web response objects or network error records, calculates duration metrics, 
    and formats payloads into a fully structured custom object with support for JSON, XML, or TXT.
.PARAMETER Response
    The raw response object returned from `Invoke-WebRequest` or similar, or `$null`.
.PARAMETER Url
    Target request URL.
.PARAMETER Method
    HTTP Method (GET, POST, etc.).
.PARAMETER InputType
    Target parsing format (`JSON`, `XML`, `TXT`).
.PARAMETER StartTime
    `[DateTime]` request start time or tick count.
.PARAMETER NetworkError
    Optional low-level error message if fetch failed.
.OUTPUTS
    [PSCustomObject] Fully structured payload descriptor.
#>

# Format-WebResponse > Normalize-Content
function Normalize-Content {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$InputType,

        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,

        [Parameter(Mandatory = $false)]
        [string]$NetworkError = $null
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    $durationMs = [Math]::Round(((Get-Date) - $StartTime).TotalMilliseconds)

    # Handle hard network/exception failures
    if ($NetworkError -or -not $Response) {
        return [PSCustomObject]@{
            Url        = $Url
            Method     = $Method
            Timestamp  = $timestamp
            DurationMs = $durationMs
            StatusCode = 0
            Status     = "REQUEST_FAILED"
            Success    = $false
            Format     = "NUL"
            Size       = 0
            Data       = $null
            Error      = if ($NetworkError) { $NetworkError } else { "No response object available" }
        }
    }

    $statusCode = [int]$Response.StatusCode
    $raw = if ($Response.Content) { $Response.Content } else { "" }
    $isSuccess = ($statusCode -ge 200 -and $statusCode -lt 300)

    if (-not $raw -or $raw.Trim().Length -eq 0) {
        $statusVal = if ($isSuccess) { "NO_DATA" } else { "HTTP_ERROR" }
        return [PSCustomObject]@{
            Url        = $Url
            Method     = $Method
            Timestamp  = $timestamp
            DurationMs = $durationMs
            StatusCode = $statusCode
            Status     = $statusVal
            Success    = $false
            Format     = "NUL"
            Size       = 0
            Data       = $null
            Error      = $null
        }
    }

    try {
        $parsedData = switch ($InputType.ToUpper()) {
            "JSON" {
                $raw | ConvertFrom-Json
            }
            "XML" {
                [xml]$raw
            }
            "TXT" {
                $raw
            }
            Default {
                $raw
            }
        }

        return [PSCustomObject]@{
            Url        = $Url
            Method     = $Method
            Timestamp  = $timestamp
            DurationMs = $durationMs
            StatusCode = $statusCode
            Status     = if ($isSuccess) { "OK" } else { "HTTP_ERROR" }
            Success    = $isSuccess
            Format     = $InputType.ToUpper()
            Size       = $raw.Length
            Data       = $parsedData
            Error      = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Url        = $Url
            Method     = $Method
            Timestamp  = $timestamp
            DurationMs = $durationMs
            StatusCode = $statusCode
            Status     = "PARSE_FAILED"
            Success    = $false
            Format     = "TXT"
            Size       = $raw.Length
            Data       = $raw
            Error      = "Parse error for $($InputType): $($_.Exception.Message)"
        }
    }
}


<#
 * ============================================================================
 * CORE UTILITIES
 * ============================================================================
#>


<#
.SYNOPSIS
    Makes a single synchronous HTTP call with headers.
.DESCRIPTION
    Makes a single raw synchronous call and returns an object containing
    the underlying response object, the extracted text string, and the response headers.
.PARAMETER Url
    The target URL.
.PARAMETER Params
    Optional request configuration hashtable.
.PARAMETER MaskPatterns
    An array of regular expression strings used to locate and mask sensitive data in URLs and error messages.
.OUTPUTS
    [PSCustomObject] Containing Resp, Text, and Headers properties.
#>
function Fetch-Light {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [hashtable]$Params = @{}
    )

    $options = Build-RequestOptions -Params $Params
    $maskPatterns = $options.MaskPatterns
    $safeUrl = Sanitize-String -Text $Url -Patterns $maskPatterns

    # Map customized options to standard Invoke-WebRequest parameter set
    $webArgs = @{
        Uri                = $Url
        Method             = $options.Method
        MaximumRedirection = $options.MaximumRedirection
        TimeoutSec         = $options.TimeoutSec
        ErrorAction        = 'Stop'
    }

    if ($script:SupportsSkipHttpErrorCheck) {
        $webArgs['SkipHttpErrorCheck'] = $options.SkipHttpErrorCheck
    }

    if ($options.Headers.Count -gt 0) {
        $webArgs['Headers'] = $options.Headers
    }
    if ($options.Body) {
        $webArgs['Body'] = $options.Body
    }
    if ($options.ContentType) {
        $webArgs['ContentType'] = $options.ContentType
    }

    try {
        $response = Invoke-WebRequest @webArgs
        
        # Parse headers
        $parsedHeaders = Convert-WebHeadersToHashtable -WebHeaders $response.Headers

        return [PSCustomObject]@{
            Resp    = $response
            Text    = if ($response.Content) { $response.Content } else { "" }
            Headers = $parsedHeaders
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $safeError = Sanitize-String -Text $errorMessage -Patterns $maskPatterns
        Write-Error "[Fetch-Light] Error fetching URL $($safeUrl): $($safeError)"
        throw "Light request error: $($safeError)"
    }
}

<#
.SYNOPSIS
    Performs chunked batch HTTP requests with rate-limiting support and per-request error handling.
.DESCRIPTION
    Multi-URL light batch calls using sequential chunking. Errors on individual requests
    are caught and recorded without stopping the entire batch.
.PARAMETER Requests
    Array of string URLs or hashtable config objects.
.PARAMETER SharedParams
    Default parameters shared across all items.
.PARAMETER MaskPatterns
    An array of regular expression strings used to locate and mask sensitive data in URLs and error messages.
.PARAMETER RateConfig
    Rate limiting configurations hashtable.
.OUTPUTS
    [PSCustomObject[]] Array of objects containing Resp, Text, and Headers.
#>
function Fetch-LightBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [string[]]$MaskPatterns = $script:DEFAULT_CONFIG.DefaultMaskPatterns,

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) {
        return @()
    }

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($req in $Requests) {
        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }
        $reqParams = if (-not $isString -and $req.ContainsKey('Params')) { $req.Params } else { @{} }

        # Merge shared parameters
        $merged = $SharedParams.Clone()
        foreach ($key in $reqParams.Keys) { $merged[$key] = $reqParams[$key] }
        $merged['MaskPatterns'] = $MaskPatterns

        try {
            $res = Fetch-Light -Url $targetUrl -Params $merged
            $results.Add([PSCustomObject]@{
                Resp    = $res.Resp
                Text    = $res.Text
                Headers = $res.Headers
                Success = $true
                Error   = $null
            })
        }
        catch {
            $safeError = Sanitize-String -Text $_.Exception.Message -Patterns $MaskPatterns
            $safeUrl = Sanitize-String -Text $targetUrl -Patterns $MaskPatterns
            Write-Warning "[Fetch-LightBatch] Request failed for $($safeUrl): $($safeError)"
            
            $results.Add([PSCustomObject]@{
                Resp    = $null
                Text    = ""
                Headers = @{}
                Success = $false
                Error   = $safeError
            })
        }
    }

    return $results.ToArray()
}

<#
.SYNOPSIS
    Sequential array fetch (Raw). Sends requests one by one with delay.
.DESCRIPTION
    Granular error handling. If one fails, the loop continues.
#>
function Fetch-LightArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [string[]]$MaskPatterns = $script:DEFAULT_CONFIG.DefaultMaskPatterns,

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) { return @() }

    $delayMs = if ($RateConfig.ContainsKey('DelayMs')) { $RateConfig.DelayMs } else { $script:DEFAULT_CONFIG.DefaultDelayMs }
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Requests.Count; $i++) {
        $req = $Requests[$i]
        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }
        $reqParams = if (-not $isString -and $req.ContainsKey('Params')) { $req.Params } else { @{} }

        $merged = $SharedParams.Clone()
        foreach ($key in $reqParams.Keys) { $merged[$key] = $reqParams[$key] }
        $merged['MaskPatterns'] = $MaskPatterns

        # Apply delay BEFORE the request (skip for first item)
        if ($i -gt 0 -and $delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }

        try {
            $res = Fetch-Light -Url $targetUrl -Params $merged
            $results.Add([PSCustomObject]@{
                Resp    = $res.Resp
                Text    = $res.Text
                Headers = $res.Headers
                Success = $true
                Error   = $null
            })
        }
        catch {
            $safeError = Sanitize-String -Text $_.Exception.Message -Patterns $MaskPatterns
            $safeUrl = Sanitize-String -Text $targetUrl -Patterns $MaskPatterns
            Write-Warning "[Fetch-LightArray] Request failed for $($safeUrl): $($safeError)"
            
            $results.Add([PSCustomObject]@{
                Resp    = $null
                Text    = ""
                Headers = @{}
                Success = $false
                Error   = $safeError
            })
        }
    }

    return $results.ToArray()
}

<#
.SYNOPSIS
    Fetches remote content and formats it into a structured descriptor.
.DESCRIPTION
    Fetches remote content using `Invoke-LightRequestRaw` and delegates formatting 
    to `Format-WebResponse` with support for explicit input formats (`JSON`, `XML`, `TXT`).
.PARAMETER Url
    The target URL.
.PARAMETER Params
    Optional request configuration hashtable including `InputType` and `Method`.
.PARAMETER MaskPatterns
    An array of regular expression strings used to locate and mask sensitive data in URLs and error messages.
.OUTPUTS
    [PSCustomObject] Fully structured payload descriptor.
#>
function Fetch-Structured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [hashtable]$Params = @{}
    )

    $inputType = if ($Params.ContainsKey('InputType')) { $Params.InputType } else { 'TXT' }
    $method = if ($Params.ContainsKey('Method')) { $Params.Method } else { 'GET' }
    $startTime = Get-Date
    $upperMethod = $method.ToUpper()

    $responseObj = $null
    $headersObj = @{}
    $requestError = $null

    try {
        $fetchResult = Fetch-Light -Url $Url -Params $Params
        if ($fetchResult) {
            $responseObj = $fetchResult.Resp
            $headersObj = $fetchResult.Headers
        }
    }
    catch {
        $requestError = $_.Exception.Message
    }

    $normalized = Normalize-Content -Response $responseObj -Url $Url -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $requestError

    # Inject headers
    $normalized | Add-Member -MemberType NoteProperty -Name 'Headers' -Value $headersObj -Force
    return $normalized
}

<#
.SYNOPSIS
    Performs batch requests and returns structured response objects.
.DESCRIPTION
    Multi-URL batch processing using rate-limited batch calls and returning 
    fully normalized and structured descriptor objects for each target.
.PARAMETER Requests
    Array of URLs or hashtable configuration objects.
.PARAMETER SharedParams
    Default parameters shared across all items.
.PARAMETER MaskPatterns
    An array of regular expression strings used to locate and mask sensitive data in URLs and error messages.
.PARAMETER RateConfig
    Rate limiting configurations hashtable with `ChunkSize` and `DelayMs` keys.
.OUTPUTS
    [PSCustomObject[]] Array of structured response descriptor objects.
#>
function Fetch-StructuredBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [string[]]$MaskPatterns = $script:DEFAULT_CONFIG.DefaultMaskPatterns,

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) { return @() }

    $lightBatch = Fetch-LightBatch -Requests $Requests -SharedParams $SharedParams -MaskPatterns $MaskPatterns -RateConfig $RateConfig
    $startTime = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Requests.Count; $index++) {
        $req = $Requests[$index]
        $item = $lightBatch[$index]

        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }
        $reqParams = if (-not $isString -and $req.ContainsKey('Params')) { $req.Params } else { @{} }

        $merged = $SharedParams.Clone()
        foreach ($key in $reqParams.Keys) { $merged[$key] = $reqParams[$key] }
        
        $inputType = if ($merged.ContainsKey('InputType')) { $merged.InputType } else { 'TXT' }
        $method = if ($merged.ContainsKey('Method')) { $merged.Method } else { 'GET' }
        $upperMethod = $method.ToUpper()

        $responseObj = $item.Resp
        $headersObj = $item.Headers
        $networkError = if (-not $item.Success) { $item.Error } else { $null }

        $normalized = Normalize-Content -Response $responseObj -Url $targetUrl -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $networkError
        $normalized | Add-Member -MemberType NoteProperty -Name 'Headers' -Value $headersObj -Force
        $results.Add($normalized)
    }

    return $results.ToArray()
}

<#
.SYNOPSIS
    Sequential array fetch (Structured). Sends requests one by one with delay.
.DESCRIPTION
    Granular error handling. If one fails, the loop continues.
#>
function Fetch-StructuredArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [string[]]$MaskPatterns = $script:DEFAULT_CONFIG.DefaultMaskPatterns,

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) { return @() }

    $delayMs = if ($RateConfig.ContainsKey('DelayMs')) { $RateConfig.DelayMs } else { $script:DEFAULT_CONFIG.DefaultDelayMs }
    $startTime = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Requests.Count; $i++) {
        $req = $Requests[$i]
        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }
        $reqParams = if (-not $isString -and $req.ContainsKey('Params')) { $req.Params } else { @{} }

        $merged = $SharedParams.Clone()
        foreach ($key in $reqParams.Keys) { $merged[$key] = $reqParams[$key] }
        
        $inputType = if ($merged.ContainsKey('InputType')) { $merged.InputType } else { 'TXT' }
        $method = if ($merged.ContainsKey('Method')) { $merged.Method } else { 'GET' }
        $upperMethod = $method.ToUpper()

        # Apply delay BEFORE the request (skip for first item)
        if ($i -gt 0 -and $delayMs -gt 0) {
            Start-Sleep -Milliseconds $delayMs
        }

        $responseObj = $null
        $headersObj = @{}
        $networkError = $null

        try {
            $fetchResult = Fetch-Light -Url $targetUrl -Params $merged
            if ($fetchResult) {
                $responseObj = $fetchResult.Resp
                $headersObj = $fetchResult.Headers
            }
        }
        catch {
            $networkError = Sanitize-String -Text $_.Exception.Message -Patterns $merged.MaskPatterns
        }

        $normalized = Normalize-Content -Response $responseObj -Url $targetUrl -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $networkError
        $normalized | Add-Member -MemberType NoteProperty -Name 'Headers' -Value $headersObj -Force
        $results.Add($normalized)
    }

    return $results.ToArray()
}
