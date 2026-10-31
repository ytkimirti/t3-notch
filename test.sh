#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos14.0 -o build/tests Sources/Store.swift Tests/main.swift
build/tests
