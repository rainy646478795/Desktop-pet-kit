#!/bin/bash
cd "$(dirname "$0")"
pkill -f "$(pwd)/atom-bubble" 2>/dev/null
sleep 1
nohup ./atom-bubble >/dev/null 2>&1 &
echo "Atom Bubble started (PID $!)"
