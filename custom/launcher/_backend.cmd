@echo off
setlocal EnableExtensions
title DeepSeek Harness backend

rem ============================================================
rem  后端启动步骤：拉取 -> 安装依赖 -> 构建 -> 安装 git hooks -> 启动 Web
rem  由 start-dsh.bat 在独立窗口中调用；支持 DSH_NO_PULL / DSH_NO_INSTALL /
rem  DSH_NO_BUILD / DSH_DRY_RUN / DSH_PULL_BRANCH / DSH_PULL_FORCE 环境变量（见 README.md）
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
  echo   - git fetch --depth=1 origin master + git reset --hard FETCH_HEAD（浅拉取，仅保留最新提交）
  echo   - pnpm install --ignore-scripts
  echo   - pnpm run build
  echo   - npx lefthook install（仅当 .git\hooks 未安装时）
  echo   - pnpm dsh web --no-open
  echo [DRY RUN] 完毕。本窗口由 cmd /k 保持打开，可直接关闭。
  exit /b 0
)

rem [1/4] 拉取最新代码（浅拉取：只取最新提交，本地仅保留最新一次提交）
set "PULL_BRANCH=master"
if defined DSH_PULL_BRANCH set "PULL_BRANCH=%DSH_PULL_BRANCH%"
if defined DSH_NO_PULL (
  echo [SKIP] DSH_NO_PULL 已设置，跳过 git 更新。
  goto :pull_done
)
git rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
  echo [WARN] 当前目录不是 git 仓库，跳过更新。
  goto :pull_done
)
git diff --quiet HEAD
if errorlevel 1 (
  echo [WARN] 工作区存在未提交修改，为防丢失已跳过更新（请先提交或还原）。
  goto :pull_done
)
for /f %%C in ('git rev-parse origin/%PULL_BRANCH% 2^>nul') do set "OLD_TIP=%%C"
if not defined OLD_TIP (
  echo [WARN] 无法读取远端 %PULL_BRANCH% 状态，跳过更新。
  goto :pull_done
)
echo [1/4] 拉取最新代码（git fetch --depth=1，本地仅保留最新提交）...
git fetch --depth=1 origin %PULL_BRANCH%
if errorlevel 1 (
  echo [WARN] git fetch 失败，使用现有代码继续。
  goto :pull_done
)
for /f %%C in ('git rev-parse origin/%PULL_BRANCH% 2^>nul') do set "NEW_TIP=%%C"
for /f %%C in ('git rev-parse HEAD 2^>nul') do set "HEAD_TIP=%%C"
if not "%HEAD_TIP%"=="%OLD_TIP%" (
  if defined DSH_PULL_FORCE (
    echo [WARN] 本地有未推送提交，DSH_PULL_FORCE=1 强制对齐远端...
    goto :pull_reset
  )
  echo [WARN] 本地有未推送提交，已保留本地版本；推送后重试，或设 DSH_PULL_FORCE=1 强制对齐远端。
  goto :pull_done
)
:pull_reset
git reset --hard FETCH_HEAD
if errorlevel 1 (
  echo [ERROR] git reset 失败，使用现有代码继续。
  goto :pull_done
)
if "%OLD_TIP%"=="%NEW_TIP%" (
  echo [OK] 已是最新（%PULL_BRANCH%），本地仅保留最新一次提交。
) else (
  echo [OK] 已更新到 %PULL_BRANCH% 最新提交，本地仅保留最新一次提交。
)
git reflog expire --expire=now --all >nul 2>nul
git gc --prune=now --quiet
:pull_done

rem [2/4] 安装依赖
if defined DSH_NO_INSTALL (
  echo [SKIP] DSH_NO_INSTALL 已设置，跳过依赖安装。
) else (
  echo [2/4] 安装依赖（pnpm install --ignore-scripts）...
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
  echo [3/4] 构建（pnpm run build）...
  call pnpm run build
  if errorlevel 1 (
    echo [ERROR] 构建失败，请查看上方日志。
    exit /b 1
  )
)

rem [hook] 安装 git hooks（仅当未安装时）
if not exist "%APP_DIR%\.git\hooks\pre-commit" (
  echo [hook] 安装 git hooks（npx lefthook install）...
  call npx lefthook install
) else (
  echo [hook] git hooks 已安装，跳过。
)

rem [4/4] 启动 Web 服务
echo [4/4] 启动 Web 服务: pnpm dsh web --no-open ^(按 Ctrl+C 可停止，关闭本窗口即停止服务^)
call pnpm dsh web --no-open
