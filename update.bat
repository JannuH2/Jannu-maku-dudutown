@echo off
setlocal
cd /d "%~dp0"
title Jannu-maku-dudutown 모드 업데이트

set "PACK_URL=https://jannuh2.github.io/Jannu-maku-dudutown/pack.toml"
set "BOOT_URL=https://github.com/packwiz/packwiz-installer-bootstrap/releases/download/v0.0.3/packwiz-installer-bootstrap.jar"

echo.
echo ==============================================
echo   Jannu-maku-dudutown 모드 업데이트
echo ==============================================
echo.

rem --- 1. CurseForge 프로필 폴더가 맞는지 확인 ---
if not exist "minecraftinstance.json" goto wrongfolder

rem --- 2. Java 찾기 (CurseForge가 설치한 Java 우선, 없으면 시스템 Java) ---
set "JAVA="
if not defined JAVA if exist "%USERPROFILE%\curseforge\minecraft\Install\java\Jre_21\bin\java.exe" set "JAVA=%USERPROFILE%\curseforge\minecraft\Install\java\Jre_21\bin\java.exe"
if not defined JAVA if exist "%USERPROFILE%\curseforge\minecraft\Install\runtime\java-runtime-delta\windows-x64\java-runtime-delta\bin\java.exe" set "JAVA=%USERPROFILE%\curseforge\minecraft\Install\runtime\java-runtime-delta\windows-x64\java-runtime-delta\bin\java.exe"
if not defined JAVA if exist "%USERPROFILE%\curseforge\minecraft\Install\java\java-runtime-delta\bin\java.exe" set "JAVA=%USERPROFILE%\curseforge\minecraft\Install\java\java-runtime-delta\bin\java.exe"
if not defined JAVA if exist "%USERPROFILE%\Documents\curseforge\minecraft\Install\java\Jre_21\bin\java.exe" set "JAVA=%USERPROFILE%\Documents\curseforge\minecraft\Install\java\Jre_21\bin\java.exe"
if not defined JAVA where java >nul 2>nul && set "JAVA=java"
if not defined JAVA goto nojava

rem --- 3. 설치 도구 내려받기 (처음 한 번만) ---
if exist "packwiz-installer-bootstrap.jar" goto run
echo 설치 도구를 내려받는 중입니다...
curl.exe -L -f -s -o "packwiz-installer-bootstrap.jar.tmp" "%BOOT_URL%"
if errorlevel 1 powershell -NoProfile -Command "try { Invoke-WebRequest -UseBasicParsing '%BOOT_URL%' -OutFile 'packwiz-installer-bootstrap.jar.tmp' } catch { exit 1 }"
if not exist "packwiz-installer-bootstrap.jar.tmp" goto downloadfail
move /y "packwiz-installer-bootstrap.jar.tmp" "packwiz-installer-bootstrap.jar" >nul

:run
echo.
echo 모드를 확인하고 업데이트합니다. 잠시 창이 나타납니다.
echo 처음에는 수백 MB를 받아서 5~10분 걸릴 수 있습니다.
echo.
set "TRY=0"

:attempt
set /a TRY+=1
"%JAVA%" -jar packwiz-installer-bootstrap.jar -s client "%PACK_URL%"
if not errorlevel 1 goto success
if %TRY% lss 3 goto retry
goto fail

:retry
echo.
echo 일부 파일을 받지 못해 다시 시도합니다. (%TRY%/3 회 실패, 받은 파일은 건너뜁니다)
echo.
goto attempt

:success
echo.
echo ==============================================
echo   완료되었습니다! CurseForge에서 프로필을 실행하세요.
echo ==============================================
pause
exit /b 0

:wrongfolder
echo [오류] 여기는 CurseForge 프로필 폴더가 아닙니다.
echo.
echo  1. CurseForge 앱에서 프로필의 톱니바퀴 메뉴 - "폴더 열기" 를 누르세요.
echo  2. 열린 폴더에 이 update.bat 파일을 옮긴 뒤 다시 실행하세요.
echo.
pause
exit /b 1

:nojava
echo [오류] Java를 찾을 수 없습니다.
echo.
echo  방법 1: CurseForge에서 이 프로필을 한 번 실행해 보세요. (Java가 자동 설치됩니다)
echo          실행 후 게임을 끄고 이 파일을 다시 실행하세요.
echo  방법 2: https://adoptium.net 에서 Java 21(Temurin)을 설치하세요.
echo.
pause
exit /b 1

:downloadfail
echo [오류] 설치 도구를 내려받지 못했습니다. 인터넷 연결을 확인하고 다시 실행하세요.
echo.
pause
exit /b 1

:fail
echo.
echo [오류] 업데이트에 실패했습니다. 위쪽 메시지를 캡처해서 관리자에게 보내주세요.
echo.
pause
exit /b 1
