"""
VRAM-Aware Scheduler for Ollama Vulkan (GTX 1060 6GB)

Implements tiered concurrency strategy:
- heavy: single-load only (~4-5GB each) - qwen2.5-coder:7b, qwen3:8b, deepseek-coder:6.7b
- light: dual-load OK (~0.4-1.5GB each) - qwen2.5:0.5b, tinyllama:1.1b, qwen2.5-coder:1.5b
- micro: quad-load OK (~0.2-0.5GB each) - future smaller models

Features:
- VRAM tracking with safety margin
- LRU auto-offload when VRAM pressure
- Health-aware model loading
- Integration with config.yaml model profiles
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from enum import Enum

import yaml

logger = logging.getLogger("FCC.VRAM.Scheduler")


class ConcurrencyTier(str, Enum):
    """Tiers de concorrência baseados em uso de VRAM."""
    HEAVY = "heavy"      # 1 modelo por vez (~4-5GB)
    LIGHT = "light"      # 2 modelos simultâneos (~1-1.5GB cada)
    MICRO = "micro"      # 4 modelos simultâneos (~0.2-0.5GB cada)


@dataclass
class ModelProfile:
    """Perfil de modelo com requisitos de VRAM e concorrência."""
    model_id: str
    concurrency_tier: ConcurrencyTier = ConcurrencyTier.HEAVY
    vram_mb: int = 4000
    max_loaded_models: int = 1
    num_gpu: int = 999
    quantization: str = "Q4_K_M"
    flash_attention: bool = True
    kv_cache_quant: str = "Q8_0"
    description: str = ""

    # Runtime state
    loaded: bool = False
    loaded_at: float = 0.0
    last_used: float = 0.0
    current_requests: int = 0

    def can_load_with(self, other: ModelProfile, vram_total: int, vram_margin: int) -> bool:
        """Verifica se este modelo pode carregar junto com outro."""
        return (self.vram_mb + other.vram_mb + vram_margin) <= vram_total

    def max_concurrent_for_tier(self) -> int:
        """Retorna max concorrência baseada no tier."""
        return {
            ConcurrencyTier.HEAVY: 1,
            ConcurrencyTier.LIGHT: 2,
            ConcurrencyTier.MICRO: 4,
        }.get(self.concurrency_tier, 1)


@dataclass
class VRAMState:
    """Estado atual de VRAM."""
    total_mb: int
    used_mb: int = 0
    safety_margin_mb: int = 500
    loaded_models: dict[str, ModelProfile] = field(default_factory=dict)

    @property
    def free_mb(self) -> int:
        return self.total_mb - self.used_mb

    @property
    def available_for_load(self) -> int:
        return max(0, self.free_mb - self.safety_margin_mb)

    def can_load(self, model: ModelProfile) -> bool:
        return self.available_for_load >= model.vram_mb

    def load_model(self, model: ModelProfile):
        self.loaded_models[model.model_id] = model
        self.used_mb += model.vram_mb
        model.loaded = True
        model.loaded_at = time.time()
        logger.info(f"VRAM: loaded {model.model_id} (+{model.vram_mb}MB) | used={self.used_mb}MB free={self.free_mb}MB")

    def unload_model(self, model_id: str) -> bool:
        if model_id in self.loaded_models:
            model = self.loaded_models.pop(model_id)
            self.used_mb -= model.vram_mb
            model.loaded = False
            logger.info(f"VRAM: unloaded {model_id} (-{model.vram_mb}MB) | used={self.used_mb}MB free={self.free_mb}MB")
            return True
        return False

    def touch_model(self, model_id: str):
        if model_id in self.loaded_models:
            self.loaded_models[model_id].last_used = time.time()
            self.loaded_models[model_id].current_requests += 1

    def release_model(self, model_id: str):
        if model_id in self.loaded_models:
            self.loaded_models[model_id].current_requests = max(0, self.loaded_models[model_id].current_requests - 1)


class VRAMScheduler:
    """
    Scheduler VRAM-aware para Ollama Vulkan.

    Gerencia carregamento/descarregamento de modelos baseado em:
    - VRAM disponível (com safety margin)
    - Tier de concorrência do modelo
    - Política LRU para offload automático
    """

    def __init__(
        self,
        config_path: str | Path = "C:/FCC/ClaudeProxy/config.yaml",
        ollama_base_url: str = "http://localhost:11434",
    ):
        self.config_path = Path(config_path)
        self.ollama_base_url = ollama_base_url.rstrip("/")
        self.profiles: dict[str, ModelProfile] = {}
        self.state = VRAMState(total_mb=5500, safety_margin_mb=500)
        self._lock = asyncio.Lock()
        self._load_config()

    def _load_config(self):
        """Carrega perfis de modelos do config.yaml."""
        try:
            if self.config_path.exists():
                with open(self.config_path) as f:
                    config = yaml.safe_load(f) or {}

                ollama_config = config.get("ollama_instances", [{}])[0]
                self.state.total_mb = ollama_config.get("vram_total_mb", 5500)
                self.state.safety_margin_mb = ollama_config.get("vram_safety_margin_mb", 500)

                per_model = ollama_config.get("per_model_config", {})
                for model_id, cfg in per_model.items():
                    tier_str = cfg.get("concurrency_tier", "heavy")
                    try:
                        tier = ConcurrencyTier(tier_str)
                    except ValueError:
                        tier = ConcurrencyTier.HEAVY

                    profile = ModelProfile(
                        model_id=model_id,
                        concurrency_tier=tier,
                        vram_mb=cfg.get("vram_mb", 4000),
                        max_loaded_models=cfg.get("max_loaded_models", 1),
                        num_gpu=cfg.get("num_gpu", 999),
                        quantization=cfg.get("quantization", "Q4_K_M"),
                        flash_attention=cfg.get("flash_attention", True),
                        kv_cache_quant=cfg.get("kv_cache_quant", "Q8_0"),
                        description=cfg.get("description", ""),
                    )
                    self.profiles[model_id] = profile

                logger.info(f"VRAM Scheduler: loaded {len(self.profiles)} model profiles | VRAM={self.state.total_mb}MB margin={self.state.safety_margin_mb}MB")
        except Exception as e:
            logger.error(f"Failed to load VRAM scheduler config: {e}")

    def get_profile(self, model_id: str) -> ModelProfile | None:
        return self.profiles.get(model_id)

    def get_all_profiles(self) -> dict[str, ModelProfile]:
        return self.profiles.copy()

    async def acquire_model(self, model_id: str) -> bool:
        """
        Adquire um modelo para uso. Carrega se necessário, faz offload LRU se preciso.
        Retorna True se modelo está disponível para uso.
        """
        async with self._lock:
            profile = self.profiles.get(model_id)
            if not profile:
                logger.warning(f"VRAM: model {model_id} not in profiles, allowing anyway")
                return True

            # Já carregado?
            if profile.loaded and model_id in self.state.loaded_models:
                self.state.touch_model(model_id)
                return True

            # Verifica se pode carregar diretamente
            if self.state.can_load(profile):
                await self._load_model_via_ollama(model_id, profile)
                self.state.load_model(profile)
                self.state.touch_model(model_id)
                return True

            # Precisa fazer offload LRU
            if await self._make_room_for(profile):
                await self._load_model_via_ollama(model_id, profile)
                self.state.load_model(profile)
                self.state.touch_model(model_id)
                return True

            logger.error(f"VRAM: cannot load {model_id} (need {profile.vram_mb}MB, available {self.state.available_for_load}MB)")
            return False

    async def release_model(self, model_id: str):
        """Libera modelo após uso. Não descarrega imediatamente (keep-alive)."""
        async with self._lock:
            self.state.release_model(model_id)
            # Keep-alive: modelo fica carregado por 5min (configurável)
            # Offload real acontece via _make_room_for ou cleanup task

    async def _make_room_for(self, target: ModelProfile) -> bool:
        """Tenta liberar VRAM descarregando modelos LRU até caber o target."""
        # Candidatos: modelos carregados que não estão em uso (current_requests == 0)
        candidates = [
            (p.last_used, m_id) for m_id, p in self.state.loaded_models.items()
            if p.current_requests == 0 and m_id != target.model_id
        ]
        candidates.sort()  # LRU first (oldest last_used)

        for _, model_id in candidates:
            if self.state.can_load(target):
                return True
            # Descarrega via Ollama API
            await self._unload_model_via_ollama(model_id)
            self.state.unload_model(model_id)

        return self.state.can_load(target)

    async def _load_model_via_ollama(self, model_id: str, profile: ModelProfile):
        """Carrega modelo no Ollama via API (define num_gpu, etc)."""
        try:
            import httpx
            async with httpx.AsyncClient(timeout=30.0) as client:
                # Ollama carrega modelo automaticamente no primeiro request
                # Mas podemos fazer warmup com num_predict=1
                payload = {
                    "model": model_id,
                    "prompt": " ",
                    "stream": False,
                    "options": {
                        "num_gpu": profile.num_gpu,
                        "num_predict": 1,
                        "flash_attention": profile.flash_attention,
                    }
                }
                resp = await client.post(f"{self.ollama_base_url}/api/generate", json=payload)
                if resp.status_code == 200:
                    logger.info(f"VRAM: warmed up {model_id} (num_gpu={profile.num_gpu})")
                else:
                    logger.warning(f"VRAM: warmup {model_id} returned {resp.status_code}")
        except Exception as e:
            logger.error(f"VRAM: failed to warmup {model_id}: {e}")

    async def _unload_model_via_ollama(self, model_id: str):
        """Descarrega modelo do Ollama (keep_alive=0)."""
        try:
            import httpx
            async with httpx.AsyncClient(timeout=10.0) as client:
                payload = {"model": model_id, "keep_alive": 0}
                resp = await client.post(f"{self.ollama_base_url}/api/generate", json=payload)
                if resp.status_code == 200:
                    logger.info(f"VRAM: unloaded {model_id} from Ollama")
        except Exception as e:
            logger.error(f"VRAM: failed to unload {model_id}: {e}")

    async def get_status(self) -> dict[str, Any]:
        """Retorna status atual do scheduler."""
        async with self._lock:
            return {
                "vram_total_mb": self.state.total_mb,
                "vram_used_mb": self.state.used_mb,
                "vram_free_mb": self.state.free_mb,
                "vram_available_for_load_mb": self.state.available_for_load,
                "safety_margin_mb": self.state.safety_margin_mb,
                "loaded_models": {
                    m_id: {
                        "model_id": p.model_id,
                        "vram_mb": p.vram_mb,
                        "tier": p.concurrency_tier.value,
                        "loaded_at": p.loaded_at,
                        "last_used": p.last_used,
                        "current_requests": p.current_requests,
                    }
                    for m_id, p in self.state.loaded_models.items()
                },
                "profiles": {
                    m_id: {
                        "vram_mb": p.vram_mb,
                        "tier": p.concurrency_tier.value,
                        "max_concurrent": p.max_concurrent_for_tier(),
                        "num_gpu": p.num_gpu,
                    }
                    for m_id, p in self.profiles.items()
                }
            }

    async def cleanup_idle(self, idle_timeout_seconds: int = 300):
        """Descarrega modelos ociosos (keep-alive expirado)."""
        async with self._lock:
            now = time.time()
            to_unload = [
                m_id for m_id, p in self.state.loaded_models.items()
                if p.current_requests == 0 and (now - p.last_used) > idle_timeout_seconds
            ]
            for model_id in to_unload:
                await self._unload_model_via_ollama(model_id)
                self.state.unload_model(model_id)


# Instância global (singleton pattern)
_scheduler: VRAMScheduler | None = None


def get_vram_scheduler(config_path: str | Path = "C:/FCC/ClaudeProxy/config.yaml") -> VRAMScheduler:
    """Retorna instância singleton do VRAM Scheduler."""
    global _scheduler
    if _scheduler is None:
        _scheduler = VRAMScheduler(config_path)
    return _scheduler


async def startup_vram_scheduler(config_path: str | Path = "C:/FCC/ClaudeProxy/config.yaml"):
    """Inicializa scheduler na startup da aplicação."""
    global _scheduler
    _scheduler = VRAMScheduler(config_path)
    logger.info("VRAM Scheduler initialized")


async def shutdown_vram_scheduler():
    """Descarrega todos os modelos no shutdown."""
    global _scheduler
    if _scheduler:
        for model_id in list(_scheduler.state.loaded_models.keys()):
            await _scheduler._unload_model_via_ollama(model_id)
        _scheduler.state.loaded_models.clear()
        _scheduler.state.used_mb = 0
        logger.info("VRAM Scheduler shutdown complete")