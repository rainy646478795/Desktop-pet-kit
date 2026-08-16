#!/bin/bash
cd "$(dirname "$0")"
pkill -f "$(pwd)/atom-bubble" 2>/dev/null
echo "Atom Bubble stopped"
