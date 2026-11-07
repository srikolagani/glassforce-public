#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ -f demo.mp4 ]; then
  printf '%s\n' "demo.mp4"
  exit 0
fi

if [ -f demo.gif ]; then
  printf '%s\n' "demo.gif"
  exit 0
fi

printf '%s\n' "assets/mock-search-eae6d2a.png"
