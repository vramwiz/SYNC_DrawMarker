param(
    [string]$ReleaseDirectory,
    [string]$XxhsumPath
)

# SYNC_AutoWritingの既存Release AUF2と説明書・ライセンスをZIPへ梱包する。
# 入力AUF2は読取専用。出力ZIPとカタログJSONのXXH3_128だけを原子的に更新する。
# ビルド・ホスト起動・ネットワークへの公開は行わない。
# Copyright (c) 2026 VRAMの魔術師 / SPDX-License-Identifier: GPL-3.0-only
$ErrorActionPreference = 'Stop'
$packageName = 'SYNC_AutoWriting'
$projectDir = Split-Path -Parent $PSScriptRoot
if (-not $ReleaseDirectory) { $ReleaseDirectory = Join-Path $env:ProgramData "aviutl2\Plugin\$packageName" }
$pluginName = "$packageName.auf2"
$pluginPath = Join-Path $ReleaseDirectory $pluginName
if (-not (Test-Path -LiteralPath $pluginPath -PathType Leaf)) {
    throw "Release plugin not found: $pluginPath. Build the Win64 Release configuration first."
}

if (-not $XxhsumPath) {
    $XxhsumPath = Join-Path $projectDir 'Win64\Dependencies\xxHash-0.8.4\xxhsum.exe'
    if (-not (Test-Path -LiteralPath $XxhsumPath -PathType Leaf)) {
        $xxhsum = Get-Command xxhsum.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $xxhsum) { throw 'xxhsum.exe is required. See setup\README.md.' }
        $XxhsumPath = $xxhsum.Source
    }
}
$XxhsumPath = (Resolve-Path -LiteralPath $XxhsumPath).ProviderPath

$catalogPath = Join-Path $PSScriptRoot "$packageName.catalog.json"
$zipPath = Join-Path $PSScriptRoot "$packageName.zip"
$tempBase = Join-Path $PSScriptRoot ('.release-' + [guid]::NewGuid().ToString('N'))
$tempPlugin = "$tempBase-plugin.tmp"
$tempZip = "$tempBase-zip.tmp"
$tempCatalog = "$tempBase-catalog.tmp"
$tempNotices = "$tempBase-notices.tmp"
$tempReadme = "$tempBase-readme.tmp"
$catalogBackup = "$tempBase-previous-catalog.tmp"

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$lock = [Threading.Mutex]::new($false, "Local\VRAMWIZ.$packageName.ReleaseZip")
$ownsLock = $false
try {
    try { $ownsLock = $lock.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsLock = $true }
    if (-not $ownsLock) { throw 'Another release ZIP is being created. Run the batch again.' }

    $catalogSource = [IO.File]::ReadAllText($catalogPath)
    if ($catalogSource -notmatch '^\s*\[') { throw 'The catalog root must be a JSON array.' }
    $catalog = [object[]]($catalogSource | ConvertFrom-Json)
    if ($catalog.Count -ne 1 -or $catalog[0].id -cne "VRAMWIZ.$packageName") {
        throw "The catalog must contain only VRAMWIZ.$packageName."
    }
    $entry = $catalog[0]
    $github = $entry.installer.source.github
    if ($github.owner -cne 'vramwiz' -or $github.repo -cne $packageName -or
        [string]::IsNullOrWhiteSpace($github.pattern) -or
        "$packageName.zip" -cnotmatch $github.pattern) {
        throw 'The catalog GitHub source must match this repository and ZIP name.'
    }
    $copyEntry = @($entry.installer.install | Where-Object action -ceq 'copy')
    if ($copyEntry.Count -ne 1 -or $copyEntry[0].from -cne "{tmp}/$packageName" -or
        $copyEntry[0].to -cne "{pluginsDir}/$packageName") {
        throw 'The catalog install paths must match the ZIP root and plugin directory.'
    }
    if (@($entry.version).Count -eq 0) { throw 'The catalog must contain a release version.' }
    if ($entry.version[0].version -cne 'v1.0.0') {
        throw 'The first public AutoWriting version must be v1.0.0.'
    }
    $version = $catalog[0].version[-1]
    if ($version.version -cnotmatch '^v[1-9][0-9]*\.[0-9]+\.[0-9]+$') {
        throw 'The catalog must use a public v1.0.0-or-later version, not an internal development number.'
    }
    $publicVersion = $version.version.Substring(1)
    $releaseDate = [datetime]::MinValue
    if ([string]::IsNullOrWhiteSpace($version.version) -or
        @($entry.version | Where-Object version -ceq $version.version).Count -ne 1 -or
        -not [datetime]::TryParseExact($version.release_date, 'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$releaseDate)) {
        throw 'The last catalog version must have a unique name and a valid yyyy-MM-dd release date.'
    }
    $pluginEntry = @($version.file | Where-Object path -ceq "{pluginsDir}/$packageName/$pluginName")
    if (@($version.file).Count -ne 1 -or $pluginEntry.Count -ne 1) {
        throw 'The last catalog version must list only the production AUF2 once.'
    }
    if (-not $pluginEntry[0].PSObject.Properties['XXH3_128'] -or
        ($pluginEntry[0].XXH3_128 -ne '' -and $pluginEntry[0].XXH3_128 -cnotmatch '^[0-9a-fA-F]{32}$')) {
        throw 'The AUF2 XXH3_128 must be empty or contain exactly 32 hexadecimal digits.'
    }

    # Hash the same AUF2 bytes that will go into the ZIP.
    Copy-Item -LiteralPath $pluginPath -Destination $tempPlugin
    $binaryInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($tempPlugin)
    $binaryVersion = '{0}.{1}.{2}' -f $binaryInfo.FileMajorPart, $binaryInfo.FileMinorPart, $binaryInfo.FileBuildPart
    if ($binaryInfo.ProductName -cne $packageName -or $binaryInfo.ProductVersion -cne $publicVersion -or
        $binaryVersion -cne $publicVersion -or $binaryInfo.FilePrivatePart -ne 0 -or $binaryInfo.IsDebug) {
        throw "Release AUF2 product/version must match $packageName v$publicVersion. Rebuild Win64 Release first."
    }
    $hashOutput = & $XxhsumPath -H128 --tag $tempPlugin
    if ($LASTEXITCODE -ne 0 -or ($hashOutput -join "`n") -notmatch ' = ([0-9a-f]{32})\s*\z') {
        throw 'Could not calculate the AUF2 XXH3-128 hash.'
    }
    $hash = $Matches[1].ToLowerInvariant()

    $packageFiles = [ordered]@{
        $pluginName = $tempPlugin
        'README.md' = $tempReadme
        'LICENSE' = Join-Path $projectDir 'LICENSE'
        'THIRD_PARTY_NOTICES.md' = $tempNotices
        'ThirdParty/LICENSE.AviUtl2-SDK.txt' = Join-Path $projectDir 'ThirdParty\LICENSE.AviUtl2-SDK.txt'
        'ThirdParty/LICENSE.CC-BY-SA-3.0.txt' = Join-Path $projectDir 'ThirdParty\LICENSE.CC-BY-SA-3.0.txt'
        'Data/StrokeReference/StrokeReference.bin' = Join-Path $projectDir 'Data\StrokeReference\StrokeReference.bin'
        'Data/StrokeReference/NOTICE.md' = Join-Path $projectDir 'Data\StrokeReference\NOTICE.md'
        'Data/StrokeReference/Manifest.json' = Join-Path $projectDir 'Data\StrokeReference\Manifest.json'
        'Data/StrokeReference/UPSTREAM-NOTICE.txt' = Join-Path $projectDir 'Data\StrokeReference\UPSTREAM-NOTICE.txt'
        'Data/StrokeReference/UPSTREAM-LICENSE.txt' = Join-Path $projectDir 'Data\StrokeReference\UPSTREAM-LICENSE.txt'
    }
    # 外部データと本体内の不変データを照合し、古いAUF2との誤梱包を拒否する。
    if (-not ('AutoWriting.ReferencePackageGuard' -as [type])) {
        Add-Type -TypeDefinition @'
namespace AutoWriting {
  public static class ReferencePackageGuard {
    public static bool Contains(byte[] binary, byte[] data) {
      for (int i = 0; i <= binary.Length - data.Length; i++) {
        if (binary[i] != data[0] || binary[i+1] != data[1]) continue;
        int k = 2;
        while (k < data.Length && binary[i+k] == data[k]) k++;
        if (k == data.Length) return true;
      }
      return false;
    }
  }
}
'@
    }
    $referencePath = $packageFiles['Data/StrokeReference/StrokeReference.bin']
    $referenceBytes = [IO.File]::ReadAllBytes($referencePath)
    if (-not [AutoWriting.ReferencePackageGuard]::Contains([IO.File]::ReadAllBytes($tempPlugin), $referenceBytes)) {
        throw 'Release AUF2 does not contain the packaged stroke reference. Rebuild it from the same generated data.'
    }
    # 開発用と配布用で同じライセンス配置を使用する。
    $notices = [IO.File]::ReadAllText((Join-Path $projectDir 'THIRD_PARTY_NOTICES.md'))
    [IO.File]::WriteAllText($tempNotices, $notices, [Text.UTF8Encoding]::new($false))
    # ルートREADMEを配布用にも使用する。画像はソース公開先を参照し、ZIP内の不足リンクを避ける。
    $readme = [IO.File]::ReadAllText((Join-Path $projectDir 'README.md'))
    $readme = $readme.Replace('](Sample/', "](https://raw.githubusercontent.com/vramwiz/$packageName/$($version.version)/Sample/")
    foreach ($document in @('note.md', 'docs/SPECIFICATION.md', 'docs/IMPLEMENTATION.md', 'setup/README.md')) {
        $readme = $readme.Replace("]($document)", "](https://github.com/vramwiz/$packageName/blob/$($version.version)/$document)")
    }
    [IO.File]::WriteAllText($tempReadme, $readme, [Text.UTF8Encoding]::new($false))
    foreach ($file in $packageFiles.Values) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Package file not found: $file" }
    }
    # インストールした全ファイルをアンインストールでき、他の場所を消さないことを確認する。
    $expectedPaths = @($packageFiles.Keys | ForEach-Object { "{pluginsDir}/$packageName/$_" })
    $deleteEntries = @($entry.installer.uninstall)
    $deletePaths = @($deleteEntries | Where-Object action -ceq 'delete' | ForEach-Object path)
    if ($deleteEntries.Count -ne $expectedPaths.Count -or $deletePaths.Count -ne $expectedPaths.Count -or
        @($deletePaths | Select-Object -Unique).Count -ne $expectedPaths.Count -or
        @(Compare-Object $expectedPaths $deletePaths -CaseSensitive).Count -ne 0) {
        throw 'The catalog uninstall paths must list every packaged file exactly once.'
    }
    $zip = [IO.Compression.ZipFile]::Open($tempZip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $packageFiles.GetEnumerator()) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.Value, "$packageName/$($file.Key)", [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally { $zip.Dispose() }

    if ([IO.File]::ReadAllText($catalogPath) -cne $catalogSource) {
        throw 'Catalog changed during packaging. Run the batch again.'
    }
    if ($pluginEntry[0].XXH3_128 -cne $hash) {
        $pluginEntry[0].XXH3_128 = $hash
        $json = ConvertTo-Json -InputObject $catalog -Depth 12
        [IO.File]::WriteAllText($tempCatalog, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
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
    if ([IO.File]::Exists($catalogBackup)) { [IO.File]::Delete($catalogBackup) }
}
finally {
    if ($ownsLock) { $lock.ReleaseMutex() }
    $lock.Dispose()
    foreach ($tempPath in @($tempPlugin, $tempZip, $tempCatalog, $tempNotices, $tempReadme)) {
        [IO.File]::Delete($tempPath)
    }
}

Write-Output "Created $zipPath"
Write-Output "Catalog $catalogPath ($($version.version), XXH3_128=$hash)"
