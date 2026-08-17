#!/usr/bin/env bash
set -euo pipefail

tool_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "$tool_dir/.." && pwd)"
validation_tmp="$(mktemp -d "${TMPDIR:-/tmp}/workbench-ws-docker.XXXXXX")"
resource_suffix="$$"
image_tag="workbench-voice-websocket-mock:$resource_suffix"
first_container="workbench-ws-mock-first-$resource_suffix"
second_container="workbench-ws-mock-second-$resource_suffix"
network_name="workbench-ws-mock-network-$resource_suffix"
first_secret="synthetic-alpha-secret"
second_secret="synthetic-beta-secret"

cleanup() {
  docker rm -f "$first_container" "$second_container" >/dev/null 2>&1 || true
  docker network rm "$network_name" >/dev/null 2>&1 || true
  docker image rm -f "$image_tag" >/dev/null 2>&1 || true
  rm -rf "$validation_tmp"
}
trap cleanup EXIT

cd "$project_dir"
dart compile exe \
  tool/mock_voice_websocket_server.dart \
  -o "$validation_tmp/mock_voice_websocket_server"
docker build \
  --quiet \
  --tag "$image_tag" \
  --file tool/docker/voice_websocket_mock/Dockerfile \
  "$validation_tmp" >/dev/null

docker network create "$network_name" >/dev/null

docker run --detach \
  --name "$first_container" \
  --network "$network_name" \
  --env MOCK_AGENTS="Mock Alpha" \
  --env MOCK_TOKEN="$first_secret" \
  "$image_tag" >/dev/null
docker run --detach \
  --name "$second_container" \
  --network "$network_name" \
  --env MOCK_AGENTS="Mock Beta" \
  --env MOCK_TOKEN="$second_secret" \
  "$image_tag" >/dev/null

for _ in $(seq 1 50); do
  if docker logs "$first_container" 2>&1 | grep -q mock_server_ready && \
     docker logs "$second_container" 2>&1 | grep -q mock_server_ready; then
    break
  fi
  sleep 0.1
done

first_host="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$first_container")"
second_host="$(docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$second_container")"
first_port=8787
second_port=8787

flutter test --no-pub tool/validate_multi_voice_websocket_docker.dart \
  --dart-define="FIRST_HOST=$first_host" \
  --dart-define="FIRST_PORT=$first_port" \
  --dart-define="FIRST_SECRET=$first_secret" \
  --dart-define="SECOND_HOST=$second_host" \
  --dart-define="SECOND_PORT=$second_port" \
  --dart-define="SECOND_SECRET=$second_secret"

docker stop "$first_container" >/dev/null
flutter test --no-pub tool/validate_multi_voice_websocket_docker.dart \
  --dart-define="FIRST_HOST=$first_host" \
  --dart-define="FIRST_PORT=$first_port" \
  --dart-define="FIRST_SECRET=$first_secret" \
  --dart-define="SECOND_HOST=$second_host" \
  --dart-define="SECOND_PORT=$second_port" \
  --dart-define="SECOND_SECRET=$second_secret" \
  --dart-define=EXPECT_FIRST_FAILURE=true

first_signals="$(docker logs "$first_container" 2>&1 | grep -c signal_received || true)"
second_signals="$(docker logs "$second_container" 2>&1 | grep -c signal_received || true)"
if [[ "$first_signals" -lt 1 || "$second_signals" -lt 2 ]]; then
  echo "Docker mock signal counts did not meet the validation contract." >&2
  exit 1
fi

echo "docker_mock_signals_confirmed first=$first_signals second=$second_signals"
cleanup
trap - EXIT
