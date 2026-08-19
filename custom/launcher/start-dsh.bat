@echo off
setlocal EnableExtensions
title DeepSeek Harness Launcher

rem ============================================================
rem  DeepSeek Harness 启动器（本地扩展，位于 custom/launcher/）
rem  行为可通过环境变量覆盖，详见 README.md
rem ============================================================

rem ---- 端口（可用 DSH_PORT 覆盖，默认 3080）----
set "PORT=%DSH_PORT%"
if not defined PORT set "PORT=3080"
set "URL=http://127.0.0.1:%PORT%"

rem ---- 仓库根目录：本脚本位于 <仓库>/custom/launcher/，上两级即仓库根 ----
for %%I in ("%~dp0..\..") do set "APP_DIR=%%~fI"
if defined DSH_APP_DIR set "APP_DIR=%DSH_APP_DIR%"

rem ---- 启动等待页（与本脚本同目录）----
set "LAUNCHER_HTML=%~dp0launcher.html"

if not exist "%APP_DIR%\package.json" (
  echo [ERROR] 未找到仓库根目录: "%APP_DIR%"
  echo         请把 start-dsh.bat 及配套文件放在仓库的 custom\launcher\ 目录下，
  echo         或通过 DSH_APP_DIR 环境变量指定仓库路径。
  echo         当前脚本位置: %~dp0
  exit /b 1
)

rem ---- 环境检测：node 与 pnpm ----
where node >nul 2>nul
if errorlevel 1 (
  echo [ERROR] 未找到 node。请安装 Node.js ^22.19 或 ^24 后重试: https://nodejs.org
  exit /b 1
)
where pnpm >nul 2>nul
if errorlevel 1 (
  echo [ERROR] 未找到 pnpm。可通过 corepack 启用: corepack enable pnpm
  exit /b 1
)

rem ---- 端口检测：服务已在运行则直接打开应用，避免重复启动后端 ----
set "IS_RUNNING=0"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%PS%" (
  "%PS%" -NoProfile -NonInteractive -Command "if (Get-NetTCPConnection -State Listen -LocalPort %PORT% -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >nul 2>nul
  if not errorlevel 1 set "IS_RUNNING=1"
)
if "%IS_RUNNING%"=="0" (
  netstat -ano | findstr /c:":%PORT% " | findstr /c:"LISTENING" >nul 2>nul
  if not errorlevel 1 set "IS_RUNNING=1"
)

if "%IS_RUNNING%"=="1" (
  echo 服务已在 %URL% 运行，直接打开应用...
  goto open_app
)

echo 服务未运行，正在独立窗口中启动后端（拉取/安装/构建/启动，详见 _backend.cmd）...
start "DeepSeek Harness backend" /d "%APP_DIR%" cmd /k ""%~dp0_backend.cmd""

if defined DSH_NO_BROWSER exit /b 0
if exist "%LAUNCHER_HTML%" (
  call :open_browser "file:///%LAUNCHER_HTML:\=/%"
) else (
  call :open_browser "%URL%"
)
exit /b 0

:open_app
if defined DSH_NO_BROWSER exit /b 0
call :open_browser "%URL%"
exit /b 0

rem ---- 打开浏览器：优先 Edge --app，其次 Chrome --app，最后系统默认浏览器 ----
:open_browser
set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if exist "%EDGE%" (
  start "" "%EDGE%" --app="%1"
  exit /b 0
)
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if exist "%CHROME%" (
  start "" "%CHROME%" --app="%1"
  exit /b 0
)
start "" "%1"
exit /b 0
