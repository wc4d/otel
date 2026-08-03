#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.local.yaml"
COUNT=${COUNT:-8}
INVOKE_PATH=/2015-03-31/functions/function/invocations
TUNNEL_PID=
TUNNEL_LOG=

cleanup() {
  if [[ -n "$TUNNEL_PID" ]]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
  if [[ -n "$TUNNEL_LOG" && -f "$TUNNEL_LOG" ]]; then
    unlink "$TUNNEL_LOG"
  fi
}
trap cleanup EXIT

docker compose --progress quiet -f "$COMPOSE_FILE" up --detach --build

PAYLOAD=$(printf '{"rawPath":"/metrics","queryStringParameters":{"count":"%s"}}' "$COUNT")
RESPONSE=
for _ in 1 2 3 4 5; do
  RESPONSE=$(curl --silent --show-error \
    --request POST \
    --header 'content-type: application/json' \
    --data "$PAYLOAD" \
    "http://localhost:9000$INVOKE_PATH")
  if [[ "$RESPONSE" == *'Sample OpenTelemetry metrics emitted'* ]]; then
    break
  fi
  sleep 2
done

if [[ "$RESPONSE" != *'Sample OpenTelemetry metrics emitted'* ]]; then
  echo "Local Lambda invocation failed: $RESPONSE" >&2
  exit 1
fi

sleep 2
COLLECTOR_LOGS=$(docker compose -f "$COMPOSE_FILE" logs --no-color collector)
for metric_name in demo.requests demo.samples demo.handler.duration; do
  if [[ "$COLLECTOR_LOGS" != *"$metric_name"* ]]; then
    echo "Collector output did not contain $metric_name" >&2
    exit 1
  fi
done

echo "Local Lambda response: $RESPONSE"
echo "Collector received: demo.requests, demo.samples, demo.handler.duration"

if [[ "${EXPOSE_CLOUDFLARE:-false}" == "true" ]]; then
  command -v cloudflared >/dev/null || {
    echo "cloudflared is required when EXPOSE_CLOUDFLARE=true" >&2
    exit 1
  }

  TUNNEL_LOG=$(mktemp)
  cloudflared tunnel --no-autoupdate --url http://localhost:9000 \
    >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!

  TUNNEL_URL=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    TUNNEL_URL=$(sed -n 's#.*\(https://[-a-z0-9]*\.trycloudflare\.com\).*#\1#p' "$TUNNEL_LOG" | tail -n 1)
    [[ -n "$TUNNEL_URL" ]] && break
    sleep 1
  done

  if [[ -z "$TUNNEL_URL" ]]; then
    echo "Cloudflare tunnel did not become ready" >&2
    sed -n '1,120p' "$TUNNEL_LOG" >&2
    exit 1
  fi

  TUNNEL_HOST=${TUNNEL_URL#https://}
  CURL_RESOLVE=()
  if command -v dig >/dev/null; then
    TUNNEL_IP=
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      TUNNEL_IP=$(dig @1.1.1.1 +short "$TUNNEL_HOST" A | head -n 1)
      [[ -n "$TUNNEL_IP" ]] && break
      sleep 2
    done
    if [[ -n "$TUNNEL_IP" ]]; then
      CURL_RESOLVE=(--resolve "$TUNNEL_HOST:443:$TUNNEL_IP")
    fi
  fi

  PUBLIC_RESPONSE=
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    PUBLIC_RESPONSE=$(curl --fail --silent --show-error \
      --connect-timeout 5 \
      --max-time 15 \
      "${CURL_RESOLVE[@]}" \
      --request POST \
      --header 'content-type: application/json' \
      --data "$PAYLOAD" \
      "$TUNNEL_URL$INVOKE_PATH") && break
    sleep 2
  done

  if [[ "$PUBLIC_RESPONSE" != *'Sample OpenTelemetry metrics emitted'* ]]; then
    echo "Cloudflare endpoint did not become reachable: $TUNNEL_URL" >&2
    exit 1
  fi

  echo "Cloudflare URL: $TUNNEL_URL"
  echo "Cloudflare response: $PUBLIC_RESPONSE"
fi
