<#
  Measurement only (part 2):
  1. Fetch ONLY the needed Burn containers from the official bundle with HTTP range requests
     (PE header -> .wixburn -> UX manifest -> NoAsserts + Shared containers; Asserts skipped).
  2. Build the minimal portable layout (bld+cli+res NoAsserts, rtl, windows.msi trimmed to host arch).
  3. Deduplicate identical files (MSI cannot express links, so swift-frontend/clang/lld are copied N times)
     and measure on-disk size, zip / tar.gz (hardlinks) / 7z sizes, and extraction with Windows' tar.exe.
#>
param(
  [string]$SwiftVersion = '6.4.3',
  [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
  [string]$Work = 'C:\s',
  [string]$Out = "$PWD\out"
)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Work, $Out | Out-Null
$r = [ordered]@{ swift_version = $SwiftVersion; arch = $Arch }
function MB($b) { [math]::Round($b / 1MB, 1) }
function SizeOf($p) { $s = (Get-ChildItem -LiteralPath $p -Recurse -File -Force | Measure-Object Length -Sum).Sum; if ($s) { [long]$s } else { 0 } }
function Get-Range($url, [long]$from, [long]$len, $dest) {
  & curl.exe -L --fail --retry 3 -s -S -r "$from-$($from + $len - 1)" -o $dest $url
  if ($LASTEXITCODE) { throw "range get failed $from+$len" }
  if ((Get-Item $dest).Length -ne $len) { throw "short range read: got $((Get-Item $dest).Length), want $len" }
}
$suffix = if ($Arch -eq 'arm64') { '-arm64' } else { '' }
$url = "https://download.swift.org/swift-$SwiftVersion-release/windows10$suffix/swift-$SwiftVersion-RELEASE/swift-$SwiftVersion-RELEASE-windows10$suffix.exe"
$total = [long](((& curl.exe -sIL $url) | Where-Object { $_ -match '^content-length:' } | Select-Object -Last 1) -replace '\D', '')
$r.bundle_mb = MB $total
$fetched = 0L
$t = [Diagnostics.Stopwatch]::StartNew()

# PE headers live in the first few KB; the .wixburn section header tells us where the burn header is
$h = Join-Path $Work 'head.bin'; Get-Range $url 0 65536 $h; $fetched += 65536
$b = [IO.File]::ReadAllBytes($h)
$pe = [BitConverter]::ToInt32($b, 0x3C); $nsec = [BitConverter]::ToUInt16($b, $pe + 6); $opt = [BitConverter]::ToUInt16($b, $pe + 20); $sec = $pe + 24 + $opt
for ($i = 0; $i -lt $nsec; $i++) { $nm = [Text.Encoding]::ASCII.GetString($b, $sec + 40 * $i, 8).TrimEnd([char]0); if ($nm -eq '.wixburn') { $raw = [BitConverter]::ToUInt32($b, $sec + 40 * $i + 20) } }
$bh = Join-Path $Work 'burn.bin'; Get-Range $url $raw 512 $bh; $fetched += 512
$bb = [IO.File]::ReadAllBytes($bh)
$stub = [long][BitConverter]::ToUInt32($bb, 24); $count = [BitConverter]::ToUInt32($bb, 44)
$sizes = @(); for ($k = 0; $k -lt $count; $k++) { $sizes += [long][BitConverter]::ToUInt32($bb, 48 + 4 * $k) }
# Locate each container: scan a 1 MB window after the previous one for the CAB header with the expected size
function Find-Cab([long]$from, [long]$size) {
  $w = Join-Path $Work 'win.bin'; Get-Range $url $from 1048576 $w; $script:fetched += 1048576
  $x = [IO.File]::ReadAllBytes($w)
  for ($j = 0; $j -le $x.Length - 12; $j++) { if ($x[$j] -eq 0x4D -and $x[$j + 1] -eq 0x53 -and $x[$j + 2] -eq 0x43 -and $x[$j + 3] -eq 0x46 -and [BitConverter]::ToUInt32($x, $j + 8) -eq $size) { return $from + $j } }
  throw "cab not found after $from"
}
$offs = @(); $off = $stub
for ($idx = 0; $idx -lt $count; $idx++) {
  # container offsets: after UX we must skip the signature blob; we only know sizes, so search sequentially
  $o = Find-Cab $off $sizes[$idx]; $offs += $o; $off = $o + $sizes[$idx]
}
$ux = Join-Path $Work 'c0'; New-Item -ItemType Directory -Force $ux | Out-Null
Get-Range $url $offs[0] $sizes[0] "$Work\ux.cab"; $fetched += $sizes[0]
& expand.exe -F:* "$Work\ux.cab" $ux | Out-Null
[xml]$man = Get-Content -Raw "$ux\0"
$want = @{}
foreach ($c in $man.GetElementsByTagName('Container')) { if ($c.GetAttribute('Id') -notmatch '^Asserts') { $want[[int]$c.GetAttribute('AttachedIndex')] = $c.GetAttribute('Id') } }
foreach ($ci in $want.Keys) {
  $cab = "$Work\container$ci.cab"; Get-Range $url $offs[$ci] $sizes[$ci] $cab; $fetched += $sizes[$ci]
  New-Item -ItemType Directory -Force "$Work\c$ci" | Out-Null; & expand.exe -F:* $cab "$Work\c$ci" | Out-Null; Remove-Item $cab
}
$r.range_fetched_mb = MB $fetched
$r.range_fetch_and_expand_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
$r.containers_fetched = @($want.Values)
foreach ($p in $man.GetElementsByTagName('Payload')) {
  $sp = $p.GetAttribute('SourcePath'); $fp = $p.GetAttribute('FilePath'); if (-not $sp -or -not $fp) { continue }
  foreach ($ci in $want.Keys) { $f = "$Work\c$ci\$sp"; if (Test-Path $f) { New-Item -ItemType Directory -Force "$Work\p" | Out-Null; Move-Item -Force $f "$Work\p\$fp" } }
}
Get-ChildItem "$Work\p" | ForEach-Object { '{0,9:n1} MB  {1}' -f ($_.Length / 1MB), $_.Name } | Set-Content "$Out\fetched-payloads.txt"

# ---- minimal layout
$t.Restart()
$dest = 'C:\m\Swift'; $i = 0
$rtlPat = if ($Arch -eq 'arm64') { 'rtl\.arm64' } else { 'rtl\.amd64' }
foreach ($m in Get-ChildItem "$Work\p" -Filter *.msi) {
  if ($m.Name -notmatch "^(bld|cli|res|windows)|$rtlPat") { continue }
  $i++; $tgt = "C:\x\$i"
  $pr = Start-Process msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$tgt`"") -Wait -PassThru
  if ($pr.ExitCode) { throw "msiexec /a $($m.Name) -> $($pr.ExitCode)" }
  Get-ChildItem $tgt -Filter *.msi | Remove-Item -Force
  $pu = Join-Path $tgt 'LocalApp\Programs\Swift'
  if (Test-Path $pu) { & robocopy.exe $pu $dest /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null }
  else { & robocopy.exe $tgt "$dest\Runtimes\$SwiftVersion\usr\bin" /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null }
}
$r.msiexec_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
$sdkArch = if ($Arch -eq 'arm64') { 'aarch64' } else { 'x86_64' }
$sdk = Get-ChildItem "$dest\Platforms" -Recurse -Directory -Filter 'Windows.sdk' | Select-Object -First 1
foreach ($a in 'x86_64', 'aarch64', 'i686') { if ($a -ne $sdkArch) { Get-ChildItem $sdk.FullName -Recurse -Directory -Filter $a | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }
Get-ChildItem $sdk.FullName -Recurse -File | Where-Object { $_.Name -match '(x86_64|aarch64|i686)-unknown' -and $_.Name -notmatch $sdkArch } | Remove-Item -Force
Remove-Item -Recurse -Force "$dest\Redistributables" -ErrorAction SilentlyContinue   # .msm merge modules: installer-authoring only
$r.minimal_on_disk_mb = MB (SizeOf 'C:\m')
$r.minimal_swift_static_mb = MB (SizeOf (Join-Path $sdk.FullName 'usr\lib\swift_static'))

# ---- dedup identical files with hardlinks
$t.Restart()
$dups = Get-ChildItem 'C:\m' -Recurse -File | Where-Object Length -gt 1MB | Group-Object Length | Where-Object Count -gt 1
$saved = 0L; $links = 0; $dupList = @()
foreach ($g in $dups) {
  $byHash = $g.Group | Group-Object { (Get-FileHash -Algorithm SHA256 $_.FullName).Hash } | Where-Object Count -gt 1
  foreach ($hg in $byHash) {
    $keep = $hg.Group[0]
    $dupList += ('{0,8:n1} MB x{1}  {2}' -f ($keep.Length / 1MB), $hg.Count, (($hg.Group | ForEach-Object Name) -join ', '))
    foreach ($d in $hg.Group | Select-Object -Skip 1) {
      Remove-Item -Force $d.FullName
      New-Item -ItemType HardLink -Path $d.FullName -Target $keep.FullName | Out-Null
      $saved += $keep.Length; $links++
    }
  }
}
$dupList | Set-Content "$Out\duplicates.txt"
$r.dedup_saved_mb = MB $saved; $r.dedup_links = $links; $r.dedup_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
$r.minimal_unique_mb = $r.minimal_on_disk_mb - $r.dedup_saved_mb

# ---- archives
$t.Restart(); & tar.exe -a -cf C:\m.zip -C C:\m Swift; $r.zip_mb = MB (Get-Item C:\m.zip).Length; $r.zip_create_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
$t.Restart(); & tar.exe -czf C:\m.tar.gz -C C:\m Swift; $r.targz_hardlinks_mb = MB (Get-Item C:\m.tar.gz).Length; $r.targz_create_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
& tar.exe --version | Out-String | ForEach-Object { $r.tar_version = $_.Trim() }
foreach ($fmt in @(@{n = 'xz'; f = '-cJf'; e = 'tar.xz' }, @{n = 'zstd'; f = '--zstd -cf'; e = 'tar.zst' })) {
  $t.Restart(); $o = "C:\m.$($fmt.e)"
  $args2 = @($fmt.f.Split(' ')) + @($o, '-C', 'C:\m', 'Swift')
  & tar.exe @args2 2>$null
  if ($LASTEXITCODE -eq 0 -and (Test-Path $o)) { $r["tar_$($fmt.n)_mb"] = MB (Get-Item $o).Length; $r["tar_$($fmt.n)_s"] = [math]::Round($t.Elapsed.TotalSeconds, 1) } else { $r["tar_$($fmt.n)_mb"] = 'unsupported' }
}
if (Get-Command 7z -ErrorAction SilentlyContinue) { $t.Restart(); & 7z a -t7z -mx=9 -bd -bso0 C:\m.7z C:\m\Swift | Out-Null; $r.sevenz_mx9_mb = MB (Get-Item C:\m.7z).Length; $r.sevenz_s = [math]::Round($t.Elapsed.TotalSeconds, 1) }
# extraction with the in-box tar.exe: are hardlinks restored? how long?
New-Item -ItemType Directory -Force C:\u | Out-Null
$t.Restart(); & tar.exe -xf C:\m.tar.gz -C C:\u; $r.targz_extract_s = [math]::Round($t.Elapsed.TotalSeconds, 1); $r.targz_extract_exit = $LASTEXITCODE
$fe = Get-ChildItem C:\u -Recurse -Filter swift-frontend.exe | Select-Object -First 1
if ($fe) { $r.extracted_swift_frontend_links = (& fsutil.exe hardlink list $fe.FullName | Measure-Object).Count }
$r.extracted_files = (Get-ChildItem C:\u -Recurse -File).Count; $r.source_files = (Get-ChildItem C:\m -Recurse -File).Count
$vol = Get-PSDrive C; $r.note = 'sizes: on-disk of extracted tree counts hardlinks once per link in SizeOf; use dedup_saved_mb'
$r | ConvertTo-Json -Depth 4 | Set-Content "$Out\minimal.json"
Get-Content "$Out\minimal.json" | Write-Host
"## Minimal portable layout ($Arch)`n``````json`n$(Get-Content -Raw "$Out\minimal.json")`n``````" >> $env:GITHUB_STEP_SUMMARY
