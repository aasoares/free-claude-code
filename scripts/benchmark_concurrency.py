#!/usr/bin/env python3
"""
Benchmark de Concorrência VRAM-Aware para Ollama Vulkan (GTX 1060 6GB)

Testa combinações válidas de modelos e mede:
- Throughput (req/s)
- Latência p50/p95/p99
- Taxa de OOM
- Tempo de swap de modelos
- Uso de VRAM
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import statistics
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

import httpx
import yaml

# Configurar logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s"
)
logger = logging.getLogger("FCC.Benchmark.Concurrency")

OLLAMA_URL = "http://localhost:11434"
HYBRID_URL = "http://127.0.0.1:8082"


# ──────────────────────────────────────────────────────────────────────────────
# TEST MATRIX - Combinações válidas baseadas em VRAM real (GTX 1060 6GB)
# ──────────────────────────────────────────────────────────────────────────────

TEST_COMBINATIONS = [
    # (model_a, model_b, expected_vram_mb, should_work, description)
    ("qwen2.5-coder:7b", "qwen2.5:0.5b", 4600, True, "Heavy + Light"),
    ("qwen3:8b-gpu90", "tinyllama:1.1b", 5500, True, "Heavy + Light (reasoning)"),
    ("deepseek-coder:6.7b", "qwen2.5-coder:1.5b", 5000, True, "Heavy + Light"),
    ("qwen2.5:0.5b", "tinyllama:1.1b", 1100, True, "Light + Light (max concurrency)"),
    ("qwen2.5-coder:1.5b", "qwen2.5:0.5b", 1400, True, "Light + Light"),
    ("qwen2.5-coder:7b", "qwen3:8b-gpu90", 9000, False, "Heavy + Heavy -> OOM"),
    ("qwen2.5-coder:7b", "deepseek-coder:6.7b", 8200, False, "Heavy + Heavy -> OOM"),
]


@dataclass
class BenchmarkResult:
    """Resultado de um teste de benchmark."""
    model_a: str
    model_b: str
    combination: str
    should_work: bool
    expected_vram_mb: int

    # Métricas
    total_requests: int = 0
    successful_requests: int = 0
    failed_requests: int = 0
    oom_errors: int = 0
    timeout_errors: int = 0
    other_errors: int = 0

    # Latência (ms)
    latency_p50: float = 0.0
    latency_p95: float = 0.0
    latency_p99: float = 0.0
    latency_mean: float = 0.0
    latency_max: float = 0.0

    # Throughput
    duration_seconds: float = 0.0
    throughput_rps: float = 0.0

    # VRAM
    peak_vram_mb: int = 0
    avg_vram_mb: int = 0

    # Model swap
    swap_count: int = 0
    avg_swap_time_ms: float = 0.0

    def to_dict(self) -> dict:
        return asdict(self)


class ConcurrencyBenchmark:
    """Benchmark de concorrência para modelos Ollama."""

    def __init__(
        self,
        ollama_url: str = OLLAMA_URL,
        hybrid_url: str = HYBRID_URL,
        concurrent_requests: int = 10,
        total_requests: int = 50,
        prompt: str = "Escreva uma função Python que calcula fibonacci de forma eficiente.",
    ):
        self.ollama_url = ollama_url
        self.hybrid_url = hybrid_url
        self.concurrent_requests = concurrent_requests
        self.total_requests = total_requests
        self.prompt = prompt
        self.results: list[BenchmarkResult] = []

    async def _check_model_exists(self, model: str) -> bool:
        """Verifica se modelo existe no Ollama."""
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.get(f"{self.ollama_url}/api/tags")
                if resp.status_code == 200:
                    models = [m["name"] for m in resp.json().get("models", [])]
                    return model in models
        except Exception:
            pass
        return False

    async def _ensure_model(self, model: str) -> bool:
        """Garante que modelo está disponível (pull se necessário)."""
        if await self._check_model_exists(model):
            return True
        logger.info(f"Pulling model {model}...")
        try:
            async with httpx.AsyncClient(timeout=300.0) as client:
                resp = await client.post(
                    f"{self.ollama_url}/api/pull",
                    json={"name": model, "stream": False}
                )
                return resp.status_code == 200
        except Exception as e:
            logger.error(f"Failed to pull {model}: {e}")
            return False

    async def _unload_model(self, model: str):
        """Descarrega modelo (keep_alive=0)."""
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                await client.post(f"{self.ollama_url}/api/generate", json={"model": model, "keep_alive": 0})
        except Exception:
            pass

    async def _warmup_model(self, model: str):
        """Warmup rápido do modelo."""
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                await client.post(f"{self.ollama_url}/api/generate", json={
                    "model": model,
                    "prompt": "test",
                    "stream": False,
                    "options": {"num_predict": 1}
                })
        except Exception:
            pass

    async def _make_request(self, model: str, semaphore: asyncio.Semaphore) -> tuple[bool, float, str]:
        """Faz uma request única e retorna (success, latency_ms, error_type)."""
        async with semaphore:
            start = time.perf_counter()
            try:
                async with httpx.AsyncClient(timeout=120.0) as client:
                    # Usar Hybrid Proxy para testar rota completa
                    resp = await client.post(
                        f"{self.hybrid_url}/v1/messages",
                        headers={"Content-Type": "application/json", "x-api-key": "local-proxy"},
                        json={
                            "model": f"ollama/{model}",
                            "messages": [{"role": "user", "content": self.prompt}],
                            "max_tokens": 100,
                            "stream": False,
                        }
                    )
                    latency = (time.perf_counter() - start) * 1000
                    if resp.status_code == 200:
                        return True, latency, ""
                    elif "out of memory" in resp.text.lower() or "oom" in resp.text.lower():
                        return False, latency, "oom"
                    else:
                        return False, latency, f"http_{resp.status_code}"
            except httpx.TimeoutException:
                return False, (time.perf_counter() - start) * 1000, "timeout"
            except Exception as e:
                return False, (time.perf_counter() - start) * 1000, str(e)

    async def _get_vram_usage(self) -> int:
        """Obtém uso de VRAM via nvidia-smi (se disponível)."""
        try:
            import subprocess
            result = subprocess.run(
                ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                return int(result.stdout.strip().split("\n")[0])
        except Exception:
            pass
        return 0

    async def run_combination(self, model_a: str, model_b: str, expected_vram: int, should_work: bool, description: str) -> BenchmarkResult:
        """Executa benchmark para uma combinação de modelos."""
        logger.info(f"\n{'='*60}")
        logger.info(f"TESTING: {model_a} + {model_b} ({description})")
        logger.info(f"Expected VRAM: {expected_vram}MB | Should work: {should_work}")
        logger.info(f"{'='*60}")

        result = BenchmarkResult(
            model_a=model_a,
            model_b=model_b,
            combination=description,
            should_work=should_work,
            expected_vram_mb=expected_vram,
        )

        # Garantir modelos disponíveis
        for m in [model_a, model_b]:
            if not await self._ensure_model(m):
                logger.error(f"Model {m} not available, skipping")
                result.failed_requests = self.total_requests
                return result

        # Warmup
        logger.info("Warming up models...")
        await self._warmup_model(model_a)
        await self._warmup_model(model_b)

        # Semaphore para controle de concorrência
        semaphore = asyncio.Semaphore(self.concurrent_requests)

        # Executar requests alternando entre modelos
        latencies: list[float] = []
        vram_samples: list[int] = []
        swap_count = 0
        swap_times: list[float] = []
        last_model = None

        start_time = time.perf_counter()

        async def worker(model: str):
            nonlocal swap_count, last_model
            swap_start = None
            if model != last_model and last_model is not None:
                swap_start = time.perf_counter()
                swap_count += 1
            success, latency, error = await self._make_request(model, semaphore)
            if swap_start:
                swap_times.append((time.perf_counter() - swap_start) * 1000)
            return success, latency, error

        # Distribuir requests entre os dois modelos
        tasks = []
        for i in range(self.total_requests):
            model = model_a if i % 2 == 0 else model_b
            tasks.append(worker(model))

            # Sample VRAM periodically
            if i % 5 == 0:
                vram = await self._get_vram_usage()
                if vram > 0:
                    vram_samples.append(vram)

        # Executar com concorrência controlada
        for i in range(0, len(tasks), self.concurrent_requests):
            batch = tasks[i:i + self.concurrent_requests]
            batch_results = await asyncio.gather(*batch, return_exceptions=True)

            for r in batch_results:
                if isinstance(r, Exception):
                    result.failed_requests += 1
                    result.other_errors += 1
                else:
                    success, latency, error = r
                    if success:
                        result.successful_requests += 1
                        latencies.append(latency)
                    else:
                        result.failed_requests += 1
                        if error == "oom":
                            result.oom_errors += 1
                        elif error == "timeout":
                            result.timeout_errors += 1
                        else:
                            result.other_errors += 1

        result.duration_seconds = time.perf_counter() - start_time
        result.total_requests = self.total_requests
        result.swap_count = swap_count
        result.avg_swap_time_ms = statistics.mean(swap_times) if swap_times else 0

        # Calcular métricas de latência
        if latencies:
            latencies.sort()
            result.latency_p50 = latencies[len(latencies) // 2]
            result.latency_p95 = latencies[int(len(latencies) * 0.95)]
            result.latency_p99 = latencies[int(len(latencies) * 0.99)]
            result.latency_mean = statistics.mean(latencies)
            result.latency_max = max(latencies)

        result.throughput_rps = result.successful_requests / result.duration_seconds if result.duration_seconds > 0 else 0

        if vram_samples:
            result.peak_vram_mb = max(vram_samples)
            result.avg_vram_mb = int(statistics.mean(vram_samples))

        # Log resultados
        logger.info(f"Results:")
        logger.info(f"  Success: {result.successful_requests}/{result.total_requests} ({result.successful_requests/result.total_requests*100:.1f}%)")
        logger.info(f"  OOM: {result.oom_errors} | Timeout: {result.timeout_errors} | Other: {result.other_errors}")
        logger.info(f"  Latency: p50={result.latency_p50:.0f}ms p95={result.latency_p95:.0f}ms p99={result.latency_p99:.0f}ms mean={result.latency_mean:.0f}ms")
        logger.info(f"  Throughput: {result.throughput_rps:.2f} req/s")
        logger.info(f"  VRAM: peak={result.peak_vram_mb}MB avg={result.avg_vram_mb}MB")
        logger.info(f"  Swaps: {result.swap_count} (avg {result.avg_swap_time_ms:.0f}ms)")

        return result

    async def run_all(self) -> list[BenchmarkResult]:
        """Executa todos os testes da matrix."""
        logger.info(f"Starting concurrency benchmark | concurrency={self.concurrent_requests} requests={self.total_requests}")

        for model_a, model_b, expected_vram, should_work, desc in TEST_COMBINATIONS:
            result = await self.run_combination(model_a, model_b, expected_vram, should_work, desc)
            self.results.append(result)

            # Cleanup entre testes
            await self._unload_model(model_a)
            await self._unload_model(model_b)
            await asyncio.sleep(2)  # Dar tempo para VRAM liberar

        return self.results

    def print_summary(self):
        """Imprime resumo final."""
        print("\n" + "=" * 80)
        print("BENCHMARK SUMMARY")
        print("=" * 80)

        print(f"\n{'Model A':<25} {'Model B':<25} {'Combo':<20} {'OK':<4} {'RPS':<8} {'p50':<8} {'p99':<8} {'OOM':<4} {'PeakVRAM':<10}")
        print("-" * 80)

        for r in self.results:
            status = "✓" if r.should_work == (r.oom_errors == 0 and r.successful_requests > 0) else "✗"
            print(f"{r.model_a:<25} {r.model_b:<25} {r.combination:<20} {status:<4} {r.throughput_rps:<8.2f} {r.latency_p50:<8.0f} {r.latency_p99:<8.0f} {r.oom_errors:<4} {r.peak_vram_mb:<10}")

        # Análise
        print("\n" + "=" * 80)
        print("ANALYSIS")
        print("=" * 80)

        working = [r for r in self.results if r.should_work and r.oom_errors == 0 and r.successful_requests > 0]
        broken = [r for r in self.results if not r.should_work and r.oom_errors > 0]

        if working:
            avg_rps = statistics.mean([r.throughput_rps for r in working])
            avg_p50 = statistics.mean([r.latency_p50 for r in working])
            print(f"\nWorking combinations ({len(working)}):")
            print(f"  Avg throughput: {avg_rps:.2f} req/s")
            print(f"  Avg latency p50: {avg_p50:.0f}ms")
            print(f"  Best combo: {max(working, key=lambda x: x.throughput_rps).combination} ({max(working, key=lambda x: x.throughput_rps).throughput_rps:.2f} req/s)")

        if broken:
            print(f"\nExpected failures ({len(broken)}):")
            for r in broken:
                print(f"  {r.combination}: OOM errors = {r.oom_errors} (expected)")

        # Recomendações
        print("\n" + "=" * 80)
        print("RECOMMENDATIONS")
        print("=" * 80)

        best_heavy_light = max([r for r in working if "Heavy + Light" in r.combination], key=lambda x: x.throughput_rps, default=None)
        best_light_light = max([r for r in working if "Light + Light" in r.combination], key=lambda x: x.throughput_rps, default=None)

        if best_heavy_light:
            print(f"Best Heavy+Light: {best_heavy_light.model_a} + {best_heavy_light.model_b} = {best_heavy_light.throughput_rps:.2f} req/s")
        if best_light_light:
            print(f"Best Light+Light: {best_light_light.model_a} + {best_light_light.model_b} = {best_light_light.throughput_rps:.2f} req/s")

        print("\nConfig suggestions:")
        print("  - Enable tiered concurrency in config.yaml")
        print("  - Heavy models: max_loaded_models=1, concurrency_tier=heavy")
        print("  - Light models: max_loaded_models=2, concurrency_tier=light")
        print("  - VRAM safety margin: 500MB minimum")

    def save_json(self, path: str):
        """Salva resultados em JSON."""
        data = {
            "timestamp": time.time(),
            "config": {
                "ollama_url": self.ollama_url,
                "hybrid_url": self.hybrid_url,
                "concurrent_requests": self.concurrent_requests,
                "total_requests": self.total_requests,
                "prompt": self.prompt,
            },
            "results": [r.to_dict() for r in self.results],
        }
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        logger.info(f"Results saved to {path}")


async def main():
    parser = argparse.ArgumentParser(description="VRAM-Aware Concurrency Benchmark")
    parser.add_argument("--ollama-url", default=OLLAMA_URL, help="Ollama base URL")
    parser.add_argument("--hybrid-url", default=HYBRID_URL, help="Hybrid Proxy URL")
    parser.add_argument("--concurrent", type=int, default=10, help="Concurrent requests")
    parser.add_argument("--requests", type=int, default=50, help="Total requests per combination")
    parser.add_argument("--prompt", default="Escreva uma função Python que calcula fibonacci de forma eficiente.", help="Test prompt")
    parser.add_argument("--output", default="benchmark_results.json", help="Output JSON file")
    args = parser.parse_args()

    benchmark = ConcurrencyBenchmark(
        ollama_url=args.ollama_url,
        hybrid_url=args.hybrid_url,
        concurrent_requests=args.concurrent,
        total_requests=args.requests,
        prompt=args.prompt,
    )

    try:
        await benchmark.run_all()
        benchmark.print_summary()
        benchmark.save_json(args.output)
    except KeyboardInterrupt:
        logger.info("Benchmark interrupted")
    except Exception as e:
        logger.exception(f"Benchmark failed: {e}")
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())