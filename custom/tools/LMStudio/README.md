# custom/tools/LMStudio/ — LM Studio 模型路由代理

本目录提供 `lmstudio_router.py`：一个跑在 DSH 与 [LM Studio](https://lmstudio.ai/) 之间的
OpenAI 兼容代理。它按请求体里的 `model` 字段**自动在 LM Studio 中卸载旧模型、加载目标模型**，
再把请求转发给 LM Studio——解决「LM Studio 一次只能加载一个模型，手工切换很烦」的问题。

本机视觉任务优先走这条链路，避免把图片直接塞进主模型上下文（见
[`../../skills/local-vision/SKILL.md`](../../skills/local-vision/SKILL.md)）。

```text
DSH Vision Router  ─┐
                    ├─►  lmstudio_router.py :1235  ──►  LM Studio :1234
curl / 任意客户端   ─┘        （自动切换模型）           （真正的推理）
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `lmstudio_router.py` | 代理服务 + 管理 CLI（`status` / `models` / `load` / `unload` / `ask`） |

## 使用前提

1. **LM Studio 已启动**，本地服务在监听（默认 `http://localhost:1234`）。
   LM Studio 的 Developer / Server 页面可以看到当前端口；router 只是代理，
   LM Studio 没起来它也无能为力。本工具**不代为启动 LM Studio 桌面端**。
2. **目标模型已在 LM Studio 中下载**（GGUF）。模型名必须用 `/v1/models` 返回的真实 key，
   不是界面上的显示名。
3. **router 在运行**（默认 `http://127.0.0.1:1235`）。
4. Python 依赖：`fastapi`、`uvicorn`、`requests`（`ask` / `models` 等子命令只用标准库即可跑，
   `serve` 才需要前两者）。

## 可用模型（本机 LM Studio 实测）

| 模型 key | 参数 / 量化 | 大小 | 用途 |
| --- | --- | --- | --- |
| `moondream-2b-2025-04-14` | 2B / F16 | 3.49GB | 超轻量，适合快速 OCR、简单描述、低延迟场景。**注意：实测经 OpenAI 端点常返回空串**（见常见问题） |
| `minicpm-v-2_6` | 7.6B / Q8_0 | 8.51GB | 高质量 OCR、文档/表格理解，目前最可靠的默认选择 |
| `qwen2.5-vl-7b-instruct` | 7B / Q4_K_M | 5.62GB | 通用视觉理解、UI 元素语义、空间推理；上下文 128k |
| `text-embedding-nomic-embed-text-v1.5` | — / Q4_K_M | 84MB | 嵌入模型（非对话模型，router 不用于识图） |

三个视觉模型都声明了 `vision: true`。一次只能加载一个（显存限制）；
切换实测约 7–10 秒/次，所以同一轮任务应固定用一个模型。

### 选型建议

- 只想知道「图里写了什么字」→ `minicpm-v-2_6`
- 判断「这个按钮在哪、这个图标什么意思、布局什么样」→ `qwen2.5-vl-7b-instruct`
- 显存紧张、只要廉价粗筛 → `moondream-2b-2025-04-14`（先验证它在你这次输入上不是空串）

## 启动

```bash
cd <仓库根>/custom/tools/LMStudio
PYTHONIOENCODING=utf-8 python lmstudio_router.py serve    # 前台
```

后台运行（MSYS / Git Bash）：

```bash
PYTHONIOENCODING=utf-8 nohup python lmstudio_router.py serve > /tmp/lmstudio-router.log 2>&1 &
sleep 6 && curl -s -m 5 http://127.0.0.1:1235/health
```

Windows CMD：

```bat
start /b python lmstudio_router.py serve
```

`PYTHONIOENCODING=utf-8` 别省：Windows 控制台默认 GBK，日志/管道里的中文会变乱码。

## 环境变量

脚本内**不含任何本机绝对路径**，端口与地址全部可用环境变量覆盖：

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `LMSTUDIO_BASE` | LM Studio 服务地址（不带 `/v1`） | `http://localhost:1234` |
| `LMSTUDIO_ROUTER_PORT` | 本代理监听端口 | `1235` |
| `LMSTUDIO_ROUTER_HOST` | 本代理监听地址 | `127.0.0.1` |
| `LMSTUDIO_VISION_MODEL` | `model="auto"` 时使用的视觉模型 | `qwen2.5-vl-7b-instruct` |
| `LMSTUDIO_RETRY_ON_EMPTY` | 设为 `0` 关闭「空正文兜底重试」 | `1`（开启） |
| `LMSTUDIO_RETRY_MODEL` | 空正文兜底时改用的模型；留空等于关闭 | `minicpm-v-2_6` |
| `LMSTUDIO_LOAD_TIMEOUT` | 加载模型超时秒数 | `300` |
| `LMSTUDIO_REQUEST_TIMEOUT` | 转发请求超时秒数 | `600` |

## 调用方式

### OpenAI 兼容端点

```bash
ROUTER=http://127.0.0.1:1235
curl -s -m 300 "$ROUTER/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model": "minicpm-v-2_6",
  "messages": [{"role":"user","content":[
    {"type":"text","text":"这张图里的文字是什么？"},
    {"type":"image_url","image_url":{"url":"data:image/png;base64,<BASE64>"}}]}],
  "max_tokens": 512
}'
```

也支持流式（`"stream": true`）：router 会原样透传 SSE。

### 管理端点

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| `GET` | `/health` | router + LM Studio 连通性、当前已加载实例、`auto` 指向的模型（503 表示 LM Studio 不可达） |
| `GET` | `/router/status` | 更详细：每个模型的量化、大小、视觉能力、加载状态 |
| `GET` | `/router/models` | 原始模型清单（排查模型名用） |
| `POST` | `/router/load` | `{"model":"<key>"}`：需要时先卸载占用者再加载 |
| `POST` | `/router/unload` | `{"model":"<key>"}` 或 `{"all": true}` |
| `GET` | `/v1/models` | OpenAI 兼容模型列表（只列 LLM，用真实 key） |

### CLI

子命令会**优先走 router**（因此也能触发自动切换）；router 没在跑时直接访问 LM Studio。

```bash
python lmstudio_router.py status                  # 连通性 + 已加载模型
python lmstudio_router.py models                  # 表格：key / 视觉 / 加载 / 大小 / 量化
python lmstudio_router.py models --json           # 原始 JSON
python lmstudio_router.py models --direct         # 绕过 router 直连 LM Studio
python lmstudio_router.py load minicpm-v-2_6      # 加载（自动腾出占用者）
python lmstudio_router.py load auto               # 加载 LMSTUDIO_VISION_MODEL
python lmstudio_router.py unload minicpm-v-2_6    # 卸载指定模型
python lmstudio_router.py unload --all            # 卸载全部，释放显存
python lmstudio_router.py ask --image shot.png "图里有什么？"
python lmstudio_router.py ask --model moondream-2b-2025-04-14 --image shot.png "简单描述"
```

`ask` 的 `--image` 可重复传入，也接受 `http(s)://` 与 `data:` URL。
退出码：`0` 成功 / `1` 运行期失败（LM Studio 不可达、模型加载失败等）/ `2` 参数错误 /
`3` 缺少 `serve` 所需依赖。

## 与 DSH Vision Router 插件配合

`dsh-vision-router` 的本地 LM Studio 后端应指向 **router**，而不是 LM Studio 本体，
否则拿不到自动切换、且换模型要靠 LM Studio 自己猜：

```yaml
vision-router:
  localLmStudio:
    enabled: true
    baseURL: http://localhost:1235/v1   # router；不是 1234
    model: qwen2.5-vl-7b-instruct
    format: openai
```

## 常见问题

- **`Errno 10048` 端口被占**：已经有实例在跑，先复用（`curl -s $ROUTER/health`）。
  要换新实例，先找占用者：`netstat -ano | grep :1235`，再 `taskkill //F //PID <pid>`。
  注意 MSYS 的 `pkill -f` **杀不掉** Windows 下由 bash 拉起的 python 子进程，
  必须用 `taskkill`。
- **请求成功但 `content` 是空串**：实测 `moondream-2b-2025-04-14` 经 `/v1/chat/completions`
  会把图片算进 `prompt_tokens`（约 740）却返回空内容；同图换 `minicpm-v-2_6` 立即正常。
  router 现在会**自动兜底**：非流式响应若正文为空、且请求的是有视觉能力的模型，
  就换 `LMSTUDIO_RETRY_MODEL`（默认 `minicpm-v-2_6`）重试一次，
  并在响应头 `x-lmstudio-router-retry` 里标注实际出图的模型。
  想看原始空响应就设 `LMSTUDIO_RETRY_ON_EMPTY=0`。
  另注意：流式（`stream: true`）不做兜底——SSE 已经边生成边下发，无法事后回退。
- **`unknown model 'xxx'`**：模型名用 `models` 子命令返回的 key（如 `minicpm-v-2_6`），
  不是显示名（`MiniCPM V 2 6`）。错误信息里会列出全部可用 key。
- **首个请求慢 7–10 秒**：正在切换/加载模型，属正常。加载超时默认 300s（`LMSTUDIO_LOAD_TIMEOUT`）。
- **中文乱码**：加 `PYTHONIOENCODING=utf-8`。
- **代理转发 502**：LM Studio 本体没启动或端口不是 1234。用 `status` 区分是
  「LM Studio unreachable」还是「router 没起来」。
- **改脚本后 `POST` 端点返回 422 `Field required: query.request`**：
  端点函数定义在 `build_app()` 内部并使用了局部导入的 `Request` 类型；
  一旦在模块顶部加 `from __future__ import annotations`，FastAPI 会无法解析该注解类型，
  把请求体当成查询参数。**不要加这个 future import**（脚本里已注明）。
- **模型常驻占显存**：用完 `unload --all`，下次按需重新加载。

## 维护备注

- 脚本只用 `fastapi` / `uvicorn` / `requests` 三个既有依赖 + 标准库；未引入新依赖。
- 模型自动切换在进程内**串行加锁**（`_SWITCH_LOCK`），避免并发请求反复装卸同一张卡。
- 空正文兜底只在**非流式**响应上生效，且每个请求最多重试一次，不会无限递归。
- 视觉模型名、大小等描述以本机 LM Studio 实际可加载的模型为准（用 `models` 子命令复核）。
