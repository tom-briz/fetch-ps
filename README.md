# fetch-ps

`fetch-ps` is a lightweight, robust, and native HTTP fetching and data normalization library designed specifically for PowerShell. It brings the clean, unified request handling and structured response philosophy of `fetch-gs` directly to Windows, macOS, and Linux terminal and script environments without heavy external dependencies.

---

## Features

* **Native PowerShell Pipelines:** Leverages core PowerShell web commands (`Invoke-WebRequest`) and outputs structured `PSCustomObject` descriptors.
* **Unified Request Options:** Centralized option builder handling method normalization, custom headers, content types, and timeouts.
* **Intelligent Content Normalization:** Automatically parses and structures responses into standard formats (`JSON`, `XML`, `TXT`) with duration telemetry and success tracking.
* **Rate-Limited Batching:** Built-in chunking and throttling delays to execute multi-URL request queues safely and responsibly.

---

## Installation

Clone or download the repository, then dot-source the main script into your active PowerShell session or module path:

```powershell
. .\FetchPS.ps1

```

---

## Core Functions & Usage

### 1. `Get-ProjectInfo`

Returns metadata about the `fetch-ps` library version, repository, and licensing.

```powershell
Get-ProjectInfo

```

### 2. `Invoke-LightRequestRaw`

Makes a single raw synchronous HTTP request and returns an object containing the underlying response and raw content string.

```powershell
$result = Invoke-LightRequestRaw -Url "https://api.github.com/zen"
$result.Text

```

### 3. `Invoke-StructuredRequest`

Fetches remote content and passes it through the centralized normalization factory to return a fully structured custom object with timing metrics and auto-parsed data payloads.

```powershell
$params = @{
    InputType = "JSON"
    Method    = "GET"
}
$structured = Invoke-StructuredRequest -Url "https://api.github.com/users/tom-briz" -Params $params

# Access normalized attributes
$structured.Success
$structured.Data.name
$structured.DurationMs

```

### 4. `Invoke-StructuredBatch`

Performs rate-limited batch processing for a collection of URLs or configuration objects, returning an array of normalized response descriptors.

```powershell
$urls = @(
    "https://api.github.com/zen",
    "https://api.github.com/octocat"
)
$rateConfig = @{ ChunkSize = 2; DelayMs = 500 }

$batchResults = Invoke-StructuredBatch -Requests $urls -RateConfig $rateConfig
$batchResults | Format-Table Url, StatusCode, Status, DurationMs

```

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the `LICENSE` file for details.
