@echo off
cd /d C:\FCC\ClaudeProxy
python -c "import sys; sys.path.insert(0, '.'); from hybrid import app; import uvicorn; uvicorn.run(app, host='127.0.0.1', port=3456, access_log=False)"