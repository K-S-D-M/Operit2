$ErrorActionPreference = "Stop"

$runtimeDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$downloadsDir = Join-Path $runtimeDir "downloads"
$sourcesDir = Join-Path $runtimeDir "sources"

New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
New-Item -ItemType Directory -Force -Path $sourcesDir | Out-Null

$items = @(
    @{
        Name = "busybox-1.38.0"
        Url = "https://busybox.net/downloads/busybox-1.38.0.tar.bz2"
        Archive = "busybox-1.38.0.tar.bz2"
        Sha256 = "34F9EA6FF8636F2C9241153B9114EEFA9E65674A45318AE1EF95BB5F31C53BB2"
        Extracted = "busybox-1.38.0"
    },
    @{
        Name = "termux-proot-v5.1.107.78"
        Url = "https://github.com/termux/proot/archive/refs/tags/v5.1.107.78.tar.gz"
        Archive = "termux-proot-v5.1.107.78.tar.gz"
        Sha256 = "F3377BA49DCD833370420C34C5081B4C243ECBB85B2A9881A4F4586012599AFA"
        Extracted = "proot-5.1.107.78"
    },
    @{
        Name = "talloc-2.4.3"
        Url = "https://www.samba.org/ftp/talloc/talloc-2.4.3.tar.gz"
        Archive = "talloc-2.4.3.tar.gz"
        Sha256 = "DC46C40B9F46BB34DD97FE41F548B0E8B247B77A918576733C528E83ABD854DD"
        Extracted = "talloc-2.4.3"
    },
    @{
        Name = "bash-5.2.37"
        Url = "https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz"
        Archive = "bash-5.2.37.tar.gz"
        Sha256 = "9599B22ECD1D5787AD7D3B7BF0C59F312B3396D1E281175DD1F8A4014DA621FF"
        Extracted = "bash-5.2.37"
    }
)

function Download-WithRetry {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$ExpectedSha256,
        [int]$MaxAttempts = 5
    )
    # Resolve a real curl binary (curl.exe on Windows, curl on Linux/macOS).
    # Avoid PowerShell's legacy 'curl' alias which maps to Invoke-WebRequest.
    $curlPath = $null
    foreach ($candidate in @('curl.exe', 'curl')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.CommandType -eq 'Application') { $curlPath = $cmd.Source; break }
    }
    if (-not $curlPath) { throw 'curl binary not found on PATH' }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host "  attempt $attempt/$MaxAttempts : $Uri"
        if (Test-Path $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
        # curl handles transient connection timeouts; --retry covers errors,
        # --connect-timeout / --max-time bound a single stalled transfer.
        & $curlPath -fL --connect-timeout 30 --max-time 300 --retry 4 --retry-delay 5 -o $OutFile $Uri 2>&1 | Write-Host
        $curlExit = $LASTEXITCODE
        if ($curlExit -eq 0 -and (Test-Path $OutFile)) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $OutFile).Hash.ToUpperInvariant()
            if ($actual -eq $ExpectedSha256) {
                Write-Host "  download OK (sha256 verified)"
                return
            }
            Write-Warning "  sha256 mismatch: $actual"
        } else {
            Write-Warning "  curl exit code: $curlExit"
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 10 }
    }
    throw "Failed to download $Uri after $MaxAttempts attempts"
}

foreach ($item in $items) {
    $archivePath = Join-Path $downloadsDir $item.Archive
    Write-Host "Downloading $($item.Name)"
    Download-WithRetry -Uri $item.Url -OutFile $archivePath -ExpectedSha256 $item.Sha256

    $extractPath = Join-Path $sourcesDir $item.Extracted
    if (Test-Path $extractPath) {
        Remove-Item -LiteralPath $extractPath -Recurse -Force
    }

    tar -xf $archivePath -C $sourcesDir
}
