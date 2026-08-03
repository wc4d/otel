#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DESTINATION_DIR="$PROJECT_DIR/.build/aws-layer"

: "${NEXUS_OTEL_URL:?Set NEXUS_OTEL_URL to the full immutable artifact URL}"
: "${NEXUS_OTEL_SHA256:?Set NEXUS_OTEL_SHA256 to the expected SHA-256 checksum}"

for command_name in curl shasum unzip; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
ARTIFACT_PATH="$TEMP_DIR/aws-otel-collector.zip"
EXTRACTED_DIR="$TEMP_DIR/extracted"

CURL_AUTH=()
if [[ -n "${NEXUS_TOKEN:-}" ]]; then
  CURL_AUTH=(--header "Authorization: Bearer $NEXUS_TOKEN")
elif [[ -n "${NEXUS_USERNAME:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
  CURL_AUTH=(--user "$NEXUS_USERNAME:$NEXUS_PASSWORD")
else
  echo "Set NEXUS_TOKEN or both NEXUS_USERNAME and NEXUS_PASSWORD" >&2
  exit 1
fi

curl --fail --location --silent --show-error \
  "${CURL_AUTH[@]}" \
  --output "$ARTIFACT_PATH" \
  "$NEXUS_OTEL_URL"

ACTUAL_SHA256=$(shasum -a 256 "$ARTIFACT_PATH" | cut -d ' ' -f 1)
if [[ "$ACTUAL_SHA256" != "$NEXUS_OTEL_SHA256" ]]; then
  echo "Checksum mismatch for downloaded ADOT artifact" >&2
  echo "Expected: $NEXUS_OTEL_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

mkdir -p "$EXTRACTED_DIR"
unzip -q "$ARTIFACT_PATH" -d "$EXTRACTED_DIR"

if [[ ! -x "$EXTRACTED_DIR/extensions/collector" ]]; then
  echo "Downloaded artifact does not contain executable extensions/collector" >&2
  exit 1
fi

if [[ ! -f "$EXTRACTED_DIR/collector-config/config.yaml" ]]; then
  echo "Downloaded artifact does not contain collector-config/config.yaml" >&2
  exit 1
fi

mkdir -p "$DESTINATION_DIR"
find "$DESTINATION_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$EXTRACTED_DIR/." "$DESTINATION_DIR/"

echo "Verified and extracted ADOT artifact to $DESTINATION_DIR"

