#!/bin/sh
export LD_LIBRARY_PATH="/home/mzou/whisper-server/.venv/lib/python3.12/site-packages/nvidia/cublas/lib:/home/mzou/whisper-server/.venv/lib/python3.12/site-packages/nvidia/cudnn/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export WHISPER_HOST=100.100.184.6
exec "$(dirname "$0")/.venv/bin/python" "$(dirname "$0")/server.py"
