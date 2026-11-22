#!/usr/bin/env python3
"""
Benchmark script for FCC Proxy chain:
- NVIDIA Proxy (port 10089) direct
- Hybrid Proxy (port 3456) via NVIDIA Proxy
"""

import asyncio
import httpx
import time
import json
import sys
from typing import Dict, List

# Configuration
NVIDIA_PROXY_URL = "http://127.0.0.1:10089/v1/chat/completions"
HYBRID_PROXY_URL = "http://127.0.0.1:3456/v1/messages"
NVIDIA_API_KEY = "sk-local-proxy-20261112"
HYBRID_API_KEY = "local-proxy"

# Test models
MODELS_NVIDIA = {
    "ollama/qwen2.5-coder:7b-gpu90": "Ollama Qwen 7B GPU",
    "ollama/qwen3:8b-gpu90": "Ollama Qwen3 8B GPU (reasoning)",
    "ollama/deepseek-coder:6.7b-gpu90": "Ollama DeepSeek 6.7B GPU",
    "nvidia_nim/bigcode/starcoder2-15b": "NVIDIA NIM StarCoder2 15B",
    "nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b": "NVIDIA NIM Nemotron 3 Ultra",
    "gemini/gemini-3.1-flash-lite": "Gemini 3.1 Flash Lite",
}

MODELS_HYBRID = {
    "sonnet": "Hybrid: sonnet -> qwen2.5-coder:7b-gpu90",
    "qwen": "Hybrid: qwen -> qwen2.5-coder:7b-gpu90",
    "qwen3": "Hybrid: qwen3 -> qwen3:8b-gpu90",
    "deepseek": "Hybrid: deepseek -> deepseek-coder:6.7b-gpu90",
    "nemotron": "Hybrid: nemotron -> nemotron-3-ultra",
    "starcoder2": "Hybrid: starcoder2 -> bigcode/starcoder2-15b",
    "kimi": "Hybrid: kimi -> custom/nim-direct",
}

async def benchmark_nvidia_proxy(model: str, name: str, runs: int = 3) -> List[float]:
    """Benchmark NVIDIA Proxy directly."""
    latencies = []
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Olá, responda apenas OK"}],
        "max_tokens": 10,
        "stream": False
    }
    headers = {
        "Authorization": f"Bearer {NVIDIA_API_KEY}",
        "Content-Type": "application/json"
    }

    async with httpx.AsyncClient(timeout=300.0) as client:
        for i in range(runs):
            start = time.perf_counter()
            try:
                resp = await client.post(NVIDIA_PROXY_URL, json=payload, headers=headers)
                elapsed = time.perf_counter() - start
                if resp.status_code == 200:
                    latencies.append(elapsed)
                    print(f"  Run {i+1}: {elapsed:.2f}s OK")
                else:
                    print(f"  Run {i+1}: HTTP {resp.status_code} - {resp.text[:100]}")
                    latencies.append(None)
            except Exception as e:
                elapsed = time.perf_counter() - start
                print(f"  Run {i+1}: ERROR after {elapsed:.2f}s - {e}")
                latencies.append(None)
            await asyncio.sleep(1)

    return latencies

async def benchmark_hybrid_proxy(model: str, name: str, runs: int = 3) -> List[float]:
    """Benchmark Hybrid Proxy (Anthropic format)."""
    latencies = []
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": "Olá, responda apenas OK"}],
        "max_tokens": 10,
        "stream": False
    }
    headers = {
        "Authorization": f"Bearer {HYBRID_API_KEY}",
        "Content-Type": "application/json"
    }

    async with httpx.AsyncClient(timeout=300.0) as client:
        for i in range(runs):
            start = time.perf_counter()
            try:
                resp = await client.post(HYBRID_PROXY_URL, json=payload, headers=headers)
                elapsed = time.perf_counter() - start
                if resp.status_code == 200:
                    latencies.append(elapsed)
                    print(f"  Run {i+1}: {elapsed:.2f}s OK")
                else:
                    print(f"  Run {i+1}: HTTP {resp.status_code} - {resp.text[:100]}")
                    latencies.append(None)
            except Exception as e:
                elapsed = time.perf_counter() - start
                print(f"  Run {i+1}: ERROR after {elapsed:.2f}s - {e}")
                latencies.append(None)
            await asyncio.sleep(1)

    return latencies

async def main():
    print("=" * 70)
    print("FCC PROXY CHAIN BENCHMARK")
    print("=" * 70)
    print(f"NVIDIA Proxy: {NVIDIA_PROXY_URL}")
    print(f"Hybrid Proxy: {HYBRID_PROXY_URL}")
    print()

    results = {}

    # Test NVIDIA Proxy directly
    print("\n" + "=" * 70)
    print("TESTING NVIDIA PROXY DIRECT (port 10089)")
    print("=" * 70)

    for model, name in MODELS_NVIDIA.items():
        print(f"\n{name} ({model})")
        latencies = await benchmark_nvidia_proxy(model, name)
        valid = [l for l in latencies if l is not None]
        if valid:
            avg = sum(valid) / len(valid)
            print(f"  Average: {avg:.2f}s (min={min(valid):.2f}s, max={max(valid):.2f}s)")
            results[f"nvidia:{model}"] = {"avg": avg, "min": min(valid), "max": max(valid), "runs": valid}
        else:
            print(f"  All runs failed")
            results[f"nvidia:{model}"] = {"avg": None, "runs": latencies}

    # Test Hybrid Proxy
    print("\n" + "=" * 70)
    print("TESTING HYBRID PROXY (port 3456) - Anthropic format")
    print("=" * 70)

    for model, name in MODELS_HYBRID.items():
        print(f"\n{name} ({model})")
        latencies = await benchmark_hybrid_proxy(model, name)
        valid = [l for l in latencies if l is not None]
        if valid:
            avg = sum(valid) / len(valid)
            print(f"  Average: {avg:.2f}s (min={min(valid):.2f}s, max={max(valid):.2f}s)")
            results[f"hybrid:{model}"] = {"avg": avg, "min": min(valid), "max": max(valid), "runs": valid}
        else:
            print(f"  All runs failed")
            results[f"hybrid:{model}"] = {"avg": None, "runs": latencies}

    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"{'Proxy':<15} {'Model':<35} {'Avg (s)':<10} {'Min (s)':<10} {'Max (s)':<10}")
    print("-" * 70)

    for key, data in results.items():
        proxy, model = key.split(":", 1)
        if data["avg"] is not None:
            print(f"{proxy:<15} {model:<35} {data['avg']:<10.2f} {data['min']:<10.2f} {data['max']:<10.2f}")
        else:
            print(f"{proxy:<15} {model:<35} {'FAILED':<10} {'-':<10} {'-':<10}")

    # Save results
    with open("benchmark_results.json", "w") as f:
        json.dump(results, f, indent=2)
    print("\nResults saved to benchmark_results.json")

if __name__ == "__main__":
    asyncio.run(main())