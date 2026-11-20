param(
    [string]$ReleaseDirectory,
    [string]$XxhsumPath
)

# Copyright (c) 2026 VRAMの魔術師 / SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$packageName = 'SYNC_DrawMarker'
$projectDir = Split-Path -Parent $PSScriptRoot
$pluginName = "$packageName.aux2"
if (-not $ReleaseDirectory) {
    $ReleaseDirectory = Join-Path $env:ProgramData "aviutl2\Plugin\$packageName"
}
$pluginPath = Join-Path $ReleaseDirectory $pluginName
if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
    throw "Release plugin not found: $pluginPath. Build Win64 Release first."
}

function Get-Xxhsum {
    if ($XxhsumPath) {
        return (Resolve-Path -LiteralPath $XxhsumPath).ProviderPath
    }
    $cache = Join-Path $projectDir 'Win64\Dependencies\xxHash-0.8.4'
    $exe = Join-Path $cache 'xxhsum.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }

    $xxhsum = Get-Command xxhsum.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($xxhsum) { return $xxhsum.Source }

    $null = New-Item -ItemType Directory -Path $cache -Force
    $download = Join-Path $cache 'xxhsum-download.tmp'
    $extracted = Join-Path $cache 'xxhsum-extracted.tmp'
    $uri = 'https://github.com/Cyan4973/xxHash/releases/download/v0.8.4/xxhsum_win64_v0_8_4.zip'
    $sha256 = '58E3DCB7063EB3829418453702556CDB2B52E7C9082215FCD4E9135FABBD4ED9'
    $progressPreference = 'SilentlyContinue'
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        Write-Host 'Downloading xxHash v0.8.4 for Windows x64...'
        [Net.ServicePointManager]::SecurityProtocol = $protocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $download -TimeoutSec 45
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            $digest = [BitConverter]::ToString($algorithm.ComputeHash([IO.File]::ReadAllBytes($download)))
        }
        finally { $algorithm.Dispose() }
        if ($digest.Replace('-', '') -cne $sha256) {
            throw 'The xxHash ZIP checksum did not match.'
        }
        $archive = [IO.Compression.ZipFile]::OpenRead($download)
        try {
            [IO.Compression.ZipFileExtensions]::ExtractToFile($archive.GetEntry('xxhsum.exe'), $extracted, $true)
        }
        finally { $archive.Dispose() }
        [IO.File]::Move($extracted, $exe)
    }
    catch {
        throw "Could not prepare xxhsum.exe. Supply -XxhsumPath to use a local copy. $($_.Exception.Message)"
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $protocol
        [IO.File]::Delete($download)
        [IO.File]::Delete($extracted)
    }
    return $exe
}

$catalogPath = Join-Path $PSScriptRoot "$packageName.catalog.json"
$zipPath = Join-Path $PSScriptRoot "$packageName.zip"
$tempBase = Join-Path $PSScriptRoot ('.release-' + [guid]::NewGuid().ToString('N'))
$tempPlugin = "$tempBase.aux2"
$tempZip = "$tempBase.zip"
$tempCatalog = "$tempBase.json"
$tempReadme = "$tempBase.md"
$catalogBackup = "$tempBase-previous.json"
$utf8 = [Text.UTF8Encoding]::new($false)

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$lock = [Threading.Mutex]::new($false, "Local\VRAMWIZ.$packageName.ReleaseZip")
$ownsLock = $false
try {
    try { $ownsLock = $lock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsLock = $true }
    if (-not $ownsLock) { throw 'Another release ZIP is being created. Run the batch again.' }

    $catalogSource = [IO.File]::ReadAllText($catalogPath)
    $catalog = [object[]]($catalogSource | ConvertFrom-Json)
    if ($catalogSource -notmatch '^\s*\[' -or $catalog.Count -ne 1 -or
        $catalog[0].id -cne "VRAMWIZ.$packageName") {
        throw "The catalog must contain one VRAMWIZ.$packageName entry."
    }
    $entry = $catalog[0]
    $github = $entry.installer.source.github
    $copy = @($entry.installer.install | Where-Object action -ceq 'copy')
    if ($github.owner -cne 'vramwiz' -or $github.repo -cne $packageName -or
        $github.pattern -cne ('^' + [regex]::Escape("$packageName.zip") + '$') -or
        $copy.Count -ne 1 -or $copy[0].from -cne "{tmp}/$packageName" -or
        $copy[0].to -cne "{pluginsDir}/$packageName") {
        throw 'Catalog download and install paths must match the release ZIP.'
    }
    $versions = @($entry.version)
    if ($versions.Count -eq 0 -or $versions[0].version -cne 'v1.0.0') {
        throw 'The first catalog version must be v1.0.0.'
    }
    $version = $versions[-1]
    $releaseDate = [datetime]::MinValue
    if ($version.version -cnotmatch '^v\d+\.\d+\.\d+$' -or
        @($versions | Where-Object version -ceq $version.version).Count -ne 1 -or
        -not [datetime]::TryParseExact($version.release_date, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$releaseDate)) {
        throw 'The latest catalog entry must have a unique version and a valid release date.'
    }
    $pluginEntry = @($version.file | Where-Object path -ceq "{pluginsDir}/$packageName/$pluginName")
    if (@($version.file).Count -ne 1 -or $pluginEntry.Count -ne 1 -or
        -not $pluginEntry[0].PSObject.Properties['XXH3_128']) {
        throw 'The latest catalog version must list the AUX2 and its XXH3_128 field.'
    }

    # Hash and archive the same copy of the release binary.
    Copy-Item -LiteralPath $pluginPath -Destination $tempPlugin
    $binary = [Diagnostics.FileVersionInfo]::GetVersionInfo($tempPlugin)
    $publicVersion = $version.version.Substring(1)
    if ($binary.ProductName -cne $packageName -or $binary.ProductVersion -cne $publicVersion -or
        $binary.FileVersion -cne "$publicVersion.0" -or $binary.IsDebug) {
        throw "Build Win64 Release for $packageName $($version.version) before packaging."
    }
    $xxhsumExe = Get-Xxhsum
    $hashOutput = & $xxhsumExe -H128 --tag $tempPlugin
    if ($LASTEXITCODE -ne 0 -or ($hashOutput -join "`n") -notmatch ' = ([0-9a-fA-F]{32})\s*\z') {
        throw 'Could not calculate the AUX2 XXH3-128 hash.'
    }
    $hash = $Matches[1].ToLowerInvariant()

    $packageFiles = [ordered]@{
        $pluginName = $tempPlugin
        'README.md' = $tempReadme
        'LICENSE' = Join-Path $projectDir 'LICENSE'
        'THIRD_PARTY_NOTICES.md' = Join-Path $projectDir 'THIRD_PARTY_NOTICES.md'
        'ThirdParty/LICENSE.AviUtl2-SDK.txt' = Join-Path $projectDir 'ThirdParty\LICENSE.AviUtl2-SDK.txt'
    }
    $expectedPaths = @($packageFiles.Keys | ForEach-Object { "{pluginsDir}/$packageName/$_" })
    $uninstall = @($entry.installer.uninstall)
    $deletePaths = @($uninstall | Where-Object action -ceq 'delete' | ForEach-Object path)
    if ($uninstall.Count -ne $expectedPaths.Count -or
        @(Compare-Object $expectedPaths $deletePaths -CaseSensitive).Count -ne 0) {
        throw 'Catalog uninstall paths must match the files in the ZIP.'
    }
    $readme = [IO.File]::ReadAllText((Join-Path $projectDir 'README.md'))
    foreach ($file in @('SYNC_DrawMarker.dproj', 'Setup/README.md', 'AVIUTL2_FILTER_INPUT_CAPTURE.md', 'note.md')) {
        $readme = $readme.Replace("]($file)", "](https://github.com/vramwiz/$packageName/blob/$($version.version)/$file)")
    }
    [IO.File]::WriteAllText($tempReadme, $readme, $utf8)

    $archive = [IO.Compression.ZipFile]::Open($tempZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $packageFiles.GetEnumerator()) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.Value, "$packageName/$($file.Key)", [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally { $archive.Dispose() }

    if ([IO.File]::ReadAllText($catalogPath) -cne $catalogSource) {
        throw 'The catalog changed during packaging. Run the batch again.'
    }
    if ($pluginEntry[0].XXH3_128 -cne $hash) {
        $pluginEntry[0].XXH3_128 = $hash
        $json = ConvertTo-Json -InputObject $catalog -Depth 10
        [IO.File]::WriteAllText($tempCatalog, $json + [Environment]::NewLine, $utf8)
        [IO.File]::Replace($tempCatalog, $catalogPath, $catalogBackup)
    }
    try {
        if ([IO.File]::Exists($zipPath)) { [IO.File]::Replace($tempZip, $zipPath, [NullString]::Value) }
        else { [IO.File]::Move($tempZip, $zipPath) }
    }
    catch {
        if ([IO.File]::Exists($catalogBackup)) {
            [IO.File]::Replace($catalogBackup, $catalogPath, [NullString]::Value)
        }
        throw
    }
    [IO.File]::Delete($catalogBackup)
}
finally {
    if ($ownsLock) { $lock.ReleaseMutex() }
    $lock.Dispose()
    foreach ($file in @($tempPlugin, $tempZip, $tempCatalog, $tempReadme)) {
        [IO.File]::Delete($file)
    }
}

Write-Output "Created $zipPath"
Write-Output "Catalog $($version.version), AUX2 XXH3_128=$hash"
