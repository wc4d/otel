#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${OTEL_LAYER_SOURCE_DIR:-$PROJECT_DIR/.aws-layer}
OUTPUT_DIR=${OTEL_ARTIFACT_OUTPUT_DIR:-$PROJECT_DIR/artifacts}
ARTIFACT_NAME=${OTEL_ARTIFACT_NAME:-aws-otel-collector-amd64-0.117.0.zip}
ARTIFACT_PATH="$OUTPUT_DIR/$ARTIFACT_NAME"

for command_name in zip shasum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

if [[ ! -x "$SOURCE_DIR/extensions/collector" ]]; then
  echo "ADOT Lambda extension not found or not executable: $SOURCE_DIR/extensions/collector" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_DIR/collector-config/config.yaml" ]]; then
  echo "ADOT collector configuration not found: $SOURCE_DIR/collector-config/config.yaml" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
if [[ -e "$ARTIFACT_PATH" ]]; then
  echo "Refusing to overwrite existing artifact: $ARTIFACT_PATH" >&2
  exit 1
fi

(
  cd "$SOURCE_DIR"
  zip -q -r "$ARTIFACT_PATH" .
)

shasum -a 256 "$ARTIFACT_PATH" > "$ARTIFACT_PATH.sha256"

echo "Created: $ARTIFACT_PATH"
echo "Checksum: $(cut -d ' ' -f 1 "$ARTIFACT_PATH.sha256")"

