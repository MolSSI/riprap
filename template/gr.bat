@echo off
setlocal EnableDelayedExpansion

echo Note: If you are running inside WSL, use "bash gr.sh" instead.
echo.

if "%~1"=="--reset-agent-state" (
    if "%~3"=="--yes" (
        powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\credential-state.ps1 -Action Reset -Agent "%~2" -Confirmation "--yes"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\credential-state.ps1 -Action Reset -Agent "%~2"
    )
    exit /b !ERRORLEVEL!
)
if "%~1"=="--install-git-hooks" (
    powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\credential-state.ps1 -Action InstallHooks
    exit /b !ERRORLEVEL!
)

for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\credential-state.ps1 -Action Ensure`) do set PROJECT_ID=%%i
if errorlevel 1 exit /b %ERRORLEVEL%

set /p IMAGE=<.guardrails\podman\image_name

podman build -t guardrails-base:latest .guardrails\podman
podman build -t %IMAGE% .

powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\interface.ps1 -Image %IMAGE% -ProjectId %PROJECT_ID%

pause
