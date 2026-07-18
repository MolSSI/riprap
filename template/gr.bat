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

REM Validate the complete pin and write transient candidate state before Podman runs.
powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\agent-build.ps1 prepare
if errorlevel 1 exit /b %ERRORLEVEL%

REM Tooling failures are never treated as refresh failures.
podman build -t guardrails-tooling:latest .guardrails\podman
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\agent-build.ps1 discard
    echo Guardrails: tooling image build failed. 1>&2
    exit /b 1
)
for /f "usebackq delims=" %%i in (`podman image inspect --format "{{.Id}}" guardrails-tooling:latest`) do set TOOLING_ID=%%i

podman build -f .guardrails\podman\Agent.Containerfile -t guardrails-agent:candidate .guardrails\podman
if errorlevel 1 goto agent_refresh_failed
set "CLAUDE_VERSION="
set "CODEX_VERSION="
for /f "tokens=1" %%i in ('podman run --rm guardrails-agent:candidate claude --version') do set CLAUDE_VERSION=%%i
for /f "tokens=2" %%i in ('podman run --rm guardrails-agent:candidate codex --version') do set CODEX_VERSION=%%i
set "GUARDRAILS_VERSION_TO_CHECK=!CLAUDE_VERSION!"
powershell -NoProfile -Command "if ($env:GUARDRAILS_VERSION_TO_CHECK -notmatch '^\d+\.\d+\.\d+$') { exit 1 }"
if errorlevel 1 goto agent_refresh_failed
set "GUARDRAILS_VERSION_TO_CHECK=!CODEX_VERSION!"
powershell -NoProfile -Command "if ($env:GUARDRAILS_VERSION_TO_CHECK -notmatch '^\d+\.\d+\.\d+$') { exit 1 }"
if errorlevel 1 goto agent_refresh_failed
set "GUARDRAILS_VERSION_TO_CHECK="
podman build -f .guardrails\podman\AgentLabels.Containerfile --build-arg CLAUDE_VERSION=!CLAUDE_VERSION! --build-arg CODEX_VERSION=!CODEX_VERSION! --build-arg TOOLING_IMAGE_ID=!TOOLING_ID! -t guardrails-agent:latest .guardrails\podman
if errorlevel 1 goto agent_refresh_failed
powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\agent-build.ps1 promote !CLAUDE_VERSION! !CODEX_VERSION!
if errorlevel 1 exit /b %ERRORLEVEL%
goto agent_refresh_done

:agent_refresh_failed
podman image exists guardrails-agent:latest
if errorlevel 1 goto no_compatible_agent
for /f "usebackq delims=" %%i in (`podman image inspect --format "{{ index .Labels \"io.guardrails.tooling-image-id\" }}" guardrails-agent:latest`) do set AGENT_TOOLING_ID=%%i
if not "!AGENT_TOOLING_ID!"=="!TOOLING_ID!" goto no_compatible_agent
powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\agent-build.ps1 discard
echo Guardrails: agent refresh failed; continuing with the compatible existing agent image. 1>&2
goto agent_refresh_done

:no_compatible_agent
powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\agent-build.ps1 discard
echo Guardrails: agent refresh failed and no compatible agent image exists. 1>&2
exit /b 1

:agent_refresh_done

podman build -t %IMAGE% .

powershell -NoProfile -ExecutionPolicy Bypass -File .guardrails\interface.ps1 -Image %IMAGE% -ProjectId %PROJECT_ID%

pause
