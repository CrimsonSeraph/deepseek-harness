# 本地已安装第三方插件清单（custom/plugins）

本目录记录本机在 DSH Web 运行环境中安装的**非上游（第三方）插件**清单及其安装方式，
供重装、迁移、审计参考。快照时间：2026-08；上游仓库自带插件（`@deepseek-ai/dsh-*`）不在此列。
数据来自用户 web profile（`%USERPROFILE%\.dsh\profiles\web`），本文不含任何用户私人数据。

## 安装方式汇总

DSH 插件通过 **profile 机制**安装：每个 profile（如 `web`）在
`%USERPROFILE%\.dsh\profiles\<profile>\` 下维护自己的 `package.json`（声明 `dependencies` 与
`dsh.profile.bundles` 组合列表），重启 `dsh web` 后生效。

### 方式一：官方 CLI（推荐）

`dsh plugin` 子命令把剩余参数转发给 profile 目录里的 pnpm：

```bat
rem 安装（示例：全家桶聚合包）
dsh plugin --profile web add @linxin666/dsh-web-ui-all
rem 卸载
dsh plugin --profile web remove <包名>
rem 升级聚合包
dsh plugin --profile web add @linxin666/dsh-web-ui-all@latest
```

安装后重启 `dsh web` 生效（本机启动器：`custom/launcher/start-dsh.bat`，服务已在运行时会直接打开应用）。

### 方式二：GUI 插件管理器

设置页 → Plugins → **Plugin manager** 标签（由 `@linxin666/dsh-client-ui-plugin-manager` 提供）：

- 从 npm 包名或 git 仓库地址安装，带进度与结果；
- 已安装插件可切换「下次启动启用」、检查更新（npm registry）、更新、卸载；
- 安装冲突可回滚（undo），或交给 agent 修复（repair 会话）；
- 生效开关与安装均在下次重启时应用。

### 方式三：手动编辑 profile（进阶）

1. 编辑 `%USERPROFILE%\.dsh\profiles\web\package.json`：
   - 在 `dependencies` 中加入包名与版本；
   - 在 `dsh.profile.bundles` 中加入包名（皮肤类包 `bundleWired: false`，无需加入）；
2. 在 profile 目录执行 `pnpm install`；
3. 重启 `dsh web`。

### 皮肤切换

```bat
dsh-skin use miku
```

皮肤激活互斥，写入 profile 的 `cordis.patch.yml` 托管段（本机 `~/.dsh/cordis.patch.yml` 的
`dsh-skin managed` 段），也可在 GUI 皮肤中心操作。

## 插件清单

### 聚合包（一键安装全家桶）

| 包名 | 版本 | 说明 |
| --- | --- | --- |
| `@linxin666/dsh-web-ui-all` | 0.2.3 | DSH Web UI 全家桶聚合包：一条命令带入下表全部功能插件（皮肤与 session-manager 除外） |

### 功能插件

| 包名 | 版本 | 功能 | 入口 |
| --- | --- | --- | --- |
| `@linxin666/dsh-client-ui-task-board` | 0.2.3 | 任务看板：Host 权威账本、真实会话执行、Host cron 定时（5 段 cron，本地时区） | 侧边栏「任务看板」 |
| `@linxin666/dsh-ssh` | 0.2.3 | SSH 远程运维：主机配置/执行/传输/隧道/集群，Web 终端 | 侧边栏「SSH」 |
| `@linxin666/dsh-liangshen` | 0.2.3 | 梁神模式 agent preset（两阶段锚定），升级时自动更新 `~/.dsh/.agent-presets/liangshen/` | 新建会话预设选择器「梁神模式」 |
| `@linxin666/dsh-pet` | 0.2.3 | 桌面宠物（注册表驱动，可反应于会话状态） | 浮动宠物 |
| `@linxin666/dsh-remote-web-ui` | 0.2.3 | 手机远程控制（扫码配对） | 设置按钮旁二维码 |
| `@linxin666/dsh-client-ui-git-graph` | 0.2.3 | Git 图谱与分支选择 | 侧边栏 Git |
| `@linxin666/dsh-client-ui-aionui-panel` | 0.2.3 | AionUi 风格右侧面板（Explorer 等，像素级复刻） | 右侧面板 |
| `@linxin666/dsh-client-ui-plugin-manager` | 0.2.3 | 插件管理器标签页（npm/git 安装、更新、卸载、冲突回滚） | 设置 → Plugins |
| `@linxin666/dsh-client-ui-community-plugins` | 0.2.3 | 社区插件索引卡片 | 设置页 |
| `@linxin666/dsh-client-ui-skill-explorer` | 0.2.3 | 技能浏览器（按 bundled/project/user/custom/runtime 分组） | 技能中心 |
| `@linxin666/dsh-client-ui-web-ui-settings` | 0.2.3 | Web UI 设置分组 | 设置页 |
| `@linxin666/dsh-client-ui-skin-center` | 0.2.3 | 皮肤中心（皮肤的唯一载体包） | 设置 → 皮肤 |
| `@linxin666/dsh-skins` | 0.2.3 | 皮肤兼容包（已退役，保留一个发布周期，仅传递皮肤中心） | - |
| `@linxin666/dsh-tool-describe-image` | 0.2.3 | `describe_image` 模型工具：让纯文本模型获得图片理解 | 工具层 |
| `dsh-better-sidebar` | 0.13.0 | VSCode 风格侧边栏（explorer/editor/terminal/git/browser） | 侧边栏 |

### 皮肤

| 包名 | 版本 | 说明 | 激活 |
| --- | --- | --- | --- |
| `@linxin666/dsh-client-ui-skin-miku` | 0.2.0 | 初音未来主题：蓝紫品红渐变 + 毛玻璃 + 深浅双主题，纯表现层可完整还原 | `dsh-skin use miku` |

### 独立插件（未进全家桶）

| 包名 | 版本 | 说明 | 安装命令 |
| --- | --- | --- | --- |
| `dsh-session-manager` | 0.1.2 | 会话管理：删除会话需确认、归档管理 | `dsh plugin --profile web add dsh-session-manager` |

## 来源仓库

| 仓库 | 说明 |
| --- | --- |
| https://github.com/zhu1090093659/dsh-web-ui | dsh-web-ui 插件全家桶（`@linxin666/*`：聚合包、ssh、task-board、liangshen 等） |
| https://github.com/omdsh-dev/DSH-better-sidebar | dsh-better-sidebar |
| https://github.com/hkkz9522/dsh-session-manager | dsh-session-manager |

## 本机数据位置（用户数据，不入库）

| 路径 | 内容 |
| --- | --- |
| `%USERPROFILE%\.dsh\profiles\web\package.json` | web profile 的依赖与 bundles 声明（本文档的权威来源） |
| `%USERPROFILE%\.dsh\dsh-ssh.json` | SSH 主机配置（含密码明文，权限 0600，注意保管；可从 `~/.ssh/config` 导入） |
| `%USERPROFILE%\.dsh\task-board\` | 任务看板账本（ledger-v2.json）与调度器状态 |
| `%USERPROFILE%\.dsh\.agent-presets\liangshen\` | 梁神模式 preset 文件（插件升级时自动更新） |
| `%USERPROFILE%\.dsh\cordis.patch.yml` | 皮肤等 patch 层托管段（`dsh-skin managed`） |

## 注意事项

1. 版本为 2026-08 快照，实际以 `npm view <包名> version` 或 GUI 插件管理器的更新检查为准；
2. 升级全家桶后如遇皮肤/面板异常，先检查 `~/.dsh/cordis.patch.yml` 托管段与 profile 的 `pnpm-lock.yaml`；
3. SSH 密码以明文存放于用户主目录私有文件，传输/执行消耗真实远程资源，操作前先确认。
