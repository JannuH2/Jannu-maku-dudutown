param(
    [string]$ManifestPath = "packwiz.json",
    [string]$ModsDir = "mods"
)

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host "[정보] packwiz.json을 찾을 수 없어 개인 설치 모드 검사를 건너뜁니다."
    exit 0
}

try {
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
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

if (-not (Test-Path -LiteralPath $ModsDir)) {
    exit 0
}

$localJars = Get-ChildItem -LiteralPath $ModsDir -Filter "*.jar" -File |
    Where-Object { -not $knownNames.ContainsKey($_.Name) }

if (-not $localJars -or $localJars.Count -eq 0) {
    Write-Host "[정보] 저장소와 일치하지 않는 클라이언트 전용 모드는 없습니다."
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms

Write-Host ""
Write-Host "======================================================"
Write-Host "  저장소와 일치하지 않는 클라이언트 전용 모드를 찾았습니다"
Write-Host "======================================================"
Write-Host "잠시 후 뜨는 창에서 남기고 싶은 모드를 체크해주세요."
Write-Host "체크하지 않은 모드는 삭제됩니다. (체크한 것만 남습니다)"
Write-Host ""

$rows = $localJars | Select-Object Name,
    @{Name='크기(KB)'; Expression = { [math]::Round($_.Length / 1KB) } },
    LastWriteTime

$selected = $rows | Out-GridView `
    -Title "남기고 싶은 모드를 체크해주세요 (체크 안 한 모드는 삭제됩니다)" `
    -OutputMode Multiple

$selectedNames = @()
if ($selected) { $selectedNames = $selected | ForEach-Object { $_.Name } }
$toDelete = $localJars | Where-Object { $selectedNames -notcontains $_.Name }

if (-not $toDelete -or $toDelete.Count -eq 0) {
    Write-Host "전부 체크하셨습니다. 아무것도 삭제하지 않았습니다."
    exit 0
}

Write-Host ""
Write-Host "다음 $($toDelete.Count)개 모드가 삭제될 예정입니다 (체크하지 않으신 것들):"
foreach ($f in $toDelete) { Write-Host "  - $($f.Name)" }
Write-Host ""

$confirmResult = [System.Windows.Forms.MessageBox]::Show(
    "위 $($toDelete.Count)개 모드를 정말 삭제할까요?`r`n(체크한 모드는 그대로 유지됩니다)",
    "삭제 확인",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)

if ($confirmResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    foreach ($item in $toDelete) {
        try {
            Remove-Item -LiteralPath $item.FullName -Force
            Write-Host "삭제됨: $($item.Name)"
        } catch {
            Write-Host "삭제 실패: $($item.Name) - $($_.Exception.Message)"
        }
    }
} else {
    Write-Host "취소하셨습니다. 아무것도 삭제하지 않았습니다."
}
