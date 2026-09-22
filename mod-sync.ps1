param(
    [string]$PackUrl = "https://jannuh2.github.io/Jannu-maku-dudutown/pack.toml",
    [string]$ManifestPath = "packwiz.json",
    [string]$ModsDir = "mods"
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
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

# Parse index.toml into a list of {file, metafile}
$entries = @()
$blocks = $indexText -split '\[\[files\]\]'
foreach ($b in $blocks) {
    $f = Get-TomlValue $b "file"
    if (-not $f) { continue }
    if (-not $f.StartsWith("mods/")) { continue }
    $isMeta = $b -match '(?m)^metafile\s*=\s*true\s*$'
    $entryHash = Get-TomlValue $b "hash"
    $entries += [PSCustomObject]@{ file = $f; metafile = $isMeta; hash = $entryHash }
}

Write-Host "$($entries.Count)개 항목을 찾았습니다. 각 모드 정보를 불러오는 중..."

# Load existing manifest (previous install state)
$cachedFiles = @{}
$manifest = $null
if (Test-Path -LiteralPath $ManifestPath) {
    try {
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        if ($manifest.cachedFiles) {
            foreach ($prop in $manifest.cachedFiles.PSObject.Properties) {
                $cachedFiles[$prop.Name] = $prop.Value
            }
        }
    } catch { $manifest = $null }
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
        $mode = Get-TomlValue $pwText "mode"
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
        # direct binary entry (jar committed straight into the repo)
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

# Only client-relevant mods
$mods = $mods | Where-Object { $_.side -eq "both" -or $_.side -eq "client" }

# Compute status vs local mods folder / manifest
foreach ($m in $mods) {
    $prevLoc = $null
    if ($cachedFiles.ContainsKey($m.pwPath)) {
        $prevLoc = $cachedFiles[$m.pwPath].cachedLocation
    }
    $prevName = if ($prevLoc) { Split-Path $prevLoc -Leaf } else { $null }
    $existsAsExpected = Test-Path -LiteralPath (Join-Path $ModsDir $m.filename)

    if ($existsAsExpected) {
        $m | Add-Member -NotePropertyName status -NotePropertyValue "일치" -Force
        $m | Add-Member -NotePropertyName localName -NotePropertyValue $m.filename -Force
        $m | Add-Member -NotePropertyName needsAction -NotePropertyValue $false -Force
    } elseif ($prevName) {
        $m | Add-Member -NotePropertyName status -NotePropertyValue "버전 다름" -Force
        $m | Add-Member -NotePropertyName localName -NotePropertyValue $prevName -Force
        $m | Add-Member -NotePropertyName needsAction -NotePropertyValue $true -Force
    } else {
        if ($m.optional -and -not $m.default) {
            # never opted in - leave alone, don't show as an error
            $m | Add-Member -NotePropertyName status -NotePropertyValue "미설치(선택)" -Force
            $m | Add-Member -NotePropertyName localName -NotePropertyValue "(없음)" -Force
            $m | Add-Member -NotePropertyName needsAction -NotePropertyValue $false -Force
        } else {
            $m | Add-Member -NotePropertyName status -NotePropertyValue "없음" -Force
            $m | Add-Member -NotePropertyName localName -NotePropertyValue "(없음)" -Force
            $m | Add-Member -NotePropertyName needsAction -NotePropertyValue $true -Force
        }
    }
}

$actionable = $mods | Where-Object { $_.needsAction }

if ($actionable.Count -eq 0) {
    Write-Host ""
    Write-Host "모든 필수 모드가 저장소 버전과 일치합니다. 업데이트할 항목이 없습니다."
    exit 0
}

# ---- Build the colored diff window ----
$form = New-Object System.Windows.Forms.Form
$form.Text = "모드 동기화 - 일치(초록) / 불일치(빨강) 확인"
$form.Width = 900
$form.Height = 650
$form.StartPosition = "CenterScreen"
$form.TopMost = $true

$label = New-Object System.Windows.Forms.Label
$label.Text = "저장소 기준으로 로컬 모드 상태를 비교했습니다. 초록색은 이미 일치, 빨간색은 저장소와 다르거나 없는 모드입니다.`r`n아래 [설치 진행] 버튼을 눌러야 실제로 파일이 변경됩니다. 누르기 전까지는 아무것도 바뀌지 않습니다."
$label.Dock = "Top"
$label.Height = 50
$label.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 0)
$form.Controls.Add($label)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.SelectionMode = "FullRowSelect"
$grid.Columns.Add("status", "상태") | Out-Null
$grid.Columns.Add("name", "모드명") | Out-Null
$grid.Columns.Add("local", "로컬 버전") | Out-Null
$grid.Columns.Add("expected", "저장소 버전") | Out-Null

foreach ($m in ($mods | Sort-Object { $_.needsAction } -Descending)) {
    $rowIdx = $grid.Rows.Add($m.status, $m.name, $m.localName, $m.filename)
    $row = $grid.Rows[$rowIdx]
    if ($m.needsAction) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkRed
    } else {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Honeydew
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkGreen
    }
}
$form.Controls.Add($grid)

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Dock = "Bottom"
$buttonPanel.Height = 50

$installBtn = New-Object System.Windows.Forms.Button
$installBtn.Text = "설치 진행 ($($actionable.Count)개)"
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
$form.AcceptButton = $installBtn
$form.CancelButton = $cancelBtn

$result = $form.ShowDialog()

if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
    Write-Host "설치가 취소되었습니다. 아무 파일도 변경되지 않았습니다."
    exit 0
}

Write-Host ""
Write-Host "$($actionable.Count)개 모드를 설치/업데이트합니다..."

if (-not (Test-Path -LiteralPath $ModsDir)) { New-Item -ItemType Directory -Path $ModsDir | Out-Null }

$okCount = 0
$failCount = 0

foreach ($m in $actionable) {
    Write-Host "  받는 중: $($m.name) ($($m.filename))"
    $target = Join-Path $ModsDir $m.filename
    $tmp = "$target.tmp"
    $ok = $false
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $m.url -OutFile $tmp -MaximumRedirection 5
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
        if ($m.localName -ne "(없음)" -and $m.localName -ne $m.filename) {
            $oldPath = Join-Path $ModsDir $m.localName
            if (Test-Path -LiteralPath $oldPath) { Remove-Item -LiteralPath $oldPath -Force -ErrorAction SilentlyContinue }
        }
        Move-Item -LiteralPath $tmp -Destination $target -Force
        $cachedFiles[$m.pwPath] = [PSCustomObject]@{
            hash            = $m.hash
            linkedFileHash  = $null
            cachedLocation  = "$ModsDir/$($m.filename)"
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

$newManifest = [PSCustomObject]@{
    packFileHash  = $null
    indexFileHash = $null
    cachedFiles   = $cachedFiles
    cachedSide    = "client"
}
$newManifest | ConvertTo-Json -Depth 6 | Set-Content -Path $ManifestPath -Encoding UTF8

Write-Host ""
Write-Host "======================================================"
Write-Host "  완료: 성공 $okCount 개, 실패 $failCount 개"
Write-Host "======================================================"
