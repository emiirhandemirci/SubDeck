: << 'CMDBLOCK'
@echo off
REM Polyglot launcher: valid as a batch file (Windows) and as a shell script (POSIX).
REM Usage: run-hook.cmd <script-name-without-.sh> [args...]
REM The script name has no extension on purpose: the host may prepend "bash"
REM to any command line containing ".sh"; the .sh suffix is added here.

if "%~1"=="" exit /b 0
set "HOOK_DIR=%~dp0"

if exist "C:\Program Files\Git\bin\bash.exe" (
    "C:\Program Files\Git\bin\bash.exe" "%HOOK_DIR%%~1.sh" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b 0
)
if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    "C:\Program Files (x86)\Git\bin\bash.exe" "%HOOK_DIR%%~1.sh" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b 0
)
where bash >nul 2>nul
if %ERRORLEVEL% equ 0 (
    bash "%HOOK_DIR%%~1.sh" %2 %3 %4 %5 %6 %7 %8 %9
    exit /b 0
)
REM No bash found: exit silently, never break the session.
exit /b 0
CMDBLOCK

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="$1"
[ -n "$NAME" ] || exit 0
shift
exec bash "${SCRIPT_DIR}/${NAME}.sh" "$@"
