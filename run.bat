@echo off

echo Note: If you are running inside WSL, use "bash run.sh" instead.
echo.

set /p IMAGE=<.guardrails\podman\image_name

podman build -t guardrails-base:latest .guardrails\podman
podman build -t %IMAGE% .

powershell -ExecutionPolicy Bypass -File .guardrails\interface.ps1 -Image %IMAGE%

pause
