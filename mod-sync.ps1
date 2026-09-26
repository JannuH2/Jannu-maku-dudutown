param(
    [string]$PackUrl = "https://jannuh2.github.io/Jannu-maku-dudutown/pack.toml",
    [string]$ManifestPath = "packwiz.json",
    [string]$ModsDir = "mods"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
# Invoke-WebRequest's default progress-bar rendering is extremely slow for
# larger files in Windows PowerShell 5.1 and can make big mods time out or
# fail entirely; this is a well-known fix with no downside.
$ProgressPreference = "SilentlyContinue"
$BaseUrl = $PackUrl.Substring(0, $PackUrl.LastIndexOf("/") + 1)

function Get-UrlText {
    param([string]$Uri)
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $Uri
    $content = $resp.Content
    if ($content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($content)
    }
    return $content
}

function Get-TomlValue {
    param([string]$Text, [string]$Key)
    $m = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))\s*=\s*""(.*)""\s*$")
    if ($m.Success) { return $m.Groups[1].Value }
    $m2 = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))\s*=\s*(\d+)\s*$")
    if ($m2.Success) { return $m2.Groups[1].Value }
    $m3 = [regex]::Match($Text, "(?m)^$([regex]::Escape($Key))\s*=\s*(true|false)\s*$")
    if ($m3.Success) { return $m3.Groups[1].Value }
    return $null
}

Write-Host "모드팩 정보를 확인하는 중입니다..."

try {
    $packText = Get-UrlText $PackUrl
} catch {
    Write-Host "[오류] pack.toml을 가져오지 못했습니다: $($_.Exception.Message)"
    exit 1
}

$indexFile = Get-TomlValue $packText "file"
$indexUrl = $BaseUrl + $indexFile

try {
    $indexText = Get-UrlText $indexUrl
} catch {
    Write-Host "[오류] index.toml을 가져오지 못했습니다: $($_.Exception.Message)"
    exit 1
}

# Parse index.toml into a list of {file, metafile, hash} - mods/ and config/ only.
# config/ entries are always plain (non-metafile) files, e.g. a config a custom
# mod needs to work the same for everyone; they're synced like mods but never
# scanned for stray/personal files (that folder holds many unrelated per-mod
# configs nobody wants this tool touching).
$entries = @()
$blocks = $indexText -split '\[\[files\]\]'
foreach ($b in $blocks) {
    $f = Get-TomlValue $b "file"
    if (-not $f) { continue }
    if (-not ($f.StartsWith("mods/") -or $f.StartsWith("config/"))) { continue }
    $isMeta = $b -match '(?m)^metafile\s*=\s*true\s*$'
    $entryHash = Get-TomlValue $b "hash"
    $entries += [PSCustomObject]@{ file = $f; metafile = $isMeta; hash = $entryHash }
}

Write-Host "$($entries.Count)개 항목을 찾았습니다. 각 모드 정보를 불러오는 중..."

# Load existing manifest (previous install state) - used only to recognize stale
# (already-tracked-but-outdated) local files by their old filename.
$cachedFiles = @{}
if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        if ($manifest.cachedFiles) {
            foreach ($prop in $manifest.cachedFiles.PSObject.Properties) {
                $cachedFiles[$prop.Name] = $prop.Value
            }
        }
    } catch { }
}

$mods = @()
foreach ($e in $entries) {
    if ($e.metafile) {
        $pwUrl = $BaseUrl + $e.file
        try {
            $pwText = Get-UrlText $pwUrl
        } catch {
            Write-Host "  [건너뜀] $($e.file) 을(를) 불러오지 못함"
            continue
        }
        $name = Get-TomlValue $pwText "name"
        $filename = Get-TomlValue $pwText "filename"
        $side = Get-TomlValue $pwText "side"
        if (-not $side) { $side = "both" }
        $url = Get-TomlValue $pwText "url"
        $hashFormat = Get-TomlValue $pwText "hash-format"
        $hash = Get-TomlValue $pwText "hash"
        $fileId = Get-TomlValue $pwText "file-id"
        $projectId = Get-TomlValue $pwText "project-id"
        $optional = (Get-TomlValue $pwText "optional") -eq "true"
        $default = (Get-TomlValue $pwText "default") -eq "true"

        if (-not $url -and $fileId -and $projectId) {
            $url = "https://www.curseforge.com/api/v1/mods/$projectId/files/$fileId/download"
        }

        $mods += [PSCustomObject]@{
            pwPath     = $e.file
            name       = $(if ($name) { $name } else { $filename })
            filename   = $filename
            side       = $side
            url        = $url
            hashFormat = $hashFormat
            hash       = $hash
            optional   = $optional
            default    = $default
        }
    } else {
        $filename = Split-Path $e.file -Leaf
        $mods += [PSCustomObject]@{
            pwPath     = $e.file
            name       = $filename
            filename   = $filename
            side       = "both"
            url        = $BaseUrl + $e.file
            hashFormat = "sha256"
            hash       = $e.hash
            optional   = $false
            default    = $true
        }
    }
}

# All filenames the pack currently expects, regardless of side (used to tell
# "personal mod" apart from "mod this pack tracks under a different side").
$allExpectedNames = @{}
foreach ($m in $mods) { $allExpectedNames[$m.filename] = $true }

# Names previously installed by this tool, by pwPath (for detecting a stale
# version of a tracked mod vs. a genuinely untracked personal mod).
$allCachedNames = @{}
foreach ($k in $cachedFiles.Keys) {
    $loc = $cachedFiles[$k].cachedLocation
    if ($loc) { $allCachedNames[(Split-Path $loc -Leaf)] = $true }
}

# A filename's "stem" strips version numbers/separators so that e.g.
# "alexsmobsfabric-1.21.1-1.4.0.jar" and "...-1.4.1.jar" compare equal. Used to
# recognize a leftover old-version jar of a mod the pack still tracks (just
# under a newer filename) even when the local cachedFiles manifest has no
# record of it at all - e.g. a fresh CurseForge modpack import, or a manual
# jar fix distributed straight to players before it was ever synced by this
# tool - so it defaults to deletion instead of silently sitting there forever.
function Get-NameStem([string]$Name) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $stem = $base -replace '[0-9]+(\.[0-9]+)*', '' -replace '[-_+.\s]+', ''
    return $stem.ToLower()
}
$expectedStems = @{}
foreach ($m in $mods) {
    $stem = Get-NameStem $m.filename
    if ($stem) { $expectedStems[$stem] = $true }
}

$clientMods = $mods | Where-Object { $_.side -eq "both" -or $_.side -eq "client" }

# ---- Row model ----
# kind: "pack" (tracked by the pack) or "personal" (local-only, not tracked)
# state (pack rows): "match" | "included" | "excluded"
# state (personal rows): "keep" | "delete"
$rows = @()

function Get-LocalDir($Mod) {
    $dir = Split-Path $Mod.pwPath -Parent
    if (-not $dir) { return $ModsDir }
    return $dir
}

function Test-ModHashMatches {
    param($Mod, [string]$Path)
    if (-not $Mod.hash -or -not $Mod.hashFormat) { return $true }
    $algo = if ($Mod.hashFormat -eq "sha1") { "SHA1" } elseif ($Mod.hashFormat -eq "sha512") { "SHA512" } else { "SHA256" }
    try {
        $actual = (Get-FileHash -LiteralPath $Path -Algorithm $algo).Hash.ToLower()
        return $actual -eq $Mod.hash.ToLower()
    } catch {
        # Can't verify (unreadable/locked file) - don't block on it, assume OK.
        return $true
    }
}

foreach ($m in $clientMods) {
    $prevLoc = $null
    if ($cachedFiles.ContainsKey($m.pwPath)) { $prevLoc = $cachedFiles[$m.pwPath].cachedLocation }
    $prevName = if ($prevLoc) { Split-Path $prevLoc -Leaf } else { $null }
    $expectedPath = Join-Path (Get-LocalDir $m) $m.filename
    # Existence alone isn't enough: a fix that patches a jar's *contents* while
    # keeping the same filename (e.g. a locally-repackaged jar) must still be
    # picked up for already-installed players, or the buggy file just sits there
    # forever looking "matched" and nobody ever gets the fix automatically.
    $existsAsExpected = (Test-Path -LiteralPath $expectedPath) -and (Test-ModHashMatches $m $expectedPath)

    if ($existsAsExpected) {
        $rows += [PSCustomObject]@{ kind="pack"; mod=$m; status="일치"; localName=$m.filename; state="match" }
    } elseif (Test-Path -LiteralPath $expectedPath) {
        # Same filename, wrong content: overwrite in place, no separate delete needed.
        $rows += [PSCustomObject]@{ kind="pack"; mod=$m; status="내용 오래됨(자동 교체)"; localName=$m.filename; state="on" }
    } elseif ($prevName -and (Test-Path -LiteralPath (Join-Path (Get-LocalDir $m) $prevName))) {
        # Missing/outdated tracked mod: default to installing it. User double-clicks to exclude.
        $rows += [PSCustomObject]@{ kind="pack"; mod=$m; status="버전 다름"; localName=$prevName; state="on" }
    } else {
        if ($m.optional -and -not $m.default) {
            # Pack-level opt-in mod the maintainer marked off-by-default: respect that, stay off.
            $rows += [PSCustomObject]@{ kind="pack"; mod=$m; status="설치안됨(선택)"; localName="(없음)"; state="off" }
        } else {
            $rows += [PSCustomObject]@{ kind="pack"; mod=$m; status="설치안됨"; localName="(없음)"; state="on" }
        }
    }
}

if (Test-Path -LiteralPath $ModsDir) {
    $localJars = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File
    foreach ($j in $localJars) {
        if ($allExpectedNames.ContainsKey($j.Name)) { continue }
        # Known-stale: either this tool's own manifest previously installed this
        # exact filename (now superseded), or its name-minus-version matches a
        # mod the pack still tracks under a newer filename. Either way it's a
        # leftover old build of a mod we still ship, not a genuine personal mod.
        # Only the exact-filename case is auto-deleted: this tool's own manifest
        # says for certain that filename was a stale version of a pwPath we
        # still track. The stem match (name minus version numbers) is much
        # weaker evidence - short/generic stems can collide between unrelated
        # mods across a few hundred entries - so it's surfaced but left off by
        # default, same as a genuine personal mod, requiring a manual double-click.
        $isCertainStale = $allCachedNames.ContainsKey($j.Name)
        $stemMatches = $expectedStems.ContainsKey((Get-NameStem $j.Name))
        if ($isCertainStale) {
            $rows += [PSCustomObject]@{
                kind="personal"; mod=$null; status="구버전(자동 삭제 예정)"; localName=$j.Name; state="on"
            }
        } elseif ($stemMatches) {
            $rows += [PSCustomObject]@{
                kind="personal"; mod=$null; status="구버전으로 추정(확인 후 삭제)"; localName=$j.Name; state="off"
            }
        } else {
            $rows += [PSCustomObject]@{
                kind="personal"; mod=$null; status="내pc에만 있음"; localName=$j.Name; state="off"
            }
        }
    }
}

$mismatchCount = ($rows | Where-Object { $_.kind -eq "pack" -and $_.state -ne "match" }).Count
$personalCount = ($rows | Where-Object { $_.kind -eq "personal" }).Count
if ($mismatchCount -eq 0 -and $personalCount -eq 0) {
    Write-Host ""
    Write-Host "모든 필수 모드가 저장소 버전과 일치하고, 내pc모드도 없습니다. 할 일이 없습니다."
    exit 0
}

# ---- Build the unified window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = "모드 동기화"
$form.Width = 950
$form.Height = 680
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

$labelHeight = 112
$buttonHeight = 50

$label = New-Object System.Windows.Forms.Label
$label.Text = "초록=이미 설치됨(그대로 둠). 빨강=기본모드 중 미설치 - 서버 접속에 반드시 필요, 기본적으로 자동 설치되며 더블클릭하면 설치에서 제외됩니다.`r`n" +
              "회색=클라이언트 모드 중 미설치 - 없어도 서버 접속엔 문제없는 선택 모드라 기본이 '설치 안 함'이며, 더블클릭하면 반대로 설치가 켜집니다(빨강과 동작이 반대이니 주의).`r`n" +
              "파랑=내pc모드(팩에 없음, 이 PC에만 있는 모드, 기본적으로 그대로 둠, 더블클릭하면 삭제 대상으로 전환). 아래 [구분/설치 여부/동작 여부] 컬럼에서 각 항목의 실제 상태를 확인하세요.`r`n" +
              "[최종 확인]을 눌러야 실제로 적용됩니다. 그 전까지는 아무 파일도 바뀌지 않습니다."
$label.AutoSize = $false
$label.Location = New-Object System.Drawing.Point(10, 10)
$label.Size = New-Object System.Drawing.Size(($form.ClientSize.Width - 20), ($labelHeight - 10))
$label.Anchor = "Top, Left, Right"
$form.Controls.Add($label)

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Location = New-Object System.Drawing.Point(0, ($form.ClientSize.Height - $buttonHeight))
$buttonPanel.Size = New-Object System.Drawing.Size($form.ClientSize.Width, $buttonHeight)
$buttonPanel.Anchor = "Bottom, Left, Right"

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(0, $labelHeight)
$grid.Size = New-Object System.Drawing.Size($form.ClientSize.Width, ($form.ClientSize.Height - $labelHeight - $buttonHeight))
$grid.Anchor = "Top, Bottom, Left, Right"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.SelectionMode = "FullRowSelect"
$grid.MultiSelect = $false
$grid.Columns.Add("category", "구분") | Out-Null
$grid.Columns.Add("installed", "설치 여부") | Out-Null
$grid.Columns.Add("action", "동작 여부") | Out-Null
$grid.Columns.Add("name", "모드명") | Out-Null
$grid.Columns.Add("local", "로컬 파일") | Out-Null
$grid.Columns.Add("expected", "저장소 파일") | Out-Null
# Header-click sorting would silently undo the client-mods-first ordering below, so disable it.
foreach ($col in $grid.Columns) { $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable }

function Get-Category($row) {
    if ($row.kind -eq "personal") { return "내pc모드" }
    if ($row.mod.side -eq "client") { return "클라이언트 모드" }
    return "기본모드"
}

# Sort tier: client pack mods first, then my-PC-only mods, then everything else (기본모드).
function Get-SortTier($row) {
    if ($row.kind -eq "pack" -and $row.mod.side -eq "client") { return 0 }
    if ($row.kind -eq "personal") { return 1 }
    return 2
}

function Get-InstalledText($row) {
    if ($row.kind -eq "personal") { return "설치됨" }
    if ($row.state -eq "match") { return "설치됨" }
    return "설치안됨"
}

function Get-ActionText($row) {
    if ($row.kind -eq "pack") {
        switch ($row.state) {
            "match" { return "-" }
            "on"    { return "설치예정" }
            "off"   { return "제외예정" }
        }
    } else {
        if ($row.state -eq "off") { return "유지" } else { return "삭제예정" }
    }
}

function Get-RowColors($row) {
    if ($row.kind -eq "pack") {
        if ($row.state -eq "match") {
            return @{ back=[System.Drawing.Color]::Honeydew; fore=[System.Drawing.Color]::DarkGreen }
        }
        $isClient = ($row.mod.side -eq "client")
        if ($row.state -eq "on") {
            # Will be installed/re-installed on confirm.
            if ($isClient) { return @{ back=[System.Drawing.Color]::WhiteSmoke; fore=[System.Drawing.Color]::Gray } }
            else { return @{ back=[System.Drawing.Color]::MistyRose; fore=[System.Drawing.Color]::DarkRed } }
        } else {
            # Excluded - will stay missing after confirm.
            if ($isClient) { return @{ back=[System.Drawing.Color]::Gainsboro; fore=[System.Drawing.Color]::DimGray } }
            else { return @{ back=[System.Drawing.Color]::LightCoral; fore=[System.Drawing.Color]::Maroon } }
        }
    } else {
        if ($row.state -eq "off") { return @{ back=[System.Drawing.Color]::AliceBlue; fore=[System.Drawing.Color]::DarkBlue } }
        else { return @{ back=[System.Drawing.Color]::Bisque; fore=[System.Drawing.Color]::DarkOrange } }
    }
}

$sorted = $rows | Sort-Object `
    { Get-SortTier $_ }, `
    { if ($_.state -eq "match") { 1 } else { 0 } }, `
    { $_.kind }
foreach ($r in $sorted) {
    $expected = if ($r.kind -eq "pack") { $r.mod.filename } else { "(팩에 없음)" }
    $name = if ($r.kind -eq "pack") { $r.mod.name } else { $r.localName }
    $colors = Get-RowColors $r
    $rowIdx = $grid.Rows.Add((Get-Category $r), (Get-InstalledText $r), (Get-ActionText $r), $name, $r.localName, $expected)
    $row = $grid.Rows[$rowIdx]
    $row.DefaultCellStyle.BackColor = $colors.back
    $row.DefaultCellStyle.ForeColor = $colors.fore
    $row.Tag = $r
}

$grid.Add_CellDoubleClick({
    param($s, $e)
    if ($e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    $r = $row.Tag
    if ($r.kind -eq "pack" -and $r.state -eq "match") { return } # not toggleable
    if ($r.state -eq "off") { $r.state = "on" } else { $r.state = "off" }
    $colors = Get-RowColors $r
    $row.Cells["action"].Value = Get-ActionText $r
    $row.Cells["installed"].Value = Get-InstalledText $r
    $row.DefaultCellStyle.BackColor = $colors.back
    $row.DefaultCellStyle.ForeColor = $colors.fore
})

$installBtn = New-Object System.Windows.Forms.Button
$installBtn.Text = "최종 확인"
$installBtn.Width = 160
$installBtn.Height = 34
$installBtn.Left = 620
$installBtn.Top = 8
$installBtn.DialogResult = [System.Windows.Forms.DialogResult]::OK
$buttonPanel.Controls.Add($installBtn)

$cancelBtn = New-Object System.Windows.Forms.Button
$cancelBtn.Text = "취소 (아무것도 안 함)"
$cancelBtn.Width = 160
$cancelBtn.Height = 34
$cancelBtn.Left = 450
$cancelBtn.Top = 8
$cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$buttonPanel.Controls.Add($cancelBtn)

$form.Controls.Add($buttonPanel)
$form.Controls.Add($grid)
$form.AcceptButton = $installBtn
$form.CancelButton = $cancelBtn

$result = $form.ShowDialog()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "취소되었습니다. 아무 파일도 변경되지 않았습니다."
    exit 0
}

$toInstall = $rows | Where-Object { $_.kind -eq "pack" -and $_.state -eq "on" }
$toDelete  = $rows | Where-Object { $_.kind -eq "personal" -and $_.state -eq "on" }

if ($toDelete.Count -gt 0) {
    Write-Host ""
    Write-Host "다음 $($toDelete.Count)개 내pc모드가 삭제됩니다:"
    foreach ($d in $toDelete) { Write-Host "  - $($d.localName)" }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "내pc모드 $($toDelete.Count)개를 정말 삭제할까요?`r`n(이 목록에 없는 나머지 내pc모드는 그대로 유지됩니다)",
        "삭제 확인",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
        Write-Host "삭제를 취소했습니다."
        $toDelete = @()
    }
}

Write-Host ""
Write-Host "$($toInstall.Count)개 모드를 설치/업데이트하고, $($toDelete.Count)개 내pc모드를 삭제합니다..."

if (-not (Test-Path -LiteralPath $ModsDir)) { New-Item -ItemType Directory -Path $ModsDir | Out-Null }

$okCount = 0
$failCount = 0

foreach ($r in $toInstall) {
    $m = $r.mod
    $localDir = Get-LocalDir $m
    if (-not (Test-Path -LiteralPath $localDir)) { New-Item -ItemType Directory -Path $localDir | Out-Null }
    Write-Host "  받는 중: $($m.name) ($($m.filename))"
    $target = Join-Path $localDir $m.filename
    # Invoke-WebRequest -OutFile resolves its path through PowerShell's wildcard
    # provider, so a filename containing literal [ ] (several mod jars have this)
    # throws "Unable to find the specified file." even though nothing is actually
    # missing. Download to a bracket-free GUID temp name instead, then move it to
    # the real (bracketed) name with -LiteralPath, which does not wildcard-expand.
    $tmp = Join-Path $localDir ((New-Guid).Guid + ".tmp")
    $ok = $false
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $m.url -OutFile $tmp -MaximumRedirection 5 -TimeoutSec 180
            if ($m.hash -and $m.hashFormat) {
                $algo = if ($m.hashFormat -eq "sha1") { "SHA1" } elseif ($m.hashFormat -eq "sha512") { "SHA512" } else { "SHA256" }
                $actualHash = (Get-FileHash -LiteralPath $tmp -Algorithm $algo).Hash.ToLower()
                if ($actualHash -ne $m.hash.ToLower()) {
                    throw "해시 불일치 (기대: $($m.hash), 실제: $actualHash)"
                }
            }
            $ok = $true
            break
        } catch {
            Write-Host "    시도 $try 실패: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
        }
    }

    if ($ok) {
        if ($r.localName -ne "(없음)" -and $r.localName -ne $m.filename) {
            $oldPath = Join-Path $localDir $r.localName
            if (Test-Path -LiteralPath $oldPath) { Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue }
        }
        Move-Item -LiteralPath $tmp -Destination $target -Force
        $cachedFiles[$m.pwPath] = [PSCustomObject]@{
            hash            = $m.hash
            linkedFileHash  = $null
            cachedLocation  = "$localDir/$($m.filename)"
            isOptional      = $m.optional
            optionValue     = $true
            onlyOtherSide   = $false
        }
        $okCount++
        Write-Host "    완료"
    } else {
        $failCount++
        Write-Host "    [실패] $($m.name) - 나중에 다시 시도해주세요"
    }
}

foreach ($d in $toDelete) {
    $target = Join-Path $ModsDir $d.localName
    try {
        Remove-Item -LiteralPath $target -Force
        Write-Host "  삭제됨: $($d.localName)"
    } catch {
        Write-Host "  [실패] $($d.localName) 삭제 실패 - $($_.Exception.Message)"
    }
}

$newManifest = [PSCustomObject]@{
    packFileHash  = $null
    indexFileHash = $null
    cachedFiles   = $cachedFiles
    cachedSide    = "client"
}
$newManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $ManifestPath -Encoding UTF8

Write-Host ""
Write-Host "======================================================"
Write-Host "  완료: 설치/업데이트 성공 $okCount 개, 실패 $failCount 개, 내pc모드 삭제 $($toDelete.Count) 개"
Write-Host "======================================================"
