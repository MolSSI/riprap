@echo off
setlocal EnableDelayedExpansion

echo Note: If you are running inside WSL, use "bash rr.sh" instead.
echo.

if "%~1"=="--reset-agent-state" (
    if "%~3"=="--yes" (
        powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\credential-state.ps1 -Action Reset -Agent "%~2" -Confirmation "--yes"
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\credential-state.ps1 -Action Reset -Agent "%~2"
    )
    exit /b !ERRORLEVEL!
)
if "%~1"=="--install-git-hooks" (
    powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\credential-state.ps1 -Action InstallHooks
    exit /b !ERRORLEVEL!
)

for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\credential-state.ps1 -Action Ensure`) do set PROJECT_ID=%%i
REM FOR /F does not reliably propagate the child command's exit status. Ensure emits an ID
REM only after validating state, so an empty result is the unambiguous failure signal.
if not defined PROJECT_ID exit /b 1

set /p IMAGE=<.riprap\managed\podman\image_name

REM Validate the complete pin and write transient candidate state before Podman runs.
powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\agent-build.ps1 prepare
if errorlevel 1 exit /b %ERRORLEVEL%

REM Tooling failures are never treated as refresh failures.
call podman build -t riprap-tooling:latest .riprap\managed\podman
if errorlevel 1 (
    powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\agent-build.ps1 discard
    echo Riprap: tooling image build failed. 1>&2
    exit /b 1
)
for /f "usebackq delims=" %%i in (`podman image inspect --format "{{.Id}}" riprap-tooling:latest`) do set TOOLING_ID=%%i

call podman build -f .riprap\managed\podman\Agent.Containerfile -t riprap-agent:candidate .riprap\managed\podman
if errorlevel 1 goto agent_refresh_failed
set "CLAUDE_VERSION="
set "CODEX_VERSION="
for /f "tokens=1" %%i in ('podman run --rm riprap-agent:candidate claude --version') do set CLAUDE_VERSION=%%i
for /f "tokens=2" %%i in ('podman run --rm riprap-agent:candidate codex --version') do set CODEX_VERSION=%%i
set "RIPRAP_VERSION_TO_CHECK=!CLAUDE_VERSION!"
powershell -NoProfile -Command "if ($env:RIPRAP_VERSION_TO_CHECK -notmatch '\d+\.\d+\.\d+') { exit 1 }"
if errorlevel 1 goto agent_refresh_failed
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "[regex]::Match($env:RIPRAP_VERSION_TO_CHECK, '\d+\.\d+\.\d+').Value"`) do set CLAUDE_VERSION=%%i
set "RIPRAP_VERSION_TO_CHECK=!CODEX_VERSION!"
powershell -NoProfile -Command "if ($env:RIPRAP_VERSION_TO_CHECK -notmatch '\d+\.\d+\.\d+') { exit 1 }"
if errorlevel 1 goto agent_refresh_failed
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "[regex]::Match($env:RIPRAP_VERSION_TO_CHECK, '\d+\.\d+\.\d+').Value"`) do set CODEX_VERSION=%%i
set "RIPRAP_VERSION_TO_CHECK="
call podman build -f .riprap\managed\podman\AgentLabels.Containerfile --build-arg CLAUDE_VERSION=!CLAUDE_VERSION! --build-arg CODEX_VERSION=!CODEX_VERSION! --build-arg TOOLING_IMAGE_ID=!TOOLING_ID! -t riprap-agent:latest .riprap\managed\podman
if errorlevel 1 goto agent_refresh_failed
powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\agent-build.ps1 promote !CLAUDE_VERSION! !CODEX_VERSION!
if errorlevel 1 exit /b %ERRORLEVEL%
goto agent_refresh_done

:agent_refresh_failed
call podman image exists riprap-agent:latest
if errorlevel 1 goto no_compatible_agent
for /f "usebackq delims=" %%i in (`podman image inspect --format "{{ index .Labels \"io.riprap.tooling-image-id\" }}" riprap-agent:latest`) do set AGENT_TOOLING_ID=%%i
if not "!AGENT_TOOLING_ID!"=="!TOOLING_ID!" goto no_compatible_agent
powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\agent-build.ps1 discard
echo Riprap: agent refresh failed; continuing with the compatible existing agent image. 1>&2
goto agent_refresh_done

:no_compatible_agent
powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\agent-build.ps1 discard
echo Riprap: agent refresh failed and no compatible agent image exists. 1>&2
exit /b 1

:agent_refresh_done

call podman build -t %IMAGE% .

powershell -NoProfile -ExecutionPolicy Bypass -File .riprap\managed\launch\interface.ps1 -Image %IMAGE% -ProjectId %PROJECT_ID%

pause
