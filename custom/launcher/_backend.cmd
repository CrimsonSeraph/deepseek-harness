@echo off
setlocal EnableExtensions
title DeepSeek Harness backend

rem ============================================================
rem  后端启动步骤：拉取 -> 安装依赖 -> 构建 -> 安装 git hooks -> 启动 Web
rem  由 start-dsh.bat 在独立窗口中调用；支持 DSH_NO_PULL / DSH_NO_INSTALL /
rem  DSH_NO_BUILD / DSH_DRY_RUN 环境变量（见 README.md）
rem ============================================================

for %%I in ("%~dp0..\..") do set "APP_DIR=%%~fI"
if defined DSH_APP_DIR set "APP_DIR=%DSH_APP_DIR%"

if not exist "%APP_DIR%\package.json" (
  echo [ERROR] 未找到仓库根目录: "%APP_DIR%"
  echo         请确认本脚本位于仓库的 custom\launcher\ 目录内。
  exit /b 1
)
cd /d "%APP_DIR%"

if defined DSH_DRY_RUN (
  echo [DRY RUN] 以下步骤将被执行（不会真正运行）:
  echo   - git pull --ff-only
  echo   - pnpm install --ignore-scripts
  echo   - pnpm run build
  echo   - npx lefthook install（仅当 .git\hooks 未安装时）
  echo   - pnpm dsh web
  echo [DRY RUN] 完毕。本窗口由 cmd /k 保持打开，可直接关闭。
  exit /b 0
)

rem [1/4] 拉取最新代码（可选跳过）
if defined DSH_NO_PULL (
  echo [SKIP] DSH_NO_PULL 已设置，跳过 git pull。
) else (
  git rev-parse --is-inside-work-tree >nul 2>nul
  if errorlevel 1 (
    echo [WARN] 当前目录不是 git 仓库，跳过 git pull。
  ) else (
    echo [1/4] 拉取最新代码...
    git pull --ff-only
    if errorlevel 1 echo [WARN] git pull 失败，使用现有代码继续。
  )
)

rem [2/4] 安装依赖
if defined DSH_NO_INSTALL (
  echo [SKIP] DSH_NO_INSTALL 已设置，跳过依赖安装。
) else (
  echo [2/4] 安装依赖 (pnpm install --ignore-scripts)...
  call pnpm install --ignore-scripts
  if errorlevel 1 (
    echo [ERROR] 依赖安装失败，请检查网络或 pnpm 配置。请查看上方日志。
    exit /b 1
  )
)

rem [3/4] 构建
if defined DSH_NO_BUILD (
  echo [SKIP] DSH_NO_BUILD 已设置，跳过构建。
) else (
  echo [3/4] 构建 (pnpm run build)...
  call pnpm run build
  if errorlevel 1 (
    echo [ERROR] 构建失败，请查看上方日志。
    exit /b 1
  )
)

rem [hook] 安装 git hooks（仅当未安装时）
if not exist "%APP_DIR%\.git\hooks\pre-commit" (
  echo [hook] 安装 git hooks (npx lefthook install)...
  call npx lefthook install
) else (
  echo [hook] git hooks 已安装，跳过。
)

rem [4/4] 启动 Web 服务
echo [4/4] 启动 Web 服务: pnpm dsh web ^(按 Ctrl+C 可停止，关闭本窗口即停止服务^)
call pnpm dsh web
