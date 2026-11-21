<#
  Measurement only: what is inside the official Swift Windows Burn bundle, how big is each
  component once extracted, and how small could a portable zip be?
  Writes everything to $Out (uploaded as an artifact).
#>
param(
  [string]$SwiftVersion = '6.4.3',
  [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
  [string]$Work = 'C:\s',
  [string]$Out = "$PWD\out"
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Work, $Out | Out-Null
$report = [ordered]@{ swift_version = $SwiftVersion; arch = $Arch }

function SizeOf($p) {
  if (-not (Test-Path -LiteralPath $p)) { return 0 }
  $s = (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if (-not $s) { 0 } else { [long]$s }
}
function MB($b) { [math]::Round($b / 1MB, 1) }

function Copy-StreamRange([System.IO.FileStream]$src, [long]$offset, [long]$length, [string]$dest) {
  $src.Position = $offset
  $o = [System.IO.File]::Create($dest)
  try {
    $buf = New-Object byte[] (4MB); $left = $length
    while ($left -gt 0) { $n = $src.Read($buf, 0, [int][math]::Min($buf.Length, $left)); if ($n -le 0) { throw 'EOF' }; $o.Write($buf, 0, $n); $left -= $n }
  } finally { $o.Dispose() }
}

# ---- download
$suffix = if ($Arch -eq 'arm64') { '-arm64' } else { '' }
$url = "https://download.swift.org/swift-$SwiftVersion-release/windows10$suffix/swift-$SwiftVersion-RELEASE/swift-$SwiftVersion-RELEASE-windows10$suffix.exe"
$bundle = Join-Path $Work 'bundle.exe'
$t = [Diagnostics.Stopwatch]::StartNew()
& curl.exe -L --fail --retry 3 -s -S -o $bundle $url
if ($LASTEXITCODE) { throw "download failed $url" }
$report.bundle_url = $url
$report.bundle_mb = MB (Get-Item $bundle).Length
$report.download_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

# Does download.swift.org also host loose MSIs/CABs next to the bundle? (probe a few names)
$base = $url.Substring(0, $url.LastIndexOf('/') + 1)
$probe = [ordered]@{}
foreach ($n in 'bld.asserts.msi', 'bld.msi', 'rtl.amd64.msi', 'windows.msi', 'swift-' + $SwiftVersion + '-RELEASE-windows10' + $suffix + '.zip', 'swift-' + $SwiftVersion + '-RELEASE-windows10' + $suffix + '.exe.sig') {
  $code = & curl.exe -s -o NUL -w '%{http_code}' -I ($base + $n)
  $probe[$n] = $code
}
$report.loose_file_probe = $probe

# ---- carve burn containers
$t.Restart()
$fs = [IO.File]::OpenRead($bundle); $br = New-Object IO.BinaryReader($fs)
$fs.Position = 0x3C; $pe = $br.ReadInt32(); $fs.Position = $pe + 6; $nsec = $br.ReadUInt16()
$fs.Position = $pe + 20; $opt = $br.ReadUInt16(); $sec = $pe + 24 + $opt
for ($i = 0; $i -lt $nsec; $i++) { $fs.Position = $sec + 40 * $i; $nm = [Text.Encoding]::ASCII.GetString($br.ReadBytes(8)).TrimEnd([char]0); if ($nm -eq '.wixburn') { $fs.Position = $sec + 40 * $i + 20; $raw = $br.ReadUInt32() } }
$fs.Position = $raw + 24; $stub = [long]$br.ReadUInt32(); $fs.Position = $raw + 44; $count = $br.ReadUInt32()
$sizes = @(); for ($k = 0; $k -lt $count; $k++) { $sizes += [long]$br.ReadUInt32() }
$report.engine_stub_kb = [math]::Round($stub / 1KB)
$off = $stub; $cabs = @()
for ($idx = 0; $idx -lt $count; $idx++) {
  $fs.Position = $off; $win = $br.ReadBytes(1MB); $found = -1
  for ($j = 0; $j -le $win.Length - 12; $j++) { if ($win[$j] -eq 0x4D -and $win[$j + 1] -eq 0x53 -and $win[$j + 2] -eq 0x43 -and $win[$j + 3] -eq 0x46 -and [BitConverter]::ToUInt32($win, $j + 8) -eq $sizes[$idx]) { $found = $j; break } }
  if ($found -lt 0) { throw "container $idx not found" }
  $off += $found; $cab = Join-Path $Work "container$idx.cab"; Copy-StreamRange $fs $off $sizes[$idx] $cab; $cabs += $cab; $off += $sizes[$idx]
}
$fs.Dispose()
$report.containers_mb = @($sizes | ForEach-Object { MB $_ })
$ci = 0
foreach ($cab in $cabs) { $d = Join-Path $Work "c$ci"; New-Item -ItemType Directory -Force $d | Out-Null; & expand.exe -F:* $cab $d | Out-Null; Remove-Item $cab; $ci++ }
$report.carve_expand_s = [math]::Round($t.Elapsed.TotalSeconds, 1)

# UX container: burn manifest (0) + BootstrapperApplicationData etc.
New-Item -ItemType Directory -Force "$Out\ux" | Out-Null
Copy-Item "$Work\c0\*" "$Out\ux\" -Recurse
[xml]$man = Get-Content -Raw "$Work\c0\0"
$containers = @{}
foreach ($c in $man.GetElementsByTagName('Container')) { $containers[$c.GetAttribute('Id')] = [ordered]@{ attached = $c.GetAttribute('Attached'); index = $c.GetAttribute('AttachedIndex'); size = $c.GetAttribute('FileSize'); url = $c.GetAttribute('DownloadUrl') } }
$report.manifest_containers = $containers
$payloads = @()
foreach ($p in $man.GetElementsByTagName('Payload')) {
  $payloads += [pscustomobject]@{ Id = $p.GetAttribute('Id'); FilePath = $p.GetAttribute('FilePath'); SourcePath = $p.GetAttribute('SourcePath'); Container = $p.GetAttribute('Container'); Packaging = $p.GetAttribute('Packaging'); MB = MB ([long]('0' + $p.GetAttribute('FileSize'))); DownloadUrl = $p.GetAttribute('DownloadUrl') }
}
$payloads | Sort-Object MB -Descending | Format-Table -AutoSize | Out-String -Width 400 | Set-Content "$Out\payloads.txt"
$report.payloads_with_download_url = @($payloads | Where-Object DownloadUrl).Count
$report.payloads_external = @($payloads | Where-Object { $_.Packaging -eq 'external' }).Count
$pkgs = @()
foreach ($p in $man.GetElementsByTagName('MsiPackage')) { $pkgs += [pscustomobject]@{ Id = $p.GetAttribute('Id'); InstallSize = MB ([long]('0' + $p.GetAttribute('InstallSize'))); Size = MB ([long]('0' + $p.GetAttribute('Size'))); Cache = $p.GetAttribute('Cache'); PerMachine = $p.GetAttribute('PerMachine'); InstallCondition = $p.GetAttribute('InstallCondition') } }
$pkgs | Format-Table -AutoSize | Out-String -Width 400 | Set-Content "$Out\packages.txt"
Get-Content "$Out\packages.txt" | Write-Host

# map payloads to real file names
foreach ($p in $payloads) {
  if (-not $p.SourcePath -or -not $p.FilePath) { continue }
  for ($c = 1; $c -lt $cabs.Count; $c++) {
    $f = Join-Path $Work "c$c\$($p.SourcePath)"
    if (Test-Path $f) { $dest = Join-Path $Work "p\$($p.Container)\$($p.FilePath)"; New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null; Move-Item -Force $f $dest }
  }
}
Get-ChildItem "$Work\p" -Recurse -File | ForEach-Object { '{0,9:n1} MB  {1}' -f ($_.Length / 1MB), $_.FullName.Substring($Work.Length) } | Set-Content "$Out\payload-files.txt"
Get-Content "$Out\payload-files.txt" | Write-Host

# ---- admin-extract every MSI separately and measure
$msiRows = @(); $i = 0
foreach ($m in Get-ChildItem "$Work\p" -Recurse -Filter *.msi) {
  $i++; $tgt = "C:\x\$i"
  $t.Restart()
  $pr = Start-Process msiexec.exe -ArgumentList @('/a', "`"$($m.FullName)`"", '/qn', "TARGETDIR=`"$tgt`"") -Wait -PassThru
  $secs = [math]::Round($t.Elapsed.TotalSeconds, 1)
  Get-ChildItem $tgt -Filter *.msi -ErrorAction SilentlyContinue | Remove-Item -Force
  $files = Get-ChildItem $tgt -Recurse -File -Force -ErrorAction SilentlyContinue
  $tot = ($files | Measure-Object Length -Sum).Sum
  $byExt = $files | Group-Object { $_.Extension.ToLowerInvariant() } | ForEach-Object { [pscustomobject]@{ ext = $_.Name; mb = MB (($_.Group | Measure-Object Length -Sum).Sum); n = $_.Count } } | Sort-Object mb -Descending | Select-Object -First 8
  $rel = $m.FullName.Substring("$Work\p\".Length)
  $msiRows += [pscustomobject]@{ msi = $rel; dir = $tgt; exit = $pr.ExitCode; secs = $secs; mb = MB $tot; files = $files.Count; pdb_mb = MB (($files | Where-Object Extension -eq '.pdb' | Measure-Object Length -Sum).Sum); top_ext = (($byExt | ForEach-Object { "$($_.ext)=$($_.mb)" }) -join ' ') }
  # big directories (> 20 MB) for this MSI
  Add-Content "$Out\big-dirs.txt" "### $rel"
  Get-ChildItem $tgt -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName.Split('\').Count -le 14 } | ForEach-Object {
    $s = SizeOf $_.FullName; if ($s -gt 20MB) { '{0,9:n1} MB  {1}' -f ($s / 1MB), $_.FullName }
  } | Add-Content "$Out\big-dirs.txt"
  # biggest files
  Add-Content "$Out\big-files.txt" "### $rel"
  $files | Sort-Object Length -Descending | Select-Object -First 25 | ForEach-Object { '{0,9:n1} MB  {1}' -f ($_.Length / 1MB), $_.FullName } | Add-Content "$Out\big-files.txt"
}
$msiRows | Format-Table -AutoSize | Out-String -Width 500 | Set-Content "$Out\msis.txt"
Get-Content "$Out\msis.txt" | Write-Host
$report.msis = $msiRows

# ---- build candidate portable layouts and compress them
$sdkArch = if ($Arch -eq 'arm64') { 'aarch64' } else { 'x86_64' }
function Merge-Msi($row, $dest) {
  $pu = Join-Path $row.dir 'LocalApp\Programs\Swift'
  if (Test-Path $pu) { & robocopy.exe $pu $dest /E /NFL /NDL /NJH /NJS /NP | Out-Null }
  elseif ($row.msi -match 'rtl') { & robocopy.exe $row.dir "$dest\Runtimes\$SwiftVersion\usr\bin" /E /NFL /NDL /NJH /NJS /NP | Out-Null }
}
function Test-Pick($row, [string[]]$want, [string]$asserts) {
  $n = [IO.Path]::GetFileName($row.msi).ToLowerInvariant(); $full = $row.msi.ToLowerInvariant()
  foreach ($w in $want) {
    if ($n -like "$w*") {
      if ($w -in 'bld', 'cli', 'dbg', 'ide') { if ($asserts -eq 'noasserts' -and $full -notmatch 'noasserts') { return $false }; if ($asserts -eq 'asserts' -and $full -match 'noasserts') { return $false } }
      if ($w -eq 'rtl' -and $n -notmatch $(if ($Arch -eq 'arm64') { 'arm64|aarch64' } else { 'amd64|x64' })) { return $false }
      return $true
    }
  }
  return $false
}
$variants = [ordered]@{
  'A_full_asserts_as_today' = @{ want = @('bld', 'cli', 'dbg', 'ide', 'python', 'res', 'rtl', 'windows'); asserts = 'asserts'; trimSdk = $false; noPdb = $false }
  'B_noasserts_all' = @{ want = @('bld', 'cli', 'dbg', 'ide', 'python', 'res', 'rtl', 'windows'); asserts = 'noasserts'; trimSdk = $false; noPdb = $false }
  'C_noasserts_hostsdk_nopdb' = @{ want = @('bld', 'cli', 'dbg', 'ide', 'python', 'res', 'rtl', 'windows'); asserts = 'noasserts'; trimSdk = $true; noPdb = $true }
  'D_minimal_compiler_spm_hostsdk_nopdb' = @{ want = @('bld', 'cli', 'res', 'rtl', 'windows'); asserts = 'noasserts'; trimSdk = $true; noPdb = $true }
}
$sz = @()
$has7z = [bool](Get-Command 7z -ErrorAction SilentlyContinue)
foreach ($k in $variants.Keys) {
  $v = $variants[$k]; $dest = "C:\v\$k\Swift"
  foreach ($row in $msiRows) { if (Test-Pick $row $v.want $v.asserts) { Merge-Msi $row $dest } }
  if ($v.trimSdk) {
    $sdk = Get-ChildItem "$dest\Platforms" -Recurse -Directory -Filter 'Windows.sdk' | Select-Object -First 1
    if ($sdk) {
      foreach ($a in 'x86_64', 'aarch64', 'i686', 'armv7') { if ($a -ne $sdkArch) { Get-ChildItem $sdk.FullName -Recurse -Directory -Filter $a -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue } }
      Get-ChildItem $sdk.FullName -Recurse -File | Where-Object { $_.Name -match '(x86_64|aarch64|i686|armv7)' -and $_.Name -notmatch $sdkArch } | Remove-Item -Force
    }
  }
  if ($v.noPdb) { Get-ChildItem "C:\v\$k" -Recurse -File -Filter *.pdb | Remove-Item -Force }
  $raw = SizeOf "C:\v\$k"
  $row = [ordered]@{ variant = $k; on_disk_mb = MB $raw; files = (Get-ChildItem "C:\v\$k" -Recurse -File).Count }
  $t.Restart()
  $zip = "C:\v\$k.zip"
  if ($has7z) { & 7z a -tzip -mx=5 -bd -bso0 $zip "C:\v\$k\*" | Out-Null } else { & tar.exe -a -cf $zip -C "C:\v\$k" Swift }
  $row.zip_mb = MB (Get-Item $zip).Length; $row.zip_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
  if ($has7z -and $k -like 'D_*') {
    $t.Restart(); & 7z a -t7z -mx=9 -bd -bso0 "C:\v\$k.7z" "C:\v\$k\*" | Out-Null
    $row.sevenz_mx9_mb = MB (Get-Item "C:\v\$k.7z").Length; $row.sevenz_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
    # extraction time of the zip (what a user would pay)
    New-Item -ItemType Directory -Force "C:\v\unz_$k" | Out-Null
    $t.Restart(); & tar.exe -xf $zip -C "C:\v\unz_$k"
    $row.unzip_tar_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
    $t.Restart(); Expand-Archive -Path $zip -DestinationPath "C:\v\unz2_$k" -Force
    $row.unzip_expandarchive_s = [math]::Round($t.Elapsed.TotalSeconds, 1)
    Remove-Item -Recurse -Force "C:\v\unz_$k", "C:\v\unz2_$k" -ErrorAction SilentlyContinue
  }
  Remove-Item $zip -Force
  $sz += [pscustomobject]$row
  Write-Host ($row | ConvertTo-Json -Compress)
  # what is biggest in the minimal variant?
  if ($k -like 'D_*') {
    Get-ChildItem "C:\v\$k" -Recurse -File | Sort-Object Length -Descending | Select-Object -First 40 | ForEach-Object { '{0,9:n1} MB  {1}' -f ($_.Length / 1MB), $_.FullName } | Set-Content "$Out\minimal-biggest-files.txt"
    Get-ChildItem "C:\v\$k" -Recurse -Directory | Where-Object { $_.FullName.Split('\').Count -le 12 } | ForEach-Object { $s = SizeOf $_.FullName; if ($s -gt 10MB) { '{0,9:n1} MB  {1}' -f ($s / 1MB), $_.FullName } } | Set-Content "$Out\minimal-big-dirs.txt"
  }
  Remove-Item -Recurse -Force "C:\v\$k" -ErrorAction SilentlyContinue
}
$report.variants = $sz
$sz | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$report | ConvertTo-Json -Depth 6 | Set-Content "$Out\report.json"
"## Bundle inspection ($Arch)`n``````json`n$($report | ConvertTo-Json -Depth 6)`n``````" >> $env:GITHUB_STEP_SUMMARY
