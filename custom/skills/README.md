# custom/skills/ — 个人 agent skill 包

本目录存放**个人自定义的 agent skill**。每个 skill 是一个目录，目录内含一个 `SKILL.md`：

```
skills/
└── <skill-name>/
    ├── SKILL.md          # 必需：YAML frontmatter + 正文
    └── resources/        # 可选：脚本、模板、夹具等随 skill 分发的素材
```

## SKILL.md 格式

文件以 YAML frontmatter 开头：

```markdown
---
name: <skill-name>              # 必需；建议与目录名一致
description: <一句话说明>        # 必需；会出现在 agent 的技能目录里，用于路由
whenToUse: <何时该用这个 skill>   # 可选；触发场景
---

正文……
```

- `name` 与 `description` 缺一不可，否则该文件会被 DSH 忽略（日志里会有 `skill file ... ignored: frontmatter requires name and description`）。
- `description` 是 agent 判断「要不要加载这个 skill」的唯一依据，写清**做什么 + 什么场景用**，不要写成标题。
- `resources/` 里的文件通过 skill 的 `resourceBase` 暴露给 agent；正文里用相对路径引用。

现有 skill：

| skill | 用途 |
| --- | --- |
| `qt-screenshot/` | 给 Qt/QML 应用启动真实窗口并按窗口句柄截图（视觉检查、多尺寸回归、排查窗口出不来 / 截图为空白 / 脚本卡死） |

## 如何将 skill 接入 DSH

**DSH 不会自动扫描 `custom/skills/`。** 随附的本地 skill 提供方按 rank 扫描这些根目录：

| rank | 来源 | 根目录 |
| --- | --- | --- |
| 100 | `project-dsh` | `<项目根>/.dsh/skills` |
| 200 | `project-agents` | `<项目根>/.agents/skills` |
| 300 | `custom` | 配置项 `customSkillDirs` 列出的目录 |
| 400 | `user-dsh` | `$DSH_HOME/skills`（默认 `~/.dsh/skills`） |
| 500 | `user-agents` | `$DSH_AGENTS_HOME/skills`（默认 `~/.agents/skills`） |

`custom/skills/` 不在上面任何一行里，因此需要下面三种方式之一把它接进去。

### 方式一：在设置面板添加目录（推荐）

在 DSH Web UI 的**设置 → Agent Skills（技能）**面板里点击「添加目录 / Add directory」，
选中本目录（`<仓库根>/custom/skills`）作为技能提供者目录。

该入口在部分构建里表现为「配置额外的 skill 根目录」，它最终写入的就是提供方
`@deepseek-ai/dsh-skill-filesystem` 的 `customSkillDirs`。如果当前版本的面板没有这个入口，
直接改配置文件即可，效果完全等价——在 `$DSH_HOME/cordis.patch.yml`（默认 `~/.dsh/cordis.patch.yml`）
里追加一条：

```yaml
# --- skills: 让 DSH 扫描仓库里的 custom/skills ---
- insert:
    - id: skills-custom
      name: "@deepseek-ai/dsh-skill-filesystem"
      config:
        customSkillDirs:
          - "<仓库根>/custom/skills"
# --- end skills-custom ---
```

### 方式二：复制或链接到默认扫描根

把 skill 目录放进 `$DSH_HOME/skills`（默认 `~/.dsh/skills`）或 `~/.agents/skills`：

```bash
# 复制一份（改动不会自动同步回仓库）
cp -r <仓库根>/custom/skills/qt-screenshot "$HOME/.dsh/skills/"

# 或者建立目录链接，保持与仓库同步（Windows 上用 mklink /J 建目录联接）
ln -s <仓库根>/custom/skills/qt-screenshot "$HOME/.dsh/skills/qt-screenshot"
```

注意：链接/复制过去的是 skill 目录本身。`qt-screenshot` 的正文引用仓库里的
`custom/tools/` 脚本，若只复制了 skill，请一并复制工具目录，或设置环境变量
`QT_SHOT_TOOLS` 指向工具实际所在位置。

### 方式三：通过插件安装

如果使用技能管理类插件（例如 `dsh-plug-skills` 之类的面板插件），
可在插件面板中「安装 / 导入」本地技能目录，插件会把技能目录复制进
`$DSH_HOME/skills/<目录名>`，并（可选）代为登记 `customSkillDirs`。
安装完成后同样按下面的方式让它生效。

### 生效与验证

- 技能目录被监听：新增 skill 目录、修改已有 `SKILL.md` 会触发重新发现。
- 复制整个目录到新的根目录、或改动 `customSkillDirs` 配置后，
  配置变更需要**重启 DSH**；仅内容变化通常刷新会话（新建会话）即可。
- 验证：新建一个会话，看会话开头的可用技能列表里是否出现 `qt-screenshot`；
  或直接让 agent「列出可用 skill」。DSH 日志里也会有解析告警，便于排查 frontmatter 写错的情况。
