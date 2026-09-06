#!/bin/sh
# Builds the magictap CLI into ./bin/magictap
set -e
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -framework IOKit -o bin/magictap src/HIDMotion.swift src/TapDetector.swift src/Gesture.swift src/InputActivity.swift src/main.swift
echo "built bin/magictap"
