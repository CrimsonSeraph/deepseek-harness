---
name: local-vision
description: 本地 LM Studio 视觉模型识图（OCR、UI 定位、文档理解），避开 DSH 原生读图的高 token 开销
whenToUse: 需要看图：OCR、截图/UI 定位、文档理解
---

# 本地视觉（Local Vision）

看图**默认走本机 LM Studio**，不把图片塞进主模型上下文。
主模型只拿回文本结果，图片像素留在本地视觉模型侧。

**不要直接退回 DSH 原生识图。** 原生 `read_image` 会把整张图编码进上下文，
单张截图常是数百到数千 token，且每看一次付一次。只有本地链路确认全挂时才向用户请示。

## 何时用哪个模型

| 场景                                      | 模型（`model` 字段）      | 体积 / 量化     | 备注                                                            |
| ----------------------------------------- | ------------------------- | --------------- | --------------------------------------------------------------- |
| 快速 OCR、简单描述、低延迟、批量粗筛      | `moondream-2b-2025-04-14` | 3.49GB / F16    | 最轻；**实测经 OpenAI 端点常返回空串**，router 会自动兜底换模型 |
| 高质量 OCR、文档/表格理解、字段抽取       | `minicpm-v-2_6`           | 8.51GB / Q8_0   | 目前**最可靠**的默认选择                                        |
| 复杂场景理解、UI 元素语义、空间推理、定位 | `qwen2.5-vl-7b-instruct`  | 5.62GB / Q4_K_M | 上下文 128k，router 的 `auto` 默认指向它                        |
| 不确定 / 让 router 选                     | `auto`（或 `vision`）     | —               | 解析为 `LMSTUDIO_VISION_MODEL`，默认 `qwen2.5-vl-7b-instruct`   |

一次只加载一个视觉模型（显存限制）。**同一轮任务里固定用一个模型**，
换来换去每次都要卸载 + 重新加载（实测约 7–10 秒），得不偿失。

## 如何使用

两种方式，任选其一；都在 `http://127.0.0.1:1235/v1`，OpenAI 兼容。

### 方式一：DSH Vision Router 插件（推荐，无需写代码）

已配置好本地后端，服务地址指向本 router（`~/.dsh/settings.yaml` 的 `vision-router` 段）：

```yaml
vision-router:
  routingMode: auto
  routingPreference: local # 优先本地
  backgroundBenchmarking: local-free
  desktopScreenshot: true
  localLmStudio:
    enabled: true
    baseURL: http://localhost:1235/v1 # 指向 router，不是 LM Studio 的 1234
    model: qwen2.5-vl-7b-instruct
    format: openai
```

直接用插件提供的工具即可：`vision_describe`、`vision_ocr`、`vision_locate`、
`vision_ground`、`vision_crop`、`vision_pixel_diff`、`vision_screenshot`。
**这些工具只在 router 活着时才有本地后端可用**，所以调用前先确认 router 状态。

改模型：把 `localLmStudio.model` 换成上表的模型 ID（或在设置 → Vision Router →
「本地与设备」里改），无需重启 DSH。

### 方式二：直接对 router 发 OpenAI 兼容请求

```bash
ROUTER=${LMSTUDIO_ROUTER_BASE:-http://127.0.0.1:1235}
curl -s -m 300 "$ROUTER/v1/chat/completions" -H 'Content-Type: application/json' -d '{
  "model": "minicpm-v-2_6",
  "messages": [{"role":"user","content":[
    {"type":"text","text":"这张图里的文字是什么？只回文字。"},
    {"type":"image_url","image_url":{"url":"data:image/png;base64,<BASE64>"}}]}],
  "max_tokens": 512, "temperature": 0.1
}'
```

图片也可以用 `file://` 形式传路径，或先转 base64。脚本还带了一个现成的提问命令：

```bash
TOOLS=${LOCAL_VISION_TOOLS:-<仓库根>/custom/tools/LMStudio}
python "$TOOLS/lmstudio_router.py" ask --image <图片路径> "<问题>"
python "$TOOLS/lmstudio_router.py" ask --model moondream-2b-2025-04-14 --image <图> "<问题>"
```

## 如何切换 / 卸载

**正常情况不用手动切换**：router 检查请求里的 `model`，发现和当前已加载的不是同一个时，
自动卸载旧模型 → 加载新模型 → 再转发（首个请求会多等 7–10 秒，其余请求直接命中）。
`/v1/chat/completions`、`/router/load`、`/router/unload` 都走同一套逻辑，且串行加锁，
不会出现两个请求同时装卸把显存打爆。

显式操作（都用同一份脚本，不用记 LM Studio 自己的 API）：

```bash
python "$TOOLS/lmstudio_router.py" status                 # 连通性 + 当前已加载
python "$TOOLS/lmstudio_router.py" models                 # 全部模型：视觉能力 / 加载状态 / 大小
python "$TOOLS/lmstudio_router.py" load minicpm-v-2_6     # 加载（自动腾出占用者）
python "$TOOLS/lmstudio_router.py" unload minicpm-v-2_6   # 卸载指定模型
python "$TOOLS/lmstudio_router.py" unload --all           # 卸载全部（释放显存）
```

等价 HTTP（router 未启动时，脚本会自动直连 LM Studio 的 `http://localhost:1234`）：

```bash
curl -s -X POST "$ROUTER/router/load"   -H 'Content-Type: application/json' -d '{"model":"minicpm-v-2_6"}'
curl -s -X POST "$ROUTER/router/unload" -H 'Content-Type: application/json' -d '{"all":true}'
curl -s "$ROUTER/health"          # router + LM Studio 连通性
curl -s "$ROUTER/router/models"   # 原始模型清单
```

**用完长时间不用就 `unload --all`**：视觉模型常驻会白占 3.5–8.5GB 显存，
影响用户其它工作；下次用时 router 会按需重新加载。

## 降级逻辑（硬性顺序）

图片来了但视觉链路不通时，**严格按下面顺序自愈，不要跳步，也不要直接放弃**：

1. **探测**：`curl -s -m 3 "$ROUTER/health"` 或 `python "$TOOLS/lmstudio_router.py" status`。
   还要确认 LM Studio 本身在监听（默认 `http://localhost:1234`）——router 只是代理，
   LM Studio 没起来它也转发不了。
2. **router 没起来 → 先启动 router**：

   ```bash
   cd <仓库根>/custom/tools/LMStudio
   PYTHONIOENCODING=utf-8 nohup python lmstudio_router.py serve > /tmp/lmstudio-router.log 2>&1 &
   sleep 6 && curl -s -m 5 "$ROUTER/health"      # 必须看到 {"router":"ok","lmstudio":"ok"}
   ```

   `sleep` + `/health` 这一步不能省：`nohup … &` 在本机 Git Bash 下可用，
   但 Windows CMD 要用 `start /b python lmstudio_router.py serve`；
   两种情况都得回读 `/health` 确认，而不是假定启动成功。
   `PYTHONIOENCODING=utf-8` 也别省（见「故障排查」）。

3. **模型没加载 → 通过 router 或直连 LM Studio 加载**：
   `python "$TOOLS/lmstudio_router.py" load <模型>`，或 `POST $ROUTER/router/load`。
   加载要 7–10 秒，别用 5 秒超时就判失败。
4. **仍然失败 → 换一个本地模型重试一次**（`moondream` ↔ `minicpm-v-2_6` ↔ `qwen2.5-vl-7b-instruct`）。
   实测 `moondream` 经 OpenAI 端点会静默返回空串，换 `minicpm-v-2_6` 立刻可用。
   router 对非流式请求已内置这层兜底（响应头 `x-lmstudio-router-retry` 可见），
   但**流式请求和 `vision_*` 工具路径没有**——那里出现空结果要自己换模型复测，
   不要当作图片有问题。
5. **以上全部失败 → 才向用户报告并请示**是否回退到 DSH 原生识图。
   报告里要写清试过什么、报错原文、以及回退的 token 代价，让用户决定。

禁止行为：一上来就用 `read_image`；把「router 没启动」当成「本地模型不可用」；
未经用户同意就改 `~/.dsh/settings.yaml`、装依赖、改 LM Studio 配置。

## 故障排查

| 现象                        | 原因 / 处理                                                                                                                                                                                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `curl` 连不上 1235          | router 没起来。按降级逻辑第 2 步启动；注意 MSYS 的 `pkill` 杀不掉 Windows 进程下的 python                                                                                                                                                                     |
| 端口被占（`Errno 10048`）   | 已有实例在跑，**先复用**：`curl -s $ROUTER/health`。要换实例先 `netstat -ano \| grep :1235` 找 PID，再 `taskkill //F //PID <pid>`                                                                                                                             |
| 中文输出乱码                | 缺 `PYTHONIOENCODING=utf-8`。Windows 默认 GBK，写日志/管道时尤其明显                                                                                                                                                                                          |
| 请求成功但 `content` 是空串 | 多半是 `moondream-2b-2025-04-14`：它经 OpenAI 端点会把图片算进 token（约 740）却返回空内容。router 会自动换 `minicpm-v-2_6` 重试一次（非流式），响应头 `x-lmstudio-router-retry` 标明实际出图的模型；开了 `stream: true` 就没有这层兜底，需要自己判空并换模型 |
| `unknown model 'xxx'`       | 模型名必须用 `/v1/models` 或 `models` 子命令返回的真实 key（如 `minicpm-v-2_6`，不是显示名 `MiniCPM V 2 6`）                                                                                                                                                  |
| 首个请求特别慢（7–10s+）    | 正常：正在切换模型。后续请求走缓存好的已加载实例                                                                                                                                                                                                              |
| 两次请求之间模型被换掉      | 另一个调用方请求了别的模型。router 会串行切换；同轮任务里统一模型名                                                                                                                                                                                           |
| 显存/内存吃紧               | `unload --all` 释放；或改用 `moondream-2b-2025-04-14`（最小）                                                                                                                                                                                                 |
| `vision_*` 工具报无可用后端 | Vision Router 插件的 `localLmStudio.enabled` 或 `baseURL` 不对——必须是 `.../1235/v1`（router），不是 `.../1234/v1`（LM Studio 本体），后者缺自动切换                                                                                                          |
| LM Studio 没启动            | 需要用户手动启动 LM Studio 桌面端（本 skill 不代为启动 GUI 程序）；启动后 `status` 应显示 `LM Studio : ok`                                                                                                                                                    |

## 成本说明（为什么值得这么绕）

- 本地视觉请求**不计费**，也不消耗主模型上下文；主模型只看到文本结果。
- 对比：一张 1180×760 截图按原生读图编码，动辄上千 token，且每次复看都要重付。
  走本地链路后同样一张图对主模型是 0 token，识别结果还可以写进文件复用。
- 因此**图片类任务优先本地**：先本地识别成文本（必要时落盘），再让主模型基于文本推理。
