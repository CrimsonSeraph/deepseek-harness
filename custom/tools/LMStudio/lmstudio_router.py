#!/usr/bin/env python3
"""LM Studio 模型路由代理。

对外暴露 OpenAI 兼容端点，收到请求后按 ``model`` 字段自动在 LM Studio 中
卸载旧模型、加载目标模型，再转发请求。附带一组管理子命令，用于查看/加载/卸载
模型，以及直接提问（无需 DSH 参与）。

依赖：fastapi、uvicorn、requests（均已在本机环境可用）。

配置一律通过环境变量，脚本内不含任何本机绝对路径：

===========================  ==========================================  ==========================
环境变量                     含义                                        默认
===========================  ==========================================  ==========================
``LMSTUDIO_BASE``            LM Studio 服务地址（不带 ``/v1``）            ``http://localhost:1234``
``LMSTUDIO_ROUTER_PORT``     本代理监听端口                                ``1235``
``LMSTUDIO_ROUTER_HOST``     本代理监听地址                                ``127.0.0.1``
``LMSTUDIO_VISION_MODEL``    ``model="auto"`` 时使用的视觉模型              ``qwen2.5-vl-7b-instruct``
``LMSTUDIO_RETRY_ON_EMPTY``  空正文兜底重试开关（``0`` 关闭）                ``1``
``LMSTUDIO_RETRY_MODEL``     空正文时改用的模型；留空等于关闭               ``minicpm-v-2_6``
``LMSTUDIO_LOAD_TIMEOUT``    加载模型的超时秒数                            ``300``
``LMSTUDIO_REQUEST_TIMEOUT`` 转发请求的超时秒数                            ``600``
===========================  ==========================================  ==========================

用法::

    python lmstudio_router.py                 # 等价于 serve：启动代理
    python lmstudio_router.py serve           # 启动代理（前台）
    python lmstudio_router.py status          # LM Studio 与本代理的连通性
    python lmstudio_router.py models          # 列出模型（含加载状态与视觉能力）
    python lmstudio_router.py load <model>    # 加载模型
    python lmstudio_router.py unload [<model>]# 卸载指定模型；省略则卸载当前已加载的
    python lmstudio_router.py unload --all    # 卸载全部已加载模型
    python lmstudio_router.py ask --image <png> "<问题>"   # 直接向视觉模型提问

子命令会**优先走本代理**（这样也能触发自动切换），代理未运行时直接访问 LM Studio。
两条路径都用标准库 HTTP，不依赖 ``lms`` CLI 是否在 PATH 中。
"""

import argparse
import base64
import http.client
import json
import mimetypes
import os
import sys
import threading
import urllib.error
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

# 注意：不要加 `from __future__ import annotations`。端点函数定义在 build_app() 内部，
# 延迟注解会让 FastAPI 无法解析局部导入的 Request/依赖类型，把请求体当成查询参数（422）。

# --- 配置区（全部可被环境变量覆盖）---
LM_STUDIO_BASE = os.environ.get("LMSTUDIO_BASE", "http://localhost:1234").rstrip("/")
PROXY_HOST = os.environ.get("LMSTUDIO_ROUTER_HOST", "127.0.0.1")
PROXY_PORT = int(os.environ.get("LMSTUDIO_ROUTER_PORT", "1235"))
VISION_MODEL = os.environ.get("LMSTUDIO_VISION_MODEL", "qwen2.5-vl-7b-instruct")
# 空正文兜底：换 RETRY_MODEL 重试一次（设为空字符串或 LMSTUDIO_RETRY_ON_EMPTY=0 可关闭）
RETRY_ON_EMPTY = os.environ.get("LMSTUDIO_RETRY_ON_EMPTY", "1").strip().lower() not in {
    "0",
    "false",
    "no",
    "",
}
RETRY_MODEL = os.environ.get("LMSTUDIO_RETRY_MODEL", "minicpm-v-2_6").strip()
LOAD_TIMEOUT = float(os.environ.get("LMSTUDIO_LOAD_TIMEOUT", "300"))
REQUEST_TIMEOUT = float(os.environ.get("LMSTUDIO_REQUEST_TIMEOUT", "600"))

# 视觉模型清单只在进程内缓存一次；模型增删后重启 router 即可。
_VISION_CACHE: Optional[set] = None

# 切换模型是全局副作用（LM Studio 一次只放得下一个视觉模型），用锁串行化。
_SWITCH_LOCK = threading.Lock()


# --------------------------------------------------------------------------
# LM Studio REST 客户端
# --------------------------------------------------------------------------
class LMStudioError(RuntimeError):
    """LM Studio 返回的错误，携带 HTTP 状态码便于上层映射。"""

    def __init__(self, message: str, status: int = 502) -> None:
        super().__init__(message)
        self.status = status


def _request(
    method: str,
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    timeout: float = 30,
) -> Tuple[int, bytes]:
    """发一个 JSON 请求，返回 (status, body)。4xx/5xx 也正常返回而不是抛错。"""
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"} if data is not None else {}
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:  # 有响应体的失败
        return error.code, error.read()


def _json_or_text(body: bytes) -> Any:
    text = body.decode("utf-8", "replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def list_models(
    base: str = LM_STUDIO_BASE, timeout: float = 15
) -> List[Dict[str, Any]]:
    """列出 LM Studio 中的模型；用 ``/api/v1/models`` 以拿到加载状态与能力。"""
    status, body = _request("GET", f"{base}/api/v1/models", timeout=timeout)
    if status != 200:
        raise LMStudioError(
            f"LM Studio /api/v1/models returned {status}: {_json_or_text(body)}"
        )
    payload = _json_or_text(body)
    if isinstance(payload, dict) and isinstance(payload.get("models"), list):
        return payload["models"]
    if isinstance(payload, list):  # 兼容旧版返回裸数组
        return payload
    raise LMStudioError(
        f"LM Studio /api/v1/models returned unexpected payload: {str(payload)[:200]}"
    )


def loaded_instances(models: List[Dict[str, Any]]) -> List[Dict[str, str]]:
    """摊平所有已加载实例，返回 [{model, instance_id}]。"""
    result: List[Dict[str, str]] = []
    for model in models:
        for instance in model.get("loaded_instances") or []:
            instance_id = instance.get("id") or model.get("key") or ""
            result.append({"model": model.get("key") or "", "instance_id": instance_id})
    return result


def has_vision(model: Dict[str, Any]) -> bool:
    capabilities = model.get("capabilities")
    return bool(isinstance(capabilities, dict) and capabilities.get("vision"))


def is_vision_model(model_name: str, base: str = LM_STUDIO_BASE) -> bool:
    """查缓存判断模型是否具备视觉能力；查询失败时保守返回 False（不触发兜底重试）。"""
    global _VISION_CACHE
    if _VISION_CACHE is None:
        try:
            _VISION_CACHE = {m.get("key") for m in list_models(base) if has_vision(m)}
        except LMStudioError:
            return False
    return model_name in _VISION_CACHE


def message_text(response: Dict[str, Any]) -> str:
    """从 OpenAI 兼容响应里取出助手正文；结构异常时返回空串。"""
    try:
        message = (response.get("choices") or [{}])[0].get("message") or {}
    except (AttributeError, IndexError, TypeError):
        return ""
    content = message.get("content")
    return content if isinstance(content, str) else ""


def load_model(model_name: str, base: str = LM_STUDIO_BASE) -> Dict[str, Any]:
    """加载模型，返回 LM Studio 的响应体；失败抛 LMStudioError。"""
    status, body = _request(
        "POST",
        f"{base}/api/v1/models/load",
        {"model": model_name},
        timeout=LOAD_TIMEOUT,
    )
    payload = _json_or_text(body)
    if status != 200:
        raise LMStudioError(
            f"failed to load '{model_name}' ({status}): {str(payload)[:300]}"
        )
    return payload if isinstance(payload, dict) else {}


def unload_model(instance_id: str, base: str = LM_STUDIO_BASE) -> None:
    """按 ``instance_id`` 卸载模型；失败抛 LMStudioError。"""
    status, body = _request(
        "POST", f"{base}/api/v1/models/unload", {"instance_id": instance_id}, timeout=60
    )
    if status != 200:
        raise LMStudioError(
            f"failed to unload '{instance_id}' ({status}): {str(_json_or_text(body))[:300]}"
        )


def ensure_model(requested_model: str, base: str = LM_STUDIO_BASE) -> Dict[str, Any]:
    """确保 ``requested_model`` 已加载：已加载则空转，否则卸载占用者再加载。

    返回一份描述本次动作的摘要，便于代理把它透出给调用方。
    """
    models = list_models(base)
    loaded = loaded_instances(models)
    loaded_models = {item["model"] for item in loaded}

    if requested_model in loaded_models:
        return {"action": "none", "model": requested_model, "unloaded": []}

    available = [m.get("key") for m in models if m.get("type") == "llm"]
    if requested_model not in available:
        raise LMStudioError(
            f"unknown model '{requested_model}'; available: {', '.join(str(k) for k in available)}",
            status=404,
        )

    unloaded: List[str] = []
    for item in loaded:
        try:
            unload_model(item["instance_id"], base)
            unloaded.append(item["model"])
        except LMStudioError as error:
            raise LMStudioError(
                f"failed to free model '{item['model']}': {error}"
            ) from error

    result = load_model(requested_model, base)
    return {
        "action": "switched" if unloaded else "loaded",
        "model": requested_model,
        "unloaded": unloaded,
        "load_time_seconds": result.get("load_time_seconds"),
        "instance_id": result.get("instance_id"),
    }


def resolve_model(requested: Optional[str]) -> Optional[str]:
    """把 ``auto`` / ``vision`` 之类的别名解析成真实模型 ID。"""
    if requested is None:
        return None
    if requested.strip().lower() in {"auto", "vision", "default"}:
        return VISION_MODEL
    return requested


# --------------------------------------------------------------------------
# FastAPI 代理
# --------------------------------------------------------------------------
app = None  # type: ignore[assignment]


def build_app():  # noqa: ANN201 - 延迟导入，未装 fastapi 时子命令仍可用
    from fastapi import FastAPI, HTTPException, Request
    from fastapi.responses import JSONResponse, StreamingResponse
    import requests

    api = FastAPI(title="LM Studio Router", version="2.0.0")

    def _upstream_error(error: LMStudioError) -> HTTPException:
        return HTTPException(status_code=error.status, detail=str(error))

    @api.get("/health")
    async def health() -> Dict[str, Any]:
        """代理与 LM Studio 的连通性，供 skill 的降级逻辑做第一步探测。"""
        try:
            models = list_models()
        except LMStudioError as error:
            return JSONResponse(
                status_code=503,
                content={
                    "router": "ok",
                    "lmstudio": "unreachable",
                    "error": str(error),
                },
            )
        loaded = loaded_instances(models)
        return {
            "router": "ok",
            "lmstudio": "ok",
            "base": LM_STUDIO_BASE,
            "port": PROXY_PORT,
            "vision_default": VISION_MODEL,
            "loaded": loaded,
        }

    @api.get("/router/status")
    async def router_status() -> Dict[str, Any]:
        """比 /health 更详细：列出模型总数、视觉模型与已加载实例。"""
        try:
            models = list_models()
        except LMStudioError as error:
            raise _upstream_error(error) from error
        return {
            "base": LM_STUDIO_BASE,
            "port": PROXY_PORT,
            "vision_default": VISION_MODEL,
            "models": [
                {
                    "key": model.get("key"),
                    "size_bytes": model.get("size_bytes"),
                    "quantization": (model.get("quantization") or {}).get("name"),
                    "vision": has_vision(model),
                    "loaded": bool(model.get("loaded_instances")),
                }
                for model in models
            ],
            "loaded": loaded_instances(models),
        }

    @api.get("/router/models")
    async def router_models() -> Dict[str, Any]:
        """原始模型清单（含加载状态与能力），便于人工排查模型名。"""
        try:
            return {"models": list_models()}
        except LMStudioError as error:
            raise _upstream_error(error) from error

    @api.post("/router/load")
    async def router_load(request: Request) -> Dict[str, Any]:
        """显式加载：``{"model": "<key>"}``，必要时先卸载占用者。"""
        body = await request.json()
        model = resolve_model(body.get("model"))
        if not model:
            raise HTTPException(
                status_code=400, detail="Missing 'model' in request body"
            )
        try:
            with _SWITCH_LOCK:
                return ensure_model(model)
        except LMStudioError as error:
            raise _upstream_error(error) from error

    @api.post("/router/unload")
    async def router_unload(request: Request) -> Dict[str, Any]:
        """显式卸载：``{"model": "<key>"}`` 或 ``{"all": true}``。"""
        body = await request.json()
        model = resolve_model(body.get("model"))
        unload_all = bool(body.get("all"))
        if not model and not unload_all:
            raise HTTPException(
                status_code=400, detail="Provide 'model' or set 'all': true"
            )
        try:
            with _SWITCH_LOCK:
                models = list_models()
                targets = [
                    item
                    for item in loaded_instances(models)
                    if unload_all or item["model"] == model
                ]
                if not targets:
                    return {
                        "unloaded": [],
                        "note": (
                            "nothing matched"
                            if unload_all
                            else f"'{model}' is not loaded"
                        ),
                    }
                for item in targets:
                    unload_model(item["instance_id"])
                return {"unloaded": [item["model"] for item in targets]}
        except LMStudioError as error:
            raise _upstream_error(error) from error

    @api.post("/v1/chat/completions")
    async def proxy_chat(request: Request) -> Any:
        """OpenAI 兼容入口：按 body 的 ``model`` 自动切换后转发（支持流式）。"""
        body = await request.json()
        requested = resolve_model(body.get("model"))
        if not requested:
            raise HTTPException(
                status_code=400, detail="Missing 'model' in request body"
            )
        body["model"] = requested

        try:
            with _SWITCH_LOCK:
                switch = ensure_model(requested)
        except LMStudioError as error:
            raise _upstream_error(error) from error

        target_url = f"{LM_STUDIO_BASE}/v1/chat/completions"
        try:
            upstream = requests.post(
                target_url, json=body, stream=True, timeout=REQUEST_TIMEOUT
            )
        except requests.exceptions.RequestException as error:
            raise HTTPException(
                status_code=502,
                detail=f"error forwarding request to LM Studio: {error}",
            ) from error

        if upstream.status_code != 200:
            detail = upstream.text[:1000]
            upstream.close()
            raise HTTPException(status_code=upstream.status_code, detail=detail)

        if switch.get("action") != "none":
            print(
                f"[router] {switch['action']} '{requested}'"
                + (
                    f" (unloaded {', '.join(switch['unloaded'])})"
                    if switch.get("unloaded")
                    else ""
                )
                + (
                    f" in {switch['load_time_seconds']}s"
                    if switch.get("load_time_seconds")
                    else ""
                ),
                flush=True,
            )

        media_type = upstream.headers.get("content-type", "application/json")

        # 非流式且正文为空时，换一个视觉模型重试一次。实测 Moondream2 经 OpenAI 端点会把
        # 图片算进 prompt_tokens 却返回空 content——静默失败比报错更难排查。
        if "text/event-stream" not in media_type:
            payload = upstream.content
            upstream.close()
            parsed = json.loads(payload)
            if (
                not RETRY_ON_EMPTY
                or not RETRY_MODEL
                or requested == RETRY_MODEL
                or message_text(parsed).strip()
                or not is_vision_model(requested)
            ):
                return JSONResponse(content=parsed, media_type=media_type)

            print(
                f"[router] '{requested}' returned empty content; retrying with '{RETRY_MODEL}'",
                flush=True,
            )
            body["model"] = RETRY_MODEL
            try:
                with _SWITCH_LOCK:
                    ensure_model(RETRY_MODEL)
                retry = requests.post(
                    target_url, json=body, stream=False, timeout=REQUEST_TIMEOUT
                )
                retry.raise_for_status()
                parsed = retry.json()
                retry.close()
            except (requests.exceptions.RequestException, ValueError) as error:
                raise HTTPException(
                    status_code=502,
                    detail=f"retry with '{RETRY_MODEL}' failed: {error}",
                ) from error
            return JSONResponse(
                content=parsed,
                media_type=media_type,
                headers={"x-lmstudio-router-retry": RETRY_MODEL},
            )

        def stream_response():  # noqa: ANN202 - SSE 直通
            try:
                for chunk in upstream.iter_content(chunk_size=1024):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        return StreamingResponse(stream_response(), media_type=media_type)

    @api.get("/v1/models")
    async def list_openai_models() -> Dict[str, Any]:
        """OpenAI 兼容模型列表；用真实模型 key，避免客户端拿到不可用的显示名。"""
        try:
            models = list_models()
        except LMStudioError as error:
            raise _upstream_error(error) from error
        return {
            "object": "list",
            "data": [
                {
                    "id": model.get("key"),
                    "object": "model",
                    "owned_by": model.get("publisher") or "lmstudio",
                }
                for model in models
                if model.get("type") == "llm"
            ],
        }

    return api


def run_server(host: str = PROXY_HOST, port: int = PROXY_PORT) -> int:
    """启动代理；缺少依赖时给出可操作的错误。"""
    try:
        import uvicorn
    except ImportError:
        print(
            "ERROR: uvicorn is required to serve; install with: pip install fastapi uvicorn requests",
            file=sys.stderr,
        )
        return 3

    global app
    app = build_app()

    try:
        loaded = loaded_instances(list_models())
        print(
            f"[router] LM Studio at {LM_STUDIO_BASE} reachable; loaded: {loaded or 'none'}"
        )
    except LMStudioError as error:
        print(
            f"[router] WARNING: LM Studio not reachable yet ({error}); will retry per request"
        )

    print(
        f"[router] listening on http://{host}:{port}  (vision default: {VISION_MODEL})"
    )
    uvicorn.run(app, host=host, port=port, log_level="info")
    return 0


# --------------------------------------------------------------------------
# CLI：优先走代理，代理不在则直连 LM Studio
# --------------------------------------------------------------------------
def _http_json(
    method: str,
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    timeout: float = 30,
) -> Any:
    status, body = _request(method, url, payload, timeout=timeout)
    parsed = _json_or_text(body)
    if status >= 400:
        raise LMStudioError(
            f"{method} {url} -> {status}: {str(parsed)[:300]}", status=status
        )
    return parsed


def _router_base() -> str:
    return f"http://127.0.0.1:{PROXY_PORT}"


def _router_alive() -> bool:
    try:
        status, _ = _request("GET", f"{_router_base()}/health", timeout=3)
        return status < 500
    except Exception:  # noqa: BLE001 - 任何失败都视为不可用
        return False


def _admin_post(router_path: str, direct_path: str, payload: Dict[str, Any]) -> Any:
    """先试代理（能触发自动切换），代理不在时直连 ``direct_path``。"""
    if _router_alive():
        return _http_json(
            "POST", f"{_router_base()}{router_path}", payload, timeout=LOAD_TIMEOUT + 60
        )
    return _http_json(
        "POST", f"{LM_STUDIO_BASE}{direct_path}", payload, timeout=LOAD_TIMEOUT + 60
    )


def direct_unload(payload: Dict[str, Any]) -> Dict[str, Any]:
    models = list_models()
    model = resolve_model(payload.get("model"))
    unload_all = bool(payload.get("all"))
    targets = [
        item
        for item in loaded_instances(models)
        if unload_all or item["model"] == model
    ]
    if not targets:
        return {
            "unloaded": [],
            "note": "nothing matched" if unload_all else f"'{model}' is not loaded",
        }
    for item in targets:
        unload_model(item["instance_id"])
    return {"unloaded": [item["model"] for item in targets]}


def _models_via(use_router: bool) -> List[Dict[str, Any]]:
    if use_router and _router_alive():
        payload = _http_json("GET", f"{_router_base()}/router/models", timeout=30)
        return payload.get("models", [])
    return list_models()


def cmd_status(_args: argparse.Namespace) -> int:
    print(f"LM Studio base : {LM_STUDIO_BASE}")
    print(
        f"router base    : {_router_base()}  ({'running' if _router_alive() else 'NOT running'})"
    )
    try:
        models = list_models()
    except LMStudioError as error:
        print(f"LM Studio      : UNREACHABLE ({error})")
        return 1
    loaded = loaded_instances(models)
    print(f"LM Studio      : ok ({len(models)} models, {len(loaded)} loaded)")
    for item in loaded:
        print(f"  loaded: {item['model']} (instance_id={item['instance_id']})")
    if not loaded:
        print("  loaded: none")
    print(f"vision default : {VISION_MODEL} (LMSTUDIO_VISION_MODEL)")
    return 0


def cmd_models(args: argparse.Namespace) -> int:
    try:
        models = _models_via(use_router=not args.direct)
    except LMStudioError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    llms = [m for m in models if m.get("type") == "llm"]
    if args.json:
        print(json.dumps(models, ensure_ascii=False, indent=2))
        return 0
    if not llms:
        print("no LLM models found")
        return 1

    print(f"{'KEY':<32} {'VISION':<7} {'LOADED':<7} {'SIZE':>8}  QUANT")
    for model in llms:
        size = model.get("size_bytes") or 0
        print(
            f"{str(model.get('key')):<32} "
            f"{'yes' if has_vision(model) else 'no':<7} "
            f"{'yes' if model.get('loaded_instances') else 'no':<7} "
            f"{size / 1024 / 1024 / 1024:>7.2f}G  "
            f"{(model.get('quantization') or {}).get('name') or '-'}"
        )
    return 0


def cmd_load(args: argparse.Namespace) -> int:
    model = resolve_model(args.model)
    try:
        if _router_alive():
            result = _admin_post(
                "/router/load", "/api/v1/models/load", {"model": model}
            )
        else:
            # 直连时也要先腾出显存，LM Studio 不会自动替换已加载模型。
            with _SWITCH_LOCK:
                result = ensure_model(model)
    except LMStudioError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"OK {json.dumps(result, ensure_ascii=False)}")
    return 0


def cmd_unload(args: argparse.Namespace) -> int:
    payload: Dict[str, Any] = (
        {"all": True} if args.all else {"model": resolve_model(args.model)}
    )
    if not args.all and not payload.get("model"):
        print("ERROR: provide a model name, or use --all", file=sys.stderr)
        return 2
    try:
        if _router_alive():
            result = _admin_post("/router/unload", "/api/v1/models/unload", payload)
        else:
            result = direct_unload(payload)
    except LMStudioError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"OK {json.dumps(result, ensure_ascii=False)}")
    return 0


def _data_url(path: str) -> str:
    """把本地图片读成 data URL；不引入新依赖，直接用标准库猜 MIME。"""
    mime, _ = mimetypes.guess_type(path)
    if not mime or not mime.startswith("image/"):
        mime = "image/png"
    with open(path, "rb") as handle:
        encoded = base64.b64encode(handle.read()).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def cmd_ask(args: argparse.Namespace) -> int:
    """直接向视觉模型提问；走代理以复用自动切换，代理不在则直连。"""
    model = resolve_model(args.model)
    content: List[Dict[str, Any]] = [{"type": "text", "text": args.prompt}]
    for image in args.image or []:
        if image.startswith(("http://", "https://", "data:")):
            url = image
        else:
            url = _data_url(image)
        content.append({"type": "image_url", "image_url": {"url": url}})

    body: Dict[str, Any] = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
    }
    base = _router_base() if _router_alive() else LM_STUDIO_BASE
    try:
        out = _http_json(
            "POST", f"{base}/v1/chat/completions", body, timeout=REQUEST_TIMEOUT
        )
    except LMStudioError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0
    choices = out.get("choices") or [{}]
    message = choices[0].get("message") or {}
    text = message.get("content") or ""
    print(text if text.strip() else "(empty content)")
    usage = out.get("usage") or {}
    if usage:
        print(
            f"[tokens] prompt={usage.get('prompt_tokens')} completion={usage.get('completion_tokens')}"
        )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="lmstudio_router.py",
        description="LM Studio 模型路由代理：按请求的 model 字段自动切换模型，并提供管理子命令。",
    )
    parser.add_argument("--base", help=f"LM Studio 地址（默认 {LM_STUDIO_BASE}）")
    parser.add_argument("--port", type=int, help=f"代理监听端口（默认 {PROXY_PORT}）")
    sub = parser.add_subparsers(dest="command")

    serve = sub.add_parser("serve", help="启动代理（默认动作）")
    serve.add_argument("--host", help=f"监听地址（默认 {PROXY_HOST}）")

    sub.add_parser("status", help="连通性与已加载模型")

    models = sub.add_parser("models", help="列出模型与加载状态")
    models.add_argument("--json", action="store_true", help="输出原始 JSON")
    models.add_argument(
        "--direct", action="store_true", help="绕过代理，直连 LM Studio"
    )

    load = sub.add_parser("load", help="加载模型（必要时先卸载占用者）")
    load.add_argument("model", help="模型 key，或 auto/vision 使用默认视觉模型")

    unload = sub.add_parser("unload", help="卸载模型")
    unload.add_argument("model", nargs="?", help="模型 key；省略时需加 --all")
    unload.add_argument("--all", action="store_true", help="卸载全部已加载模型")

    ask = sub.add_parser("ask", help="直接向模型提问（可带图片）")
    ask.add_argument("prompt", help="问题文本")
    ask.add_argument("--image", action="append", help="图片路径或 URL，可重复")
    ask.add_argument(
        "--model",
        default="auto",
        help="模型 key，默认 auto（用 LMSTUDIO_VISION_MODEL）",
    )
    ask.add_argument("--max-tokens", type=int, default=512)
    ask.add_argument("--temperature", type=float, default=0.1)
    ask.add_argument("--json", action="store_true", help="输出原始 JSON")

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    global LM_STUDIO_BASE, PROXY_PORT
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.base:
        LM_STUDIO_BASE = args.base.rstrip("/")
    if args.port:
        PROXY_PORT = args.port

    handlers = {
        None: lambda a: run_server(getattr(a, "host", None) or PROXY_HOST, PROXY_PORT),
        "serve": lambda a: run_server(a.host or PROXY_HOST, PROXY_PORT),
        "status": cmd_status,
        "models": cmd_models,
        "load": cmd_load,
        "unload": cmd_unload,
        "ask": cmd_ask,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except LMStudioError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
    except http.client.HTTPException as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
