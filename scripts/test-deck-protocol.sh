#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-deck-protocol.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/StreamDeck/DeckProtocol.swift \
    NotchBuddy/Sources/App/StreamDeck/DeckLayout.swift \
    tests/DeckProtocolTests.swift -o "$TEST_DIR/deck-protocol-tests"
"$TEST_DIR/deck-protocol-tests"
