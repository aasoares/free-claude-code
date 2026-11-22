"""
FCC Claude Proxy Hybrid v1.1 -> NVIDIA Proxy -> NVIDIA NIM

Exposes an Anthropic Messages-compatible endpoint for FCC Server/Claude Code
and translates requests to OpenAI Chat Completions at the local NVIDIA Proxy.

Local endpoint:
    http://127.0.0.1:3456/v1/messages

Upstream:
    http://127.0.0.1:8089/v1/chat/completions

Required environment:
    NVIDIA_PROXY_API_KEY       Key accepted by the local NVIDIA Proxy (or PROXY_API_KEY)
    CLAUDE_PROXY_CLIENT_API_KEY Key required from FCC Server/clients

Optional:
    NVIDIA_PROXY_BASE_URL      default http://127.0.0.1:8089
    NVIDIA_MODEL               default model served by NVIDIA Proxy
    CLAUDE_PROXY_HOST          default 127.0.0.1
    CLAUDE_PROXY_PORT          default 3456

v1.1 Features:
    - Colorful ANSI logging (from server.py)
    - Debug payload dumping (DEBUG_PAYLOADS)
    - Adaptive rate limiting with 429 backoff
    - Exponential retry with jitter + Retry-After parsing
    - Dual semaphore (concurrent + streams)
    - /diagnostics endpoint
    - /v1/messages/count_tokens (tiktoken cl100k_base)
    - Comprehensive health checks
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import sys
import time
import uuid
import random
from datetime import datetime
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator
from pathlib import Path

import httpx
import yaml
from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel

# Load .env from explicit path to ensure it works with Start-Job
ENV_PATH = Path(r"C:\FCC\ClaudeProxy\.env")
load_dotenv(dotenv_path=ENV_PATH, override=True)

APP_NAME = "FCC Claude Proxy Hybrid (NVIDIA upstream)"
VERSION = "1.2.0"
HOST = os.getenv("CLAUDE_PROXY_HOST", "127.0.0.1")
PORT = int(os.getenv("CLAUDE_PROXY_PORT", "3456"))

NVIDIA_PROXY_BASE_URL = os.getenv(
    "NVIDIA_PROXY_BASE_URL", os.getenv("NVIDIA_PROXY_URL", "http://127.0.0.1:10089")
).rstrip("/")
NVIDIA_CHAT_COMPLETIONS_URL = os.getenv(
    "NVIDIA_CHAT_COMPLETIONS_URL",
    f"{NVIDIA_PROXY_BASE_URL}/v1/chat/completions",
)
NVIDIA_MODELS_URL = os.getenv(
    "NVIDIA_MODELS_URL",
    f"{NVIDIA_PROXY_BASE_URL}/v1/models",
)
NVIDIA_PROXY_API_KEY = (
    os.getenv("NVIDIA_PROXY_API_KEY", "").strip()
    or os.getenv("PROXY_API_KEY", "").strip()
)
CLIENT_API_KEY = os.getenv("CLAUDE_PROXY_CLIENT_API_KEY", "").strip()
DEFAULT_MODEL = (
    os.getenv("CLAUDE_PROXY_DEFAULT_MODEL", "").strip()
    or os.getenv("NVIDIA_MODEL", "").strip()
    or "nvidia/nemotron-3-ultra-550b-a55b"
)
AUTH_ENABLED = os.getenv("CLAUDE_PROXY_AUTH_ENABLED", "true").lower() in {
    "1", "true", "yes", "on"
}

# ════════════════════════════════════════════════════════════════════════════════
# NEW v1.2: Model Aliases, Custom Providers, Active Health Checks
# ════════════════════════════════════════════════════════════════════════════════

# Config path
CONFIG_PATH = Path(os.getenv("FCC_CONFIG_PATH", "C:/FCC/ClaudeProxy/config.yaml"))

# Load model aliases from config.yaml
MODEL_ALIASES: dict[str, str] = {}
_model_aliases_lock = asyncio.Lock()

async def load_model_aliases() -> dict[str, str]:
    """Carrega model_aliases do config.yaml."""
    global MODEL_ALIASES
    async with _model_aliases_lock:
        if MODEL_ALIASES:
            return MODEL_ALIASES
        try:
            import yaml
            if CONFIG_PATH.exists():
                with open(CONFIG_PATH) as f:
                    config = yaml.safe_load(f) or {}
                MODEL_ALIASES = config.get("model_aliases", {})
                logger.info(f"Loaded {len(MODEL_ALIASES)} model aliases from config")
            else:
                logger.warning(f"Config not found at {CONFIG_PATH}")
        except Exception as e:
            logger.error(f"Failed to load model aliases: {e}")
        return MODEL_ALIASES

def resolve_model_alias(model: str) -> str:
    """Resolve alias para modelo real (síncrono, usa cache)."""
    return MODEL_ALIASES.get(model, model)

# Custom Providers (estilo free-claude-server)
CUSTOM_PROVIDERS_FILE = Path("data/custom_providers.json")
CUSTOM_PROVIDERS_FILE.parent.mkdir(exist_ok=True)
_custom_providers: dict[str, dict] = {}
_custom_providers_lock = asyncio.Lock()

async def load_custom_providers() -> dict[str, dict]:
    """Carrega custom providers do arquivo JSON."""
    global _custom_providers
    async with _custom_providers_lock:
        if _custom_providers:
            return _custom_providers
        try:
            if CUSTOM_PROVIDERS_FILE.exists():
                with open(CUSTOM_PROVIDERS_FILE) as f:
                    _custom_providers = json.load(f)
                logger.info(f"Loaded {len(_custom_providers)} custom providers")
        except Exception as e:
            logger.error(f"Failed to load custom providers: {e}")
        return _custom_providers

async def save_custom_providers():
    """Salva custom providers no arquivo JSON."""
    async with _custom_providers_lock:
        try:
            with open(CUSTOM_PROVIDERS_FILE, "w") as f:
                json.dump(_custom_providers, f, indent=2, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Failed to save custom providers: {e}")

# Active Health Check (VERIFY_MODEL_LIVENESS)
VERIFY_MODEL_LIVENESS = os.getenv("VERIFY_MODEL_LIVENESS", "false").lower() in {"1", "true", "yes", "on"}
HEALTH_CHECK_TIMEOUT = float(os.getenv("HEALTH_CHECK_TIMEOUT", "10"))
_model_health_cache: dict[str, tuple[bool, float]] = {}  # model_id -> (healthy, timestamp)
_health_cache_ttl = 60  # seconds
_health_cache_lock = asyncio.Lock()

async def check_model_health(model_id: str) -> bool:
    """Verifica saúde ativa de um modelo via request mínimo."""
    cache_key = model_id
    now = time.time()

    async with _health_cache_lock:
        if cache_key in _model_health_cache:
            healthy, cached_at = _model_health_cache[cache_key]
            if now - cached_at < _health_cache_ttl:
                return healthy

    try:
        # Resolve alias first
        real_model = resolve_model_alias(model_id)

        # Make minimal test request to NVIDIA Proxy
        client: httpx.AsyncClient = httpx.AsyncClient(timeout=HEALTH_CHECK_TIMEOUT)
        headers = {"Authorization": f"Bearer {NVIDIA_PROXY_API_KEY}"} if NVIDIA_PROXY_API_KEY else {}
        test_payload = {
            "model": real_model,
            "messages": [{"role": "user", "content": "test"}],
            "max_tokens": 1,
            "stream": False
        }
        resp = await client.post(NVIDIA_CHAT_COMPLETIONS_URL, json=test_payload, headers=headers)
        await client.aclose()
        healthy = resp.status_code == 200
    except Exception as e:
        logger.debug(f"Health check failed for {model_id}: {e}")
        healthy = False

    async with _health_cache_lock:
        _model_health_cache[cache_key] = (healthy, now)

    return healthy

async def get_healthy_models_from_upstream() -> list[dict]:
    """Obtém modelos saudáveis do upstream, filtrando os não saudáveis se VERIFY_MODEL_LIVENESS."""
    try:
        client: httpx.AsyncClient = httpx.AsyncClient(timeout=HEALTH_CHECK_TIMEOUT)
        headers = {"Authorization": f"Bearer {NVIDIA_PROXY_API_KEY}"} if NVIDIA_PROXY_API_KEY else {}
        resp = await client.get(NVIDIA_MODELS_URL, headers=headers)
        await client.aclose()

        if resp.status_code != 200:
            return []

        data = resp.json()
        models = data.get("data", [])

        if VERIFY_MODEL_LIVENESS and models:
            # Filtrar apenas modelos saudáveis
            healthy_models = []
            for m in models:
                model_id = m.get("id", "")
                if await check_model_health(model_id):
                    healthy_models.append(m)
                else:
                    logger.debug(f"Model {model_id} failed health check, excluding from list")
            return healthy_models

        return models
    except Exception as e:
        logger.error(f"Failed to get models from upstream: {e}")
        return []

CONNECT_TIMEOUT = float(os.getenv("CLAUDE_PROXY_CONNECT_TIMEOUT", "20"))
READ_TIMEOUT = float(os.getenv("CLAUDE_PROXY_READ_TIMEOUT", "600"))
WRITE_TIMEOUT = float(os.getenv("CLAUDE_PROXY_WRITE_TIMEOUT", "120"))
POOL_TIMEOUT = float(os.getenv("CLAUDE_PROXY_POOL_TIMEOUT", "30"))
MAX_CONNECTIONS = int(os.getenv("CLAUDE_PROXY_MAX_CONNECTIONS", "100"))
MAX_KEEPALIVE = int(os.getenv("CLAUDE_PROXY_MAX_KEEPALIVE", "20"))
MAX_CONCURRENT = int(os.getenv("CLAUDE_PROXY_MAX_CONCURRENT", "20"))
MAX_STREAMS = max(1, int(os.getenv("CLAUDE_PROXY_MAX_STREAMS", "2")))
MAX_BODY_BYTES = int(os.getenv("CLAUDE_PROXY_MAX_BODY_BYTES", str(20 * 1024 * 1024)))

# Adaptive rate limiting (inspired by FCC/NIM server)
RPM_MAX = max(1, int(os.getenv("CLAUDE_PROXY_RPM_MAX", "40")))
RPM_MIN = max(1, min(RPM_MAX, int(os.getenv("CLAUDE_PROXY_RPM_MIN", "5"))))
RPM_RECOVERY_STEP = max(1, int(os.getenv("CLAUDE_PROXY_RPM_RECOVERY_STEP", "2")))
RPM_DECREASE_FACTOR = min(0.95, max(0.10, float(os.getenv("CLAUDE_PROXY_RPM_DECREASE_FACTOR", "0.75"))))
RPM_RECOVERY_INTERVAL = max(10.0, float(os.getenv("CLAUDE_PROXY_RPM_RECOVERY_INTERVAL", "120")))
HTTP429_THRESHOLD = max(1, int(os.getenv("CLAUDE_PROXY_429_THRESHOLD", "2")))
HTTP429_WINDOW = max(5.0, float(os.getenv("CLAUDE_PROXY_429_WINDOW", "60")))
MIN_INTERVAL = max(0.0, float(os.getenv("CLAUDE_PROXY_MIN_INTERVAL", "1.5")))
MAX_RETRIES = max(0, min(10, int(os.getenv("CLAUDE_PROXY_MAX_RETRIES", "3"))))
RETRY_BASE_DELAY = max(0.1, float(os.getenv("CLAUDE_PROXY_RETRY_BASE_DELAY", "2")))
RETRY_MAX_DELAY = max(RETRY_BASE_DELAY, float(os.getenv("CLAUDE_PROXY_RETRY_MAX_DELAY", "30")))
RETRY_AFTER_MAX = max(1.0, float(os.getenv("CLAUDE_PROXY_RETRY_AFTER_MAX", "120")))

# Logging & Debug
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
DEBUG_PAYLOADS = os.getenv("CLAUDE_PROXY_DEBUG_PAYLOADS", "false").lower() in {
    "1", "true", "yes", "on"
}


# ──────────────────────────────────────────────────────────────────────────────
# COLORFUL LOGGING (from server.py)
# ──────────────────────────────────────────────────────────────────────────────

class ColorFormatter(logging.Formatter):
    """Readable ANSI-colored console logs (works in modern Windows Terminal)."""

    COLORS = {
        logging.DEBUG: "\033[36m",      # cyan
        logging.INFO: "\033[32m",       # green
        logging.WARNING: "\033[33m",    # yellow
        logging.ERROR: "\033[31m",      # red
        logging.CRITICAL: "\033[1;31m", # bold red
    }
    RESET = "\033[0m"
    DIM = "\033[2m"

    def format(self, record: logging.LogRecord) -> str:
        timestamp = self.formatTime(record, "%Y-%m-%d %H:%M:%S")
        color = self.COLORS.get(record.levelno, "")
        level = f"{color}{record.levelname:<8}{self.RESET}"
        name = f"{self.DIM}{record.name}{self.RESET}"
        message = record.getMessage()
        if record.exc_info:
            message += "\n" + self.formatException(record.exc_info)
        return f"{self.DIM}{timestamp}{self.RESET} {level} {name} | {message}"


_console = logging.StreamHandler(sys.stdout)
_console.setFormatter(ColorFormatter())
_root = logging.getLogger()
_root.handlers.clear()
_root.addHandler(_console)
_root.setLevel(getattr(logging, LOG_LEVEL, logging.INFO))
logger = logging.getLogger("FCC.CLAUDE-NVIDIA.HYBRID")
logger.info("Logger initialized | level=%s | payload_dump=%s | version=%s", LOG_LEVEL, DEBUG_PAYLOADS, VERSION)


# ──────────────────────────────────────────────────────────────────────────────
# ERROR RESPONSE & AUTH HELPERS
# ──────────────────────────────────────────────────────────────────────────────

def error_response(
    status: int, message: str, error_type: str = "proxy_error"
) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={
            "type": "error",
            "error": {"type": error_type, "message": message},
        },
    )


def get_client_key(request: Request) -> str:
    key = request.headers.get("x-api-key", "").strip()
    if key:
        return key
    auth = request.headers.get("authorization", "").strip()
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return ""


# ──────────────────────────────────────────────────────────────────────────────
# ANTHROPIC ↔ OPENAI TRANSLATION (shared logic)
# ──────────────────────────────────────────────────────────────────────────────

def map_stop_reason(reason: str | None) -> str:
    return {
        "stop": "end_turn",
        "length": "max_tokens",
        "tool_calls": "tool_use",
        "function_call": "tool_use",
        "content_filter": "end_turn",
    }.get(reason or "", "end_turn")


def anthropic_content_to_openai(content: Any) -> tuple[str | None, list[dict[str, Any]] | None]:
    """Convert Anthropic content blocks into OpenAI-compatible message content."""
    if isinstance(content, str):
        return content, None
    if not isinstance(content, list):
        return str(content) if content is not None else "", None

    parts: list[dict[str, Any]] = []
    text_parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind == "text":
            text_parts.append(str(block.get("text", "")))
        elif kind == "image":
            source = block.get("source") or {}
            if source.get("type") == "base64":
                media_type = source.get("media_type", "image/jpeg")
                data = source.get("data", "")
                parts.append({
                    "type": "image_url",
                    "image_url": {"url": f"data:{media_type};base64,{data}"},
                })
            elif source.get("type") == "url":
                parts.append({
                    "type": "image_url",
                    "image_url": {"url": source.get("url", "")},
                })
        elif kind == "tool_result":
            result_content = block.get("content", "")
            if isinstance(result_content, list):
                result_content = "\n".join(
                    str(x.get("text", "")) for x in result_content
                    if isinstance(x, dict) and x.get("type") == "text"
                )
            text_parts.append(str(result_content))
    if parts:
        if text_parts:
            parts.insert(0, {"type": "text", "text": "\n".join(text_parts)})
        return None, parts
    return "\n".join(text_parts), None


def build_openai_messages(payload: dict[str, Any]) -> list[dict[str, Any]]:
    messages: list[dict[str, Any]] = []
    system = payload.get("system")
    if system:
        if isinstance(system, list):
            system_text = "\n".join(
                str(item.get("text", "")) for item in system
                if isinstance(item, dict) and item.get("type") == "text"
            )
        else:
            system_text = str(system)
        if system_text:
            messages.append({"role": "system", "content": system_text})

    for message in payload.get("messages", []):
        if not isinstance(message, dict):
            continue
        role = message.get("role", "user")
        content = message.get("content", "")

        if isinstance(content, list):
            ordinary_blocks = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    result = block.get("content", "")
                    if isinstance(result, list):
                        result = "\n".join(
                            str(x.get("text", "")) for x in result
                            if isinstance(x, dict) and x.get("type") == "text"
                        )
                    messages.append({
                        "role": "tool",
                        "tool_call_id": block.get("tool_use_id", ""),
                        "content": str(result),
                    })
                else:
                    ordinary_blocks.append(block)
            content, multimodal = anthropic_content_to_openai(ordinary_blocks)
            if multimodal is not None:
                content = multimodal
        else:
            content = str(content)

        msg: dict[str, Any] = {"role": role, "content": content}
        if role == "assistant" and isinstance(message.get("content"), list):
            calls = []
            for block in message["content"]:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    calls.append({
                        "id": block.get("id") or f"call_{uuid.uuid4().hex[:12]}",
                        "type": "function",
                        "function": {
                            "name": block.get("name", "tool"),
                            "arguments": json.dumps(block.get("input", {}), ensure_ascii=False),
                        },
                    })
            if calls:
                msg["tool_calls"] = calls
        messages.append(msg)
    return messages


def build_openai_payload(payload: dict[str, Any]) -> dict[str, Any]:
    model = payload.get("model") or DEFAULT_MODEL
    if str(model).lower().startswith(("claude-", "claude/")):
        model = DEFAULT_MODEL

    result: dict[str, Any] = {
        "model": model,
        "messages": build_openai_messages(payload),
        "max_tokens": int(payload.get("max_tokens", 4096)),
        "stream": bool(payload.get("stream", False)),
    }
    for key in ("temperature", "top_p", "stop"):
        if key in payload:
            result[{"stop": "stop"}[key] if key == "stop" else key] = payload[key]

    tools = payload.get("tools")
    if isinstance(tools, list) and tools:
        result["tools"] = [
            {
                "type": "function",
                "function": {
                    "name": tool.get("name", "tool"),
                    "description": tool.get("description", ""),
                    "parameters": tool.get("input_schema", {
                        "type": "object", "properties": {}
                    }),
                },
            }
            for tool in tools if isinstance(tool, dict)
        ]

    tool_choice = payload.get("tool_choice")
    if isinstance(tool_choice, dict):
        choice_type = tool_choice.get("type")
        if choice_type == "auto":
            result["tool_choice"] = "auto"
        elif choice_type == "any":
            result["tool_choice"] = "required"
        elif choice_type == "tool":
            result["tool_choice"] = {
                "type": "function",
                "function": {"name": tool_choice.get("name", "")},
            }
    elif isinstance(tool_choice, str):
        result["tool_choice"] = tool_choice

    # FASE 4: Anthropic thinking -> OpenAI reasoning_effort translation
    # Anthropic thinking: {"type": "enabled", "budget_tokens": N}
    # OpenAI reasoning_effort: "low" | "medium" | "high"
    # Also pass thinking to NVIDIA Proxy for Ollama think parameter
    thinking = payload.get("thinking")
    if thinking and isinstance(thinking, dict):
        budget = thinking.get("budget_tokens")
        if budget:
            if budget <= 1024:
                result["reasoning_effort"] = "low"
            elif budget <= 4096:
                result["reasoning_effort"] = "medium"
            else:
                result["reasoning_effort"] = "high"
            logger.debug(f"Anthropic thinking budget={budget} -> reasoning_effort={result['reasoning_effort']}")
        else:
            logger.debug("Anthropic thinking parameter omitted; upstream controls reasoning.")
        # Pass thinking to NVIDIA Proxy for Ollama think parameter
        result["thinking"] = thinking

    return result


def openai_response_to_anthropic(data: dict[str, Any], model: str) -> dict[str, Any]:
    # DEBUG: Force visible logging
    print(f"[TRANSLATE DEBUG] model={model} data_keys={list(data.keys())}", flush=True)
    choices = data.get("choices") or []
    choice = choices[0] if choices else {}
    message = choice.get("message") or {}
    print(f"[TRANSLATE DEBUG] message_keys={list(message.keys())} content={repr(message.get('content'))} reasoning={repr(message.get('reasoning_content'))}", flush=True)
    content: list[dict[str, Any]] = []

    # Handle standard content
    text = message.get("content")
    if isinstance(text, str) and text:
        content.append({"type": "text", "text": text})
    elif isinstance(text, list):
        for part in text:
            if isinstance(part, dict) and part.get("type") == "text":
                content.append({"type": "text", "text": part.get("text", "")})

    # Handle reasoning_content (Kimi/NIM-specific)
    reasoning = message.get("reasoning_content")
    print(f"[TRANSLATE DEBUG] reasoning check: isinstance={isinstance(reasoning, str)} reasoning={repr(reasoning)[:50]} content_empty={not content}", flush=True)
    if isinstance(reasoning, str) and reasoning and not content:
        # If no regular content, use reasoning_content as the response
        content.append({"type": "text", "text": reasoning})
        print(f"[TRANSLATE DEBUG] Used reasoning_content: {len(reasoning)} chars", flush=True)

    for call in message.get("tool_calls") or []:
        function = call.get("function") or {}
        try:
            arguments = json.loads(function.get("arguments") or "{}")
        except json.JSONDecodeError:
            arguments = {}
        content.append({
            "type": "tool_use",
            "id": call.get("id") or f"toolu_{uuid.uuid4().hex[:12]}",
            "name": function.get("name", "tool"),
            "input": arguments,
        })

    usage = data.get("usage") or {}
    return {
        "id": data.get("id") or f"msg_{uuid.uuid4().hex}",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": map_stop_reason(choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {
            "input_tokens": int(usage.get("prompt_tokens", 0)),
            "output_tokens": int(usage.get("completion_tokens", 0)),
        },
    }


# ──────────────────────────────────────────────────────────────────────────────
# SSE HELPER
# ──────────────────────────────────────────────────────────────────────────────

def sse(event: str, data: dict[str, Any]) -> bytes:
    return (
        f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
    ).encode("utf-8")


# ──────────────────────────────────────────────────────────────────────────────
# STREAMING TRANSLATION: OpenAI SSE → Anthropic SSE
# ──────────────────────────────────────────────────────────────────────────────

async def anthropic_stream_from_openai(
    upstream: httpx.Response, model: str, request_id: str
) -> AsyncIterator[bytes]:
    message_id = f"msg_{uuid.uuid4().hex}"
    yield sse("message_start", {
        "type": "message_start",
        "message": {
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": None,
            "stop_sequence": None,
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    })

    text_block_started = False
    text_block_index = 0
    tool_blocks: dict[int, dict[str, Any]] = {}
    finish_reason = "stop"
    input_tokens = 0
    output_tokens = 0
    buffer = b""

    try:
        async for chunk in upstream.aiter_bytes():
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                line = line.strip()
                if not line or not line.startswith(b"data:"):
                    continue
                raw = line[5:].strip()
                if raw == b"[DONE]":
                    continue
                try:
                    item = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                usage = item.get("usage") or {}
                input_tokens = int(usage.get("prompt_tokens", input_tokens) or 0)
                output_tokens = int(usage.get("completion_tokens", output_tokens) or 0)

                choices = item.get("choices") or []
                if not choices:
                    continue
                choice = choices[0]
                delta = choice.get("delta") or {}
                if choice.get("finish_reason"):
                    finish_reason = choice["finish_reason"]

                text_delta = delta.get("content")
                if isinstance(text_delta, str) and text_delta:
                    if not text_block_started:
                        yield sse("content_block_start", {
                            "type": "content_block_start",
                            "index": text_block_index,
                            "content_block": {"type": "text", "text": ""},
                        })
                        text_block_started = True
                    yield sse("content_block_delta", {
                        "type": "content_block_delta",
                        "index": text_block_index,
                        "delta": {"type": "text_delta", "text": text_delta},
                    })

                for tool in delta.get("tool_calls") or []:
                    idx = int(tool.get("index", 0))
                    function = tool.get("function") or {}
                    if idx not in tool_blocks:
                        block_index = len(tool_blocks) + (1 if text_block_started else 0)
                        tool_blocks[idx] = {
                            "block_index": block_index,
                            "id": tool.get("id") or f"toolu_{uuid.uuid4().hex[:12]}",
                            "name": function.get("name") or "tool",
                        }
                        yield sse("content_block_start", {
                            "type": "content_block_start",
                            "index": block_index,
                            "content_block": {
                                "type": "tool_use",
                                "id": tool_blocks[idx]["id"],
                                "name": tool_blocks[idx]["name"],
                                "input": {},
                            },
                        })
                    args_fragment = function.get("arguments")
                    if args_fragment:
                        yield sse("content_block_delta", {
                            "type": "content_block_delta",
                            "index": tool_blocks[idx]["block_index"],
                            "delta": {
                                "type": "input_json_delta",
                                "partial_json": args_fragment,
                            },
                        })

        if text_block_started:
            yield sse("content_block_stop", {
                "type": "content_block_stop", "index": text_block_index
            })
        for block in tool_blocks.values():
            yield sse("content_block_stop", {
                "type": "content_block_stop", "index": block["block_index"]
            })

        yield sse("message_delta", {
            "type": "message_delta",
            "delta": {
                "stop_reason": map_stop_reason(finish_reason),
                "stop_sequence": None,
            },
            "usage": {"output_tokens": output_tokens},
        })
        yield sse("message_stop", {"type": "message_stop"})
    except asyncio.CancelledError:
        raise
    except Exception:
        logger.exception("request_id=%s streaming_translation_error", request_id)
        yield sse("error", {
            "type": "error",
            "error": {
                "type": "api_error",
                "message": "Streaming response translation failed.",
            },
        })


# ──────────────────────────────────────────────────────────────────────────────
# ADAPTIVE RATE LIMITER (Process-local RPM with 429 backoff)
# ──────────────────────────────────────────────────────────────────────────────

class AdaptiveRateLimiter:
    """Process-local RPM limiter that backs off after repeated upstream 429s."""

    def __init__(self) -> None:
        self.current_rpm = RPM_MAX
        self.last_admission = 0.0
        self.last_429 = 0.0
        self.last_recovery = time.monotonic()
        self.events_429: list[float] = []
        self.lock = asyncio.Lock()

    async def acquire(self) -> None:
        while True:
            async with self.lock:
                now = time.monotonic()
                self.events_429 = [
                    stamp for stamp in self.events_429
                    if now - stamp <= HTTP429_WINDOW
                ]

                if self.last_429 and now - self.last_429 >= RPM_RECOVERY_INTERVAL:
                    periods = int(
                        (now - max(self.last_recovery, self.last_429))
                        / RPM_RECOVERY_INTERVAL
                    )
                    if periods > 0 and self.current_rpm < RPM_MAX:
                        old = self.current_rpm
                        self.current_rpm = min(
                            RPM_MAX, self.current_rpm + periods * RPM_RECOVERY_STEP
                        )
                        self.last_recovery = now
                        if old != self.current_rpm:
                            logger.info("ADAPTIVE RPM RECOVERY | %d -> %d", old, self.current_rpm)

                interval = max(MIN_INTERVAL, 60.0 / self.current_rpm)
                wait_for = interval - (now - self.last_admission)
                if wait_for <= 0:
                    self.last_admission = now
                    return
            await asyncio.sleep(min(wait_for, 1.0))

    async def on_429(self) -> None:
        async with self.lock:
            now = time.monotonic()
            self.last_429 = now
            self.last_recovery = now
            self.events_429 = [
                stamp for stamp in self.events_429
                if now - stamp <= HTTP429_WINDOW
            ]
            self.events_429.append(now)

            if len(self.events_429) >= HTTP429_THRESHOLD:
                old = self.current_rpm
                reduced = max(RPM_MIN, int(self.current_rpm * RPM_DECREASE_FACTOR))
                if reduced >= self.current_rpm and self.current_rpm > RPM_MIN:
                    reduced = self.current_rpm - 1
                self.current_rpm = max(RPM_MIN, reduced)
                self.events_429.clear()
                logger.warning(
                    "ADAPTIVE RPM DOWN | %d -> %d | min=%d max=%d",
                    old, self.current_rpm, RPM_MIN, RPM_MAX
                )
            else:
                logger.warning(
                    "UPSTREAM HTTP 429 | observations=%d/%d | rpm=%d",
                    len(self.events_429), HTTP429_THRESHOLD, self.current_rpm
                )

    def snapshot(self) -> dict[str, int]:
        return {
            "current": self.current_rpm,
            "minimum": RPM_MIN,
            "maximum": RPM_MAX,
            "min_interval_seconds": MIN_INTERVAL
        }


rate_limiter = AdaptiveRateLimiter()


# ──────────────────────────────────────────────────────────────────────────────
# RETRY HELPERS
# ──────────────────────────────────────────────────────────────────────────────

def get_retry_after_seconds(response: httpx.Response) -> float | None:
    raw = response.headers.get("Retry-After")
    if not raw:
        return None
    try:
        return max(0.0, float(raw.strip()))
    except (TypeError, ValueError):
        try:
            from email.utils import parsedate_to_datetime
            target = parsedate_to_datetime(raw)
            now = datetime.now(target.tzinfo) if target.tzinfo else datetime.now()
            return max(0.0, (target - now).total_seconds())
        except (TypeError, ValueError, OverflowError):
            return None


async def send_upstream_with_retry(
    client: httpx.AsyncClient,
    headers: dict[str, str],
    payload: dict[str, Any],
    request_id: str,
    upstream_url: str | None = None,
) -> httpx.Response:
    """Send a streaming-capable request; retry only 429s before response streaming starts."""
    target_url = upstream_url or NVIDIA_CHAT_COMPLETIONS_URL
    response: httpx.Response | None = None
    for attempt in range(MAX_RETRIES + 1):
        await rate_limiter.acquire()
        logger.info(
            "UPSTREAM SEND | request_id=%s | attempt=%d/%d | model=%s | url=%s | rpm=%s",
            request_id, attempt + 1, MAX_RETRIES + 1,
            payload.get("model"), target_url, rate_limiter.snapshot()
        )
        request = client.build_request(
            "POST", target_url, headers=headers, json=payload
        )
        response = await client.send(request, stream=True)

        if response.status_code != 429:
            return response

        await rate_limiter.on_429()
        if attempt >= MAX_RETRIES:
            logger.error("429 RETRIES EXHAUSTED | request_id=%s", request_id)
            return response

        retry_after = get_retry_after_seconds(response)
        await response.aclose()
        exponential = min(RETRY_BASE_DELAY * (2 ** attempt), RETRY_MAX_DELAY)
        requested_delay = max(exponential, retry_after or 0.0)
        delay = min(requested_delay, RETRY_AFTER_MAX) + random.uniform(0.0, 0.35)
        logger.warning(
            "429 RETRY | request_id=%s | delay=%.2fs | retry_after=%s",
            request_id, delay,
            f"{retry_after:.2f}s" if retry_after is not None else "missing"
        )
        await asyncio.sleep(delay)

    assert response is not None
    return response


# ──────────────────────────────────────────────────────────────────────────────
# LIFESPAN / STARTUP & SHUTDOWN
# ──────────────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    if AUTH_ENABLED and not CLIENT_API_KEY:
        logger.warning("Client authentication enabled but CLAUDE_PROXY_CLIENT_API_KEY is empty.")
    if not NVIDIA_PROXY_API_KEY:
        logger.warning("NVIDIA_PROXY_API_KEY is empty; upstream may reject requests.")

    timeout = httpx.Timeout(
        connect=CONNECT_TIMEOUT,
        read=READ_TIMEOUT,
        write=WRITE_TIMEOUT,
        pool=POOL_TIMEOUT,
    )
    limits = httpx.Limits(
        max_connections=MAX_CONNECTIONS,
        max_keepalive_connections=MAX_KEEPALIVE,
    )
    app.state.http = httpx.AsyncClient(
        timeout=timeout,
        limits=limits,
        follow_redirects=False,
        trust_env=False,
    )
    app.state.semaphore = asyncio.Semaphore(MAX_CONCURRENT)
    app.state.stream_semaphore = asyncio.Semaphore(MAX_STREAMS)

    logger.info("=" * 76)
    logger.info("FCC CLAUDE-COMPATIBLE NVIDIA PROXY HYBRID v%s STARTING", VERSION)
    logger.info("LISTEN  : http://%s:%s", HOST, PORT)
    logger.info("UPSTREAM: %s", NVIDIA_CHAT_COMPLETIONS_URL)
    logger.info("MODELS  : %s", NVIDIA_MODELS_URL)
    logger.info("MODEL   : %s", DEFAULT_MODEL)
    logger.info("AUTH    : client_auth=%s | upstream_key_configured=%s",
                AUTH_ENABLED, bool(NVIDIA_PROXY_API_KEY))
    logger.info("LIMITS  : concurrent=%s | streams=%s | connections=%s | keepalive=%s | body_limit_mb=%.1f",
                MAX_CONCURRENT, MAX_STREAMS, MAX_CONNECTIONS, MAX_KEEPALIVE, MAX_BODY_BYTES / 1024 / 1024)
    logger.info("RATE    : rpm_max=%d | rpm_min=%d | 429_threshold=%d/%ds | recovery=%ds/+%d",
                RPM_MAX, RPM_MIN, HTTP429_THRESHOLD, HTTP429_WINDOW, RPM_RECOVERY_INTERVAL, RPM_RECOVERY_STEP)
    logger.info("RETRY   : max_retries=%d | base_delay=%.1fs | max_delay=%.1fs | retry_after_cap=%.1fs",
                MAX_RETRIES, RETRY_BASE_DELAY, RETRY_MAX_DELAY, RETRY_AFTER_MAX)
    logger.info("DEBUG   : payload_dump=%s | log_level=%s", DEBUG_PAYLOADS, LOG_LEVEL)
    logger.info("=" * 76)

    yield

    logger.info("FCC Claude/NVIDIA Proxy Hybrid v%s shutting down", VERSION)
    await app.state.http.aclose()


# ──────────────────────────────────────────────────────────────────────────────
# FASTAPI APP
# ──────────────────────────────────────────────────────────────────────────────

app = FastAPI(
    title=APP_NAME,
    version=VERSION,
    description="Anthropic Messages-compatible adapter translating requests to NVIDIA Proxy OpenAI Chat Completions.",
    lifespan=lifespan,
)


# ──────────────────────────────────────────────────────────────────────────────
# MIDDLEWARE: AUTH + DETAILED LOGGING
# ──────────────────────────────────────────────────────────────────────────────

@app.middleware("http")
async def authenticate_and_log(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    request.state.request_id = request_id
    start = time.perf_counter()

    logger.debug(
        "[INCOMING] id=%s method=%s path=%s client=%s content_length=%s content_type=%s",
        request_id, request.method, request.url.path,
        request.client.host if request.client else "unknown",
        request.headers.get("content-length", "unknown"),
        request.headers.get("content-type", "unknown"),
    )

    protected = request.url.path.startswith("/v1/")
    if protected and AUTH_ENABLED:
        if not CLIENT_API_KEY:
            logger.error("[AUTH] id=%s blocked: client key is not configured", request_id)
            return error_response(503, "Local client authentication is not configured.", "configuration_error")
        if not secrets.compare_digest(get_client_key(request), CLIENT_API_KEY):
            logger.warning("[AUTH] id=%s rejected: invalid client credential", request_id)
            return error_response(401, "Invalid local proxy API key.", "authentication_error")
        logger.debug("[AUTH] id=%s client authentication accepted", request_id)

    try:
        response = await call_next(request)
    except Exception:
        elapsed = (time.perf_counter() - start) * 1000
        logger.exception("[UNHANDLED] id=%s method=%s path=%s elapsed_ms=%.1f",
                         request_id, request.method, request.url.path, elapsed)
        raise

    response.headers["x-request-id"] = request_id
    elapsed = (time.perf_counter() - start) * 1000
    level = logging.ERROR if response.status_code >= 500 else (
        logging.WARNING if response.status_code >= 400 else logging.INFO
    )
    logger.log(
        level, "[OUTGOING] id=%s method=%s path=%s status=%s elapsed_ms=%.1f response_type=%s",
        request_id, request.method, request.url.path, response.status_code, elapsed,
        response.headers.get("content-type", "unknown"),
    )
    return response


# ──────────────────────────────────────────────────────────────────────────────
# ENDPOINTS
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return {
        "service": APP_NAME,
        "version": VERSION,
        "status": "ok",
        "messages_endpoint": "/v1/messages",
        "models_endpoint": "/v1/models",
        "health_endpoint": "/health",
        "diagnostics_endpoint": "/diagnostics",
        "count_tokens_endpoint": "/v1/messages/count_tokens",
    }


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "service": APP_NAME,
        "version": VERSION,
        "upstream": NVIDIA_PROXY_BASE_URL,
        "upstream_api_key_configured": bool(NVIDIA_PROXY_API_KEY),
        "client_auth_enabled": AUTH_ENABLED,
        "default_model": DEFAULT_MODEL,
        "rate_limit": rate_limiter.snapshot(),
        "max_retries": MAX_RETRIES,
    }


@app.get("/diagnostics")
async def diagnostics():
    """Operational diagnostics without exposing API keys."""
    return {
        "status": "active",
        "service": APP_NAME,
        "version": VERSION,
        "listen": {"host": HOST, "port": PORT},
        "upstream": NVIDIA_PROXY_BASE_URL,
        "model": DEFAULT_MODEL,
        "rate_limit": rate_limiter.snapshot(),
        "retry": {
            "max_retries": MAX_RETRIES,
            "base_delay_seconds": RETRY_BASE_DELAY,
            "max_delay_seconds": RETRY_MAX_DELAY,
            "retry_after_cap_seconds": RETRY_AFTER_MAX,
        },
        "concurrency": {"max_concurrent": MAX_CONCURRENT, "max_streams": MAX_STREAMS},
        "connection_pool": {"max_connections": MAX_CONNECTIONS, "max_keepalive": MAX_KEEPALIVE},
        "timeouts": {
            "connect": CONNECT_TIMEOUT,
            "read": READ_TIMEOUT,
            "write": WRITE_TIMEOUT,
            "pool": POOL_TIMEOUT,
        },
        "body_limit_mb": MAX_BODY_BYTES / 1024 / 1024,
        "auth_enabled": AUTH_ENABLED,
        "debug_payloads": DEBUG_PAYLOADS,
    }


@app.get("/v1/models")
async def list_models(request: Request):
    """
    Lista todos os modelos disponíveis incluindo:
    - Modelos reais do NVIDIA Proxy
    - Modelos do model_registry.json (NIM, Gemini, Ollama)
    - Aliases do config.yaml (ex: qwen, qwen3, deepseek, nemotron)
    - Custom providers registrados via API
    """
    # Carregar aliases se não carregados
    if not MODEL_ALIASES:
        await load_model_aliases()

    # Carregar custom providers
    await load_custom_providers()

    # Obter modelos do upstream (com health check se habilitado)
    upstream_models = await get_healthy_models_from_upstream()

    # Carregar modelos do model_registry.json
    registry_models = await load_model_registry()

    # Construir conjunto de IDs de modelos reais disponíveis (upstream + registry)
    real_model_ids = {m.get("id", "") for m in upstream_models}
    real_model_ids.update(m.get("id", "") for m in registry_models)

    # Adicionar aliases que apontam para modelos reais disponíveis
    alias_models = []
    for alias, target in MODEL_ALIASES.items():
        if target in real_model_ids:
            # Encontrar o modelo real para copiar metadados
            real_model = next((m for m in upstream_models if m.get("id") == target), None)
            if not real_model:
                real_model = next((m for m in registry_models if m.get("id") == target), None)
            if real_model:
                alias_model = real_model.copy()
                alias_model["id"] = alias
                alias_model["owned_by"] = f"alias:{real_model.get('owned_by', 'unknown')}"
                alias_models.append(alias_model)

    # Adicionar custom providers como modelos virtuais
    custom_models = []
    for provider_id, provider_config in _custom_providers.items():
        if provider_config.get("enabled", True):
            for model_id in provider_config.get("model_ids", []):
                custom_models.append({
                    "id": f"custom/{provider_id}/{model_id}",
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": f"custom:{provider_id}",
                    "permission": [],
                    "root": f"custom/{provider_id}/{model_id}",
                    "parent": None,
                })

    # Combinar todos: upstream + registry + aliases + custom
    all_models = upstream_models + registry_models + alias_models + custom_models

    return {
        "object": "list",
        "data": all_models,
    }


async def load_model_registry() -> list[dict]:
    """Carrega modelos do model_registry.json e converte para formato OpenAI."""
    registry_path = Path("data/model_registry.json")
    if not registry_path.exists():
        logger.warning(f"Model registry not found at {registry_path}")
        return []

    try:
        with open(registry_path) as f:
            data = json.load(f)

        entries = data.get("entries", {})
        models = []

        for public_id, entry in entries.items():
            if not entry.get("enabled", True):
                continue

            # Converter para formato OpenAI models
            model = {
                "id": public_id,  # ex: nvidia_nim/bigcode/starcoder2-15b
                "object": "model",
                "created": int(time.time()),
                "owned_by": entry.get("provider_id", "unknown"),
                "permission": [],
                "root": public_id,
                "parent": None,
            }
            models.append(model)

        logger.info(f"Loaded {len(models)} models from model_registry.json")
        return models

    except Exception as e:
        logger.error(f"Failed to load model registry: {e}")
        return []


# ──────────────────────────────────────────────────────────────────────────────
# CUSTOM PROVIDER MANAGEMENT (free-claude-server style)
# ──────────────────────────────────────────────────────────────────────────────

class CustomProviderRequest(BaseModel):
    """Request para registrar/atualizar custom provider."""
    id: str
    name: str
    api_base: str
    api_key: str = ""
    models_endpoint: str = "/models"
    chat_endpoint: str = "/chat/completions"
    timeout: int = 30
    enabled: bool = True
    model_ids: list[str] = []
    headers: dict[str, str] = {}


@app.get("/v1/custom/providers")
async def list_custom_providers(request: Request):
    """Lista todos os custom providers registrados (api_key ocultada)."""
    await load_custom_providers()
    providers = []
    for pid, config in _custom_providers.items():
        safe_config = config.copy()
        if safe_config.get("api_key"):
            safe_config["api_key"] = "***" if safe_config["api_key"] else ""
        providers.append({"id": pid, **safe_config})
    return {"providers": providers}


@app.get("/v1/custom/providers/{provider_id}")
async def get_custom_provider(provider_id: str, request: Request):
    """Obtém detalhes de um custom provider."""
    await load_custom_providers()
    if provider_id not in _custom_providers:
        return error_response(404, f"Custom provider '{provider_id}' not found", "not_found")
    config = _custom_providers[provider_id].copy()
    if config.get("api_key"):
        config["api_key"] = "***" if config["api_key"] else ""
    return {"id": provider_id, **config}


@app.post("/v1/custom/providers")
async def register_custom_provider(provider: CustomProviderRequest, request: Request):
    """Registra um novo custom provider OpenAI-compatível."""
    await load_custom_providers()

    if provider.id in _custom_providers:
        return error_response(409, f"Custom provider '{provider.id}' already exists", "conflict")

    # Validar conectividade (opcional - testar models endpoint)
    try:
        test_client = httpx.AsyncClient(timeout=provider.timeout)
        test_url = f"{provider.api_base.rstrip('/')}{provider.models_endpoint}"
        headers = {"Accept": "application/json"}
        if provider.api_key:
            headers["Authorization"] = f"Bearer {provider.api_key}"
        headers.update(provider.headers)

        resp = await test_client.get(test_url, headers=headers)
        await test_client.aclose()

        if resp.status_code != 200:
            logger.warning(f"Custom provider {provider.id} test returned {resp.status_code}")
    except Exception as e:
        logger.warning(f"Custom provider {provider.id} connectivity test failed: {e}")
        # Não bloqueia registro - permite registrar mesmo se teste falhar

    config = provider.model_dump()
    _custom_providers[provider.id] = config
    await save_custom_providers()

    logger.info(f"Registered custom provider: {provider.id} ({provider.name})")
    return {"id": provider.id, "status": "registered", **config}


@app.put("/v1/custom/providers/{provider_id}")
async def update_custom_provider(provider_id: str, provider: CustomProviderRequest, request: Request):
    """Atualiza um custom provider existente."""
    await load_custom_providers()

    if provider_id not in _custom_providers:
        return error_response(404, f"Custom provider '{provider_id}' not found", "not_found")

    # Preservar api_key se não fornecida na atualização
    if not provider.api_key and _custom_providers[provider_id].get("api_key"):
        provider.api_key = _custom_providers[provider_id]["api_key"]

    config = provider.model_dump()
    _custom_providers[provider_id] = config
    await save_custom_providers()

    logger.info(f"Updated custom provider: {provider_id}")
    return {"id": provider_id, "status": "updated", **config}


@app.delete("/v1/custom/providers/{provider_id}")
async def unregister_custom_provider(provider_id: str, request: Request):
    """Remove um custom provider."""
    await load_custom_providers()

    if provider_id not in _custom_providers:
        return error_response(404, f"Custom provider '{provider_id}' not found", "not_found")

    del _custom_providers[provider_id]
    await save_custom_providers()

    logger.info(f"Unregistered custom provider: {provider_id}")
    return {"status": "deleted", "id": provider_id}


@app.post("/v1/custom/providers/{provider_id}/discover")
async def discover_custom_provider_models(provider_id: str, request: Request):
    """Força descoberta de modelos de um custom provider."""
    await load_custom_providers()

    if provider_id not in _custom_providers:
        return error_response(404, f"Custom provider '{provider_id}' not found", "not_found")

    config = _custom_providers[provider_id]
    try:
        test_client = httpx.AsyncClient(timeout=config.get("timeout", 30))
        test_url = f"{config['api_base'].rstrip('/')}{config.get('models_endpoint', '/models')}"
        headers = {"Accept": "application/json"}
        if config.get("api_key"):
            headers["Authorization"] = f"Bearer {config['api_key']}"
        headers.update(config.get("headers", {}))

        resp = await test_client.get(test_url, headers=headers)
        await test_client.aclose()

        if resp.status_code != 200:
            return error_response(502, f"Failed to discover models: HTTP {resp.status_code}", "upstream_error")

        data = resp.json()
        models = []
        for item in data.get("data", []):
            model_id = item.get("id", "")
            if model_id:
                # Se model_ids configurado, filtrar
                if config.get("model_ids") and model_id not in config["model_ids"]:
                    continue
                models.append({
                    "id": f"custom/{provider_id}/{model_id}",
                    "object": "model",
                    "created": int(time.time()),
                    "owned_by": f"custom:{provider_id}",
                    "display_name": model_id,
                })

        return {"provider_id": provider_id, "discovered": len(models), "models": models}
    except Exception as e:
        logger.error(f"Discovery failed for {provider_id}: {e}")
        return error_response(500, f"Discovery failed: {str(e)}", "internal_error")


@app.post("/v1/messages/count_tokens")
async def count_message_tokens(request: Request):
    """Approximate Anthropic-compatible input token count (not provider tokenizer billing)."""
    try:
        body = await request.body()
        if len(body) > MAX_BODY_BYTES:
            return error_response(413, "Request body is too large.", "request_too_large")
        payload = json.loads(body or b"{}")
        if not isinstance(payload, dict):
            return error_response(400, "JSON body must be an object.", "invalid_request_error")
    except (json.JSONDecodeError, UnicodeDecodeError):
        return error_response(400, "Invalid JSON request body.", "invalid_request_error")

    serializable = {
        "messages": build_openai_messages(payload),
        "tools": payload.get("tools") or [],
        "system": payload.get("system") or "",
    }
    serialized = json.dumps(serializable, ensure_ascii=False, separators=(",", ":"))
    try:
        import tiktoken
        encoding = tiktoken.get_encoding("cl100k_base")
        count = max(1, len(encoding.encode(serialized, disallowed_special=())))
    except Exception:
        count = max(1, (len(serialized.encode("utf-8")) + 3) // 4)

    return {"input_tokens": count}


@app.post("/v1/messages")
async def messages(request: Request):
    try:
        body = await request.body()
        if len(body) > MAX_BODY_BYTES:
            return error_response(413, "Request body is too large.", "request_too_large")
        payload = json.loads(body or b"{}")
        if not isinstance(payload, dict):
            return error_response(400, "JSON body must be an object.", "invalid_request_error")
    except (json.JSONDecodeError, UnicodeDecodeError):
        return error_response(400, "Invalid JSON request body.", "invalid_request_error")

    # Garantir que aliases estejam carregados
    if not MODEL_ALIASES:
        await load_model_aliases()

    # Resolve model alias ANTES de construir payload OpenAI
    requested_model = payload.get("model", DEFAULT_MODEL)
    resolved_model = resolve_model_alias(requested_model)
    if resolved_model != requested_model:
        payload["model"] = resolved_model
        logger.debug(f"Model alias resolved: {requested_model} -> {resolved_model}")

    openai_payload = build_openai_payload(payload)
    model = str(openai_payload["model"])
    message_list = openai_payload.get("messages", [])
    tool_list = openai_payload.get("tools", [])

    # Verificar se é modelo de custom provider (formato: custom/{provider_id}/{model_id})
    logger.debug(f"[ROUTING] model='{model}', is_custom_provider={model.startswith('custom/')}")
    is_custom_provider = model.startswith("custom/")
    custom_provider_config = None
    upstream_url = NVIDIA_CHAT_COMPLETIONS_URL
    upstream_headers = {
        "Authorization": f"Bearer {NVIDIA_PROXY_API_KEY}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream" if openai_payload.get("stream") else "application/json",
        "X-Request-ID": request.state.request_id,
    }

    if is_custom_provider:
        # Parse: custom/{provider_id}/{model_id}
        parts = model.split("/", 2)
        if len(parts) == 3:
            provider_id = parts[1]
            actual_model = parts[2]
            await load_custom_providers()
            if provider_id in _custom_providers:
                custom_provider_config = _custom_providers[provider_id]
                upstream_url = f"{custom_provider_config['api_base'].rstrip('/')}{custom_provider_config.get('chat_endpoint', '/chat/completions')}"
                upstream_headers = {
                    "Content-Type": "application/json",
                    "Accept": "text/event-stream" if openai_payload.get("stream") else "application/json",
                    "X-Request-ID": request.state.request_id,
                }
                if custom_provider_config.get("api_key"):
                    upstream_headers["Authorization"] = f"Bearer {custom_provider_config['api_key']}"
                upstream_headers.update(custom_provider_config.get("headers", {}))
                openai_payload["model"] = actual_model
                logger.info(f"Routing to custom provider: {provider_id} -> {upstream_url} (model: {actual_model})")
            else:
                logger.error(f"Custom provider not found: {provider_id}")
                return error_response(404, f"Custom provider '{provider_id}' not found", "not_found")
        else:
            logger.error(f"Invalid custom provider model format: {model}")
            return error_response(400, f"Invalid custom provider model format: {model}", "invalid_request_error")

    if not is_custom_provider and not NVIDIA_PROXY_API_KEY:
        return error_response(503, "NVIDIA_PROXY_API_KEY is not configured.", "configuration_error")

    semaphore: asyncio.Semaphore = request.app.state.semaphore
    stream_semaphore: asyncio.Semaphore = request.app.state.stream_semaphore
    client: httpx.AsyncClient = request.app.state.http

    stream_slot_acquired = False
    semaphore_acquired = False

    try:
        await semaphore.acquire()
        semaphore_acquired = True

        if openai_payload.get("stream"):
            await stream_semaphore.acquire()
            stream_slot_acquired = True

        upstream = await send_upstream_with_retry(
            client, upstream_headers, openai_payload, request.state.request_id, upstream_url
        )

    except httpx.TimeoutException:
        if stream_slot_acquired:
            stream_semaphore.release()
        if semaphore_acquired:
            semaphore.release()
        logger.error("[TIMEOUT] id=%s upstream timed out after read_timeout=%ss",
                     request.state.request_id, READ_TIMEOUT)
        return error_response(504, "NVIDIA Proxy request timed out.", "timeout_error")
    except httpx.RequestError as exc:
        if stream_slot_acquired:
            stream_semaphore.release()
        if semaphore_acquired:
            semaphore.release()
        logger.exception("[CONNECTION-ERROR] id=%s upstream_error=%s",
                         request.state.request_id, type(exc).__name__)
        return error_response(502, "Could not connect to NVIDIA Proxy on the configured endpoint.", "upstream_error")
    except Exception:
        if stream_slot_acquired:
            stream_semaphore.release()
        if semaphore_acquired:
            semaphore.release()
        logger.exception("request_id=%s proxy_request_error", request.state.request_id)
        return error_response(500, "Unexpected proxy error.")

    if upstream.status_code >= 400:
        try:
            content = await upstream.aread()
            logger.error("[UPSTREAM-ERROR] id=%s status=%s body=%s",
                         request.state.request_id, upstream.status_code,
                         content[:3000].decode("utf-8", errors="replace"))
            return Response(
                content=content,
                status_code=upstream.status_code,
                media_type=upstream.headers.get("content-type", "application/json"),
            )
        finally:
            await upstream.aclose()
            if stream_slot_acquired:
                stream_semaphore.release()
            semaphore.release()

    wants_stream = bool(openai_payload.get("stream"))
    if wants_stream:
        async def stream_and_release() -> AsyncIterator[bytes]:
            try:
                async for event in anthropic_stream_from_openai(
                    upstream, model, request.state.request_id
                ):
                    yield event
            finally:
                await upstream.aclose()
                if stream_slot_acquired:
                    stream_semaphore.release()
                semaphore.release()

        return StreamingResponse(
            stream_and_release(),
            media_type="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "Connection": "keep-alive",
                "x-request-id": request.state.request_id,
            },
        )

    try:
        raw = await upstream.aread()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            return error_response(502, "NVIDIA Proxy returned invalid JSON.", "upstream_error")

        translated = openai_response_to_anthropic(data, model)

        logger.info(
            "[TRANSLATED] id=%s response_id=%s stop_reason=%s input_tokens=%s output_tokens=%s blocks=%s",
            request.state.request_id, translated.get("id"), translated.get("stop_reason"),
            translated.get("usage", {}).get("input_tokens"),
            translated.get("usage", {}).get("output_tokens"),
            len(translated.get("content", [])),
        )
        if DEBUG_PAYLOADS:
            logger.debug("[RESPONSE-PAYLOAD] id=%s payload=%s",
                         request.state.request_id,
                         json.dumps(translated, ensure_ascii=False, default=str))

        return JSONResponse(content=translated, status_code=200)
    finally:
        await upstream.aclose()
        if stream_slot_acquired:
            stream_semaphore.release()
        semaphore.release()


# ──────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ──────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    # Windows fix: use string import to avoid double-bind on Windows
    # uvicorn imports the module fresh, avoiding double execution of __main__
    uvicorn.run(
        "hybrid:app",
        host=HOST,
        port=PORT,
        reload=False,
        access_log=False,
        proxy_headers=False,
        loop="asyncio",
    )