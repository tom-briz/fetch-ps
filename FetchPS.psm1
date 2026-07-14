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

    $method = if ($Params.ContainsKey('Method')) { $Params.Method } else { 'GET' }
    $headers = if ($Params.ContainsKey('Headers')) { $Params.Headers } else { @{} }
    $payload = if ($Params.ContainsKey('Payload')) { $Params.Payload } else { $null }
    $timeout = if ($Params.ContainsKey('Timeout')) { $Params.Timeout } else { 30000 }

    $contentType = if ($headers.ContainsKey('Content-Type')) { $headers['Content-Type'] } else { $null }

    return [PSCustomObject]@{
        Method             = $method.ToUpper()
        Headers            = $headers
        Body               = $payload
        SkipHttpErrorCheck = $true
        MaximumRedirection = 10
        ContentType        = $contentType
        TimeoutSec         = [Math]::Ceiling($timeout / 1000)
    }
}

<#
.SYNOPSIS
    Centralized parser and normalization factory for PowerShell web responses.
.DESCRIPTION
    Accepts raw web response objects or network error records, calculates duration metrics, 
    and normalizes payloads into a fully structured custom object with formatting for JSON, XML, or TXT.
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
            Error      = "Parse error for $InputType: $($_.Exception.Message)"
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
    Makes a single synchronous HTTP call.
.DESCRIPTION
    Makes a single raw synchronous call and returns an object containing
    the underlying response object and the extracted text string.
.PARAMETER Url
    The target URL.
.PARAMETER Params
    Optional request configuration hashtable.
.OUTPUTS
    [PSCustomObject] Containing Resp and Text properties.
#>
function Invoke-LightRequestRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        [hashtable]$Params = @{}
    )

    $options = Build-RequestOptions -Params $Params
    
    # Map customized options to standard Invoke-WebRequest parameter set
    $webArgs = @{
        Uri                = $Url
        Method             = $options.Method
        SkipHttpErrorCheck = $options.SkipHttpErrorCheck
        MaximumRedirection = $options.MaximumRedirection
        TimeoutSec         = $options.TimeoutSec
        ErrorAction        = 'Stop'
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
        return [PSCustomObject]@{
            Resp = $response
            Text = if ($response.Content) { $response.Content } else { "" }
        }
    }
    catch {
        Write-Error "[Fetcher:Light] Error fetching URL $Url: $_"
        throw "Light request error: $_"
    }
}

<#
.SYNOPSIS
    Performs chunked batch HTTP requests with rate-limiting support.
.DESCRIPTION
    Multi-URL light batch calls using sequential chunking and optional delays 
    between chunks to replicate fetch-gs behavior in native PowerShell.
.PARAMETER Requests
    Array of string URLs or hashtable config objects containing Url and Params.
.PARAMETER SharedParams
    Default parameters shared across all items.
.PARAMETER RateConfig
    Rate limiting configurations hashtable with ChunkSize and DelayMs keys.
.OUTPUTS
    [PSCustomObject[]] Array of objects containing Resp and Text properties.
#>
function Invoke-LightBatchRaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) {
        return @()
    }

    $chunkSize = if ($RateConfig.ContainsKey('ChunkSize')) { $RateConfig.ChunkSize } else { 10 }
    $delayMs = if ($RateConfig.ContainsKey('DelayMs')) { $RateConfig.DelayMs } else { 1000 }
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Requests.Count; $i += $chunkSize) {
        $chunk = $Requests[$i..([Math]::Min($i + $chunkSize - 1, $Requests.Count - 1))]
        $chunkResults = [System.Collections.Generic.List[object]]::new()

        try {
            foreach ($req in $chunk) {
                $isString = $req -is [string]
                $targetUrl = if ($isString) { $req } else { $req.Url }
                $reqParams = if (-not $isString -and $req.ContainsKey('Params')) { $req.Params } else { @{} }

                # Merge shared parameters and request specific parameters
                $merged = $SharedParams.Clone()
                foreach ($key in $reqParams.Keys) {
                    $merged[$key] = $reqParams[$key]
                }

                $options = Build-RequestOptions -Params $merged
                $webArgs = @{
                    Uri                = $targetUrl
                    Method             = $options.Method
                    SkipHttpErrorCheck = $true
                    MaximumRedirection = $options.MaximumRedirection
                    TimeoutSec         = $options.TimeoutSec
                    ErrorAction        = 'Stop'
                }

                if ($options.Headers.Count -gt 0) { $webArgs['Headers'] = $options.Headers }
                if ($options.Body) { $webArgs['Body'] = $options.Body }
                if ($options.ContentType) { $webArgs['ContentType'] = $options.ContentType }

                $res = Invoke-WebRequest @webArgs
                $chunkResults.Add([PSCustomObject]@{
                    Resp = $res
                    Text = if ($res.Content) { $res.Content } else { "" }
                })
            }
            foreach ($item in $chunkResults) {
                $results.Add($item)
            }
        }
        catch {
            Write-Error "[Fetcher:LightBatch] Chunk execution failed at index $i: $($_.Exception.Message)"
            foreach ($item in $chunk) {
                $results.Add([PSCustomObject]@{ Resp = $null; Text = "" })
            }
        }

        if (($i + $chunkSize -lt $Requests.Count) -and ($delayMs -gt 0)) {
            Start-Sleep -Milliseconds $delayMs
        }
    }

    return $results.ToArray()
}

<#
.SYNOPSIS
    Fetches remote content and normalizes it into a structured descriptor.
.DESCRIPTION
    Fetches remote content using `Invoke-LightRequestRaw` and delegates normalization 
    to `Normalize-Content` with support for explicit input formats (`JSON`, `XML`, `TXT`).
.PARAMETER Url
    The target URL.
.PARAMETER Params
    Optional request configuration hashtable including `InputType` and `Method`.
.OUTPUTS
    [PSCustomObject] Fully structured payload descriptor.
#>
function Invoke-StructuredRequest {
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
    $requestError = $null

    try {
        $fetchResult = Invoke-LightRequestRaw -Url $Url -Params $Params
        $responseObj = if ($fetchResult) { $fetchResult.Resp } else { $null }
    }
    catch {
        $requestError = $_.Exception.Message
    }

    return Normalize-Content -Response $responseObj -Url $Url -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $requestError
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
.PARAMETER RateConfig
    Rate limiting configurations hashtable with `ChunkSize` and `DelayMs` keys.
.OUTPUTS
    [PSCustomObject[]] Array of structured response descriptor objects.
#>
function Invoke-StructuredBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,

        [Parameter(Mandatory = $false)]
        [hashtable]$SharedParams = @{},

        [Parameter(Mandatory = $false)]
        [hashtable]$RateConfig = @{}
    )

    if (-not $Requests -or $Requests.Count -eq 0) {
        return @()
    }

    $lightBatch = Invoke-LightBatchRaw -Requests $Requests -SharedParams $SharedParams -RateConfig $RateConfig
    $startTime = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Requests.Count; $index++) {
        $req = $Requests[$index]
        $item = $lightBatch[$index]
        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }

        $merged = $SharedParams.Clone()
        if (-not $isString -and $req.ContainsKey('Params')) {
            foreach ($k in $req.Params.Keys) {
                $merged[$k] = $req.Params[$k]
            }
        }

        $inputType = if ($merged.ContainsKey('InputType')) { $merged.InputType } else { 'TXT' }
        $method = if ($merged.ContainsKey('Method')) { $merged.Method } else { 'GET' }
        $upperMethod = $method.ToUpper()

        $responseObj = if ($item) { $item.Resp } else { $null }
        $errorMsg = if (-not $responseObj) { "Chunk execution error or no response" } else { $null }

        $normalized = Normalize-Content -Response $responseObj -Url $targetUrl -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $errorMsg
        $results.Add($normalized)
    }

    return $results.ToArray()
}
