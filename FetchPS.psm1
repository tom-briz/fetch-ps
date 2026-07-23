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
.OUTPUTS
    [PSCustomObject] Containing Resp, Text, and Headers properties.
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
        
        # Parse headers
        $parsedHeaders = Convert-WebHeadersToHashtable -WebHeaders $response.Headers

        return [PSCustomObject]@{
            Resp    = $response
            Text    = if ($response.Content) { $response.Content } else { "" }
            Headers = $parsedHeaders
        }
    }
    catch {
        Write-Error "[Fetcher:Light] Error fetching URL $($Url): $(_)"
        throw "Light request error: $_"
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
.PARAMETER RateConfig
    Rate limiting configurations hashtable.
.OUTPUTS
    [PSCustomObject[]] Array of objects containing Resp, Text, and Headers.
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
    $delayMs = if ($RateConfig.ContainsKey('DelayMs')) { $RateConfig.DelayMs } else { 0 } # Default to 0 delay if not specified
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Requests.Count; $i += $chunkSize) {
        # Define the chunk range
        $endIndex = [Math]::Min($i + $chunkSize - 1, $Requests.Count - 1)
        $chunk = $Requests[$i..$endIndex]

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
                ErrorAction        = 'Stop' # Critical: ensures Invoke-WebRequest throws on errors
            }

            if ($options.Headers.Count -gt 0) { $webArgs['Headers'] = $options.Headers }
            if ($options.Body) { $webArgs['Body'] = $options.Body }
            if ($options.ContentType) { $webArgs['ContentType'] = $options.ContentType }

            try {
                # Execute the request
                $res = Invoke-WebRequest @webArgs
                $parsedHeaders = Convert-WebHeadersToHashtable -WebHeaders $res.Headers

                # Success: Add result
                $results.Add([PSCustomObject]@{
                    Resp    = $res
                    Text    = if ($res.Content) { $res.Content } else { "" }
                    Headers = $parsedHeaders
                    Success = $true
                    Error   = $null
                })
            }
            catch {
                # Failure: Log error and add a failure placeholder
                $errorMsg = $_.Exception.Message
                Write-Warning "[Fetcher:LightBatch] Request failed for ${targetUrl}: ${errorMsg}"
                
                $results.Add([PSCustomObject]@{
                    Resp    = $null
                    Text    = ""
                    Headers = @{}
                    Success = $false
                    Error   = $errorMsg
                })
            }
        }

        # Apply delay between chunks (not between every single request if chunkSize > 1)
        if ($delayMs -gt 0 -and ($i + $chunkSize) -lt $Requests.Count) {
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

    # --- IDENTICAL INITIALIZATION BLOCK ---
    $responseObj = $null
    $headersObj = @{}
    $requestError = $null

    try {
        # 1. Fetch raw data
        $fetchResult = Invoke-LightRequestRaw -Url $Url -Params $Params
        
        if ($fetchResult) {
            $responseObj = $fetchResult.Resp
            $headersObj = $fetchResult.Headers
            
            # If the raw request returned null content (e.g., 404 handled as "success" but empty)
            # we still proceed to normalization, but if the fetch itself threw, we catch it here.
            if (-not $responseObj) {
                $requestError = "No response object returned from request"
            }
        }
        else {
            $requestError = "Request returned no result"
        }

        # 2. Normalize content (Headers NOT passed to Normalize-Content)
        $normalizedResult = Normalize-Content -Response $responseObj -Url $Url -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $requestError

        # 3. Inject headers
        if ($normalizedResult) {
            $normalizedResult | Add-Member -MemberType NoteProperty -Name 'Headers' -Value $headersObj -Force
        }

        return $normalizedResult
    }
    catch {
        # --- SAFE FAILURE OBJECT PATTERN ---
        # If anything fails (fetch, normalization, injection), create a safe object
        # so the caller always gets a structured response, never a script crash.
        $errorMsg = $_.Exception.Message
        Write-Warning "[Fetcher:StructuredRequest] Request failed for ${Url}: ${errorMsg}"
        
        # Create a safe failure object using the normalizer
        $failureObj = Normalize-Content -Response $null -Url $Url -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError "Processing error: $errorMsg"
        
        # Inject empty headers for structural consistency
        $failureObj | Add-Member -MemberType NoteProperty -Name 'Headers' -Value @{} -Force
        
        return $failureObj
    }
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

    if (-not $Requests -or $Requests.Count -eq 0) { return @() }

    # Pre-fetch raw data (including headers) from the batch function.
    # Note: Invoke-LightBatchRaw handles network errors and returns safe placeholders.
    $lightBatch = Invoke-LightBatchRaw -Requests $Requests -SharedParams $SharedParams -RateConfig $RateConfig
    
    $startTime = Get-Date
    $results = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $Requests.Count; $index++) {
        $req = $Requests[$index]
        $item = $lightBatch[$index]

        # --- DIFFERENCE 1: URL Resolution ---
        # Single Function: $Url is a direct parameter.
        # Batch Function: Extract URL from $req (string or hashtable).
        $isString = $req -is [string]
        $targetUrl = if ($isString) { $req } else { $req.Url }

        # --- DIFFERENCE 2: Parameter Merging ---
        # Single Function: $Params passed directly.
        # Batch Function: Manually merge $SharedParams with request-specific params.
        $merged = $SharedParams.Clone()
        if (-not $isString -and $req.ContainsKey('Params')) {
            foreach ($k in $req.Params.Keys) { $merged[$k] = $req.Params[$k] }
        }

        $inputType = if ($merged.ContainsKey('InputType')) { $merged.InputType } else { 'TXT' }
        $method = if ($merged.ContainsKey('Method')) { $merged.Method } else { 'GET' }
        $upperMethod = $method.ToUpper()

        # --- IDENTICAL INITIALIZATION BLOCK ---
        # Matches Invoke-StructuredRequest exactly
        $responseObj = $null
        $headersObj = @{}
        $requestError = $null

        # --- IDENTICAL TRY/CATCH BLOCK ---
        # Mirrors Invoke-StructuredRequest logic for stability.
        # Even though $item comes from Invoke-LightBatchRaw, we wrap the extraction 
        # and normalization in try/catch to protect against parsing errors 
        # or unexpected null states in the loop.
        try {
            if ($item) {
                $responseObj = $item.Resp
                $headersObj = $item.Headers
                
                # If the raw item had no response (network failure handled upstream),
                # we set a specific error message to pass to normalization.
                if (-not $responseObj) {
                    $requestError = "Chunk execution error or no response"
                }
            }
            else {
                # Fallback if the batch result array is missing an index
                $requestError = "No batch item found at index $index"
            }
            
            # Normalization happens inside the try block so we can catch errors
            # during parsing (e.g., invalid JSON/XML)
            $normalizedResult = Normalize-Content -Response $responseObj -Url $targetUrl -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError $requestError

            # --- IDENTICAL INJECTION STEP ---
            if ($normalizedResult) {
                $normalizedResult | Add-Member -MemberType NoteProperty -Name 'Headers' -Value $headersObj -Force
            }

            $results.Add($normalizedResult)
        }
        catch {
            # If anything fails during extraction, parsing, or injection,
            # we log it and add a safe failure object to the results.
            $errorMsg = $_.Exception.Message
            Write-Warning "[Fetcher:StructuredBatch] Processing failed for ${targetUrl}: ${errorMsg}"
            
            # Create a safe failure object that matches the successful structure
            $failureObj = Normalize-Content -Response $null -Url $targetUrl -Method $upperMethod -InputType $inputType -StartTime $startTime -NetworkError "Processing error: ${errorMsg}"
            
            # Inject empty headers for consistency
            $failureObj | Add-Member -MemberType NoteProperty -Name 'Headers' -Value @{} -Force
            
            $results.Add($failureObj)
        }
    }

    return $results.ToArray()
}
