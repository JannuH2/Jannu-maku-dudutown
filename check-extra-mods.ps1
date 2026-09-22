param(
    [string]$ManifestPath = "packwiz.json",
    [string]$ModsDir = "mods"
)

if (-not (Test-Path $ManifestPath)) {
    Write-Host "[정보] packwiz.json을 찾을 수 없어 추가 모드 검사를 건너뜁니다."
    exit 0
}

try {
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
} catch {
    Write-Host "[경고] packwiz.json을 읽는 중 오류가 발생해 추가 모드 검사를 건너뜁니다."
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
    Write-Host "[정보] 모드팩에 없는 모드는 발견되지 않았습니다."
    exit 0
}

Write-Host ""
Write-Host "[알림] 모드팩에 포함되지 않은 모드 $($localJars.Count)개를 발견했습니다."
Write-Host "       잠시 후 뜨는 창에서 삭제할 항목을 체크하고 확인을 누르세요."
Write-Host "       (아무것도 체크 안 하고 확인을 누르면 전부 그대로 둡니다)"

$rows = $localJars | Select-Object Name,
    @{Name='크기(KB)'; Expression = { [math]::Round($_.Length / 1KB) } },
    LastWriteTime

$selected = $rows | Out-GridView -Title "모드팩에 없는 모드 - 삭제할 항목을 체크 후 확인을 누르세요" -OutputMode Multiple

if ($selected) {
    foreach ($item in $selected) {
        $target = Join-Path $ModsDir $item.Name
        try {
            Remove-Item -LiteralPath $target -Force
            Write-Host "삭제됨: $($item.Name)"
        } catch {
            Write-Host "삭제 실패: $($item.Name) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "선택된 항목이 없어 아무것도 삭제하지 않았습니다."
}
