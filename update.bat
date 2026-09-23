@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title Jannu-maku-dudutown 모드팩 업데이트

set "PACK_URL=https://jannuh2.github.io/Jannu-maku-dudutown/pack.toml"
set "SYNC_URL=https://raw.githubusercontent.com/JannuH2/Jannu-maku-dudutown/main/mod-sync.ps1"

echo.
echo ==============================================
echo   Jannu-maku-dudutown 모드팩 업데이트
echo ==============================================
echo.

rem --- 1. CurseForge 인스턴스 폴더가 맞는지 확인 ---
if not exist "minecraftinstance.json" goto wrongfolder

rem --- 2. 모드 동기화 스크립트 받아오기 ---
if exist "mod-sync.ps1" del /q "mod-sync.ps1"
set "DL=0"

:download
set /a DL+=1
if exist "mod-sync.ps1.tmp" del /q "mod-sync.ps1.tmp"
curl.exe -L -f -s -o "mod-sync.ps1.tmp" "%SYNC_URL%"
if not errorlevel 1 goto dlok
powershell -NoProfile -Command "try { Invoke-WebRequest -UseBasicParsing '%SYNC_URL%' -OutFile 'mod-sync.ps1.tmp' } catch { exit 1 }"
if not errorlevel 1 goto dlok
if %DL% lss 3 goto dlretry
goto downloadfail

:dlretry
echo 다운로드에 문제가 있어 잠시 후 다시 시도합니다. (%DL%/3 회 시도)
ping -n 4 127.0.0.1 >nul
goto download

:dlok
if not exist "mod-sync.ps1.tmp" goto downloadfail
move /y "mod-sync.ps1.tmp" "mod-sync.ps1" >nul

:run
echo.
echo 저장소와 비교하는 중입니다. 잠시 후 비교 화면(초록=일치, 빨강/회색=미설치)이 뜹니다.
echo 미설치 항목은 기본적으로 자동 설치되며, 그 창에서 [최종 확인]을 눌러야만 실제로 파일이 바뀝니다.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "mod-sync.ps1" -PackUrl "%PACK_URL%"
if errorlevel 1 goto fail

:success
echo.
echo ==============================================
echo   완료되었습니다! CurseForge에서 게임으로 들어가세요.
echo ==============================================
pause
exit /b 0

:wrongfolder
echo [오류] 여기는 CurseForge 인스턴스 폴더가 아닙니다.
echo.
echo  1. CurseForge 앱에서 인스턴스의 우측 메뉴 - "폴더 열기" 를 눌러주세요.
echo  2. 열린 폴더에 이 update.bat 파일을 옮겨 둔 뒤 다시 실행하세요.
echo.
pause
exit /b 1

:downloadfail
echo [오류] 동기화 스크립트를 받아오지 못했습니다. 인터넷 연결을 확인하고 다시 실행하세요.
echo.
pause
exit /b 1

:fail
echo.
echo [오류] 업데이트가 실패했습니다. 위 메시지를 캡처해서 관리자에게 보내주세요.
echo.
pause
exit /b 1
