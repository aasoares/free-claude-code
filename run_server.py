#!/usr/bin/env python
"""
Server entry point - avoids uvicorn factory double-bind issue on Windows.
Chamado por: python run_server.py [--port PORTA] [--host HOST]
Nenhum arquivo existente serve o mesmo propósito - o main.py usa factory pattern que causa double-bind no Windows.
"""
from __future__ import annotations

import argparse
import uvicorn
from nvidia_proxy.main import create_app
from nvidia_proxy.config import get_config


def main():
    parser = argparse.ArgumentParser(
        prog="run_server",
        description="NVIDIA Proxy server entry point (Windows-safe, no double-bind)",
    )
    parser.add_argument(
        "--port", "-p",
        type=int,
        default=None,
        help="Porta para ouvir (sobrescreve config.yaml)",
    )
    parser.add_argument(
        "--host",
        type=str,
        default=None,
        help="Host para bind (sobrescreve config.yaml)",
    )
    args = parser.parse_args()

    config = get_config()

    # Aplica sobrescritas de linha de comando
    if args.host:
        config.host = args.host
    if args.port:
        config.port = args.port

    # Create app instance directly (not factory) - evita double-bind no Windows
    app = create_app()

    # Run uvicorn com a instancia de app diretamente
    uvicorn.run(
        app,
        host=config.host,
        port=config.port,
        log_level=config.log_level.lower(),
        reload=config.reload,
        loop="asyncio",
    )


if __name__ == "__main__":
    main()