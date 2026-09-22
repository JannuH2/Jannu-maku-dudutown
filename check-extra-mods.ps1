param(
    [string]$ManifestPath = "packwiz.json",
    [string]$ModsDir = "mods"
)

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[정보] packwiz.json을 찾을 수 없어 개인 설치 모드 검사를 건너뜁니다."
    exit 0
}

try {
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "[경고] packwiz.json을 읽는 중 오류가 발생해 개인 설치 모드 검사를 건너뜁니다."
    exit 0
}

$knownNames = @{}
if ($manifest.cachedFiles) {
    foreach ($prop in $manifest.cachedFiles.PSObject.Properties) {
        $path = $prop.Name
        if ($path -like "mods/*" -or $path -like "mods\*") {
            $name = Split-Path $path -Leaf
            $knownNames[$name] = $true
        }
    }
}

if (-not (Test-Path $ModsDir)) {
    exit 0
}

$localJars = Get-ChildItem -Path $ModsDir -Filter "*.jar" -File |
    Where-Object { -not $knownNames.ContainsKey($_.Name) }

if (-not $localJars -or $localJars.Count -eq 0) {
    Write-Host "[정보] 개인적으로 추가하신 모드는 없습니다. 모드팩 구성 그대로입니다."
    exit 0
}

Write-Host ""
Write-Host "======================================================"
Write-Host "  개인적으로 설치하신 모드 $($localJars.Count)개를 발견했습니다"
Write-Host "======================================================"
Write-Host ""
Write-Host "아래 모드들은 이 모드팩(update.bat)이 관리하는 목록에 없습니다."
Write-Host "즉, 회원님이 직접 CurseForge 등에서 따로 추가하신 모드일 가능성이 높습니다."
Write-Host ""
Write-Host "  * 방금 모드팩 업데이트는 이 모드들을 전혀 건드리지 않았습니다."
Write-Host "  * 아무것도 선택하지 않고 확인만 누르면 전부 그대로 유지됩니다 (기본값: 보존)."
Write-Host "  * 잠시 후 뜨는 창에서, 정말 지우고 싶은 모드만 체크하고 확인을 누르세요."
Write-Host ""

$rows = $localJars | Select-Object Name,
    @{Name='크기(KB)'; Expression = { [math]::Round($_.Length / 1KB) } },
    LastWriteTime

$selected = $rows | Out-GridView `
    -Title "개인 설치 모드 목록 - 지울 항목만 체크하세요 (아무것도 체크 안 하면 전부 유지)" `
    -OutputMode Multiple

if ($selected) {
    Write-Host ""
    Write-Host "체크하신 $($selected.Count)개 모드를 삭제합니다:"
    foreach ($item in $selected) {
        $target = Join-Path $ModsDir $item.Name
        try {
            Remove-Item -LiteralPath $target -Force
            Write-Host "  삭제됨: $($item.Name)"
        } catch {
            Write-Host "  삭제 실패: $($item.Name) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "선택한 항목이 없어 모든 개인 설치 모드를 그대로 두었습니다."
}
