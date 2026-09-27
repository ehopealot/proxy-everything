#!/usr/bin/env bash
# Verifies the ingress control listener remains reachable while transparent
# outbound flows continue through the TPROXY chain. It owns every Docker
# resource it creates and never modifies host networking.
set -Eeuo pipefail

readonly PORT=39001
readonly EGRESS_PORT=45678
readonly UUID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
readonly IMAGE="proxy-everything-regression:${UUID}"
readonly HOLDER="proxy-everything-regression-${UUID}"
readonly LOG_DIR="${TMPDIR:-/tmp}/proxy-everything-regression-${UUID}"
CONTAINER_CREATED=false
IMAGE_CREATED=false

mkdir -p "$LOG_DIR"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ "$CONTAINER_CREATED" == true ]]; then
    docker logs "$HOLDER" >"$LOG_DIR/proxy.log" 2>&1 || true
    docker rm -f "$HOLDER" >/dev/null 2>&1 || true
  fi
  if [[ "$IMAGE_CREATED" == true ]]; then
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
  fi
  printf 'cleanup uuid=%s container=%s image=%s status=%s logs=%s\n' \
    "$UUID" "$HOLDER" "$IMAGE" "$status" "$LOG_DIR"
  exit "$status"
}
trap cleanup EXIT INT TERM

subnet="$({ docker network inspect bridge; } | python3 -c '
import json, sys
network = json.load(sys.stdin)[0]
print(next(entry["Subnet"] for entry in network["IPAM"]["Config"] if ":" not in entry["Subnet"]))
')"

# Build a UUID-tagged local image. The tag is removed by cleanup and is never
# pushed or used to replace a shared image reference.
docker build --tag "$IMAGE" .
IMAGE_CREATED=true

docker create --name "$HOLDER" --network bridge --cap-add NET_ADMIN \
  --dns 1.1.1.1 --dns 8.8.8.8 --add-host host.docker.internal:host-gateway \
  --publish 127.0.0.1::"$PORT" "$IMAGE" \
  --http-egress-port "$EGRESS_PORT" \
  --http-ingress-address "0.0.0.0:${PORT}" \
  --docker-gateway-cidr "$subnet" \
  --dns-enabled --tls-intercept --disable-ipv6 >/dev/null
CONTAINER_CREATED=true
docker start "$HOLDER" >/dev/null

for _ in $(seq 1 80); do
  if docker exec "$HOLDER" busybox wget -q -O /dev/null "http://127.0.0.1:${PORT}/ca"; then
    break
  fi
  sleep 0.25
done

docker exec "$HOLDER" busybox wget -q -O /dev/null "http://127.0.0.1:${PORT}/ca"
docker exec "$HOLDER" iptables -t mangle -C PREROUTING -p tcp -m socket --transparent -j DIVERT
docker exec "$HOLDER" iptables -t mangle -S PREROUTING \
  | grep -Fqx -- '-A PREROUTING -p tcp -m socket --transparent -j DIVERT'

host_port="$(docker inspect "$HOLDER" --format '{{with index .NetworkSettings.Ports "39001/tcp"}}{{(index . 0).HostPort}}{{end}}')"
container_ip="$(docker inspect "$HOLDER" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
[[ -n "$host_port" && -n "$container_ip" ]]

python3 - "$host_port" "$container_ip" "$PORT" "$EGRESS_PORT" <<'PY'
import http.client
import json
import sys

host_port, container_ip, port, egress_port = sys.argv[1:]
body = json.dumps({
    "port": int(egress_port),
    "dns": {"allowHostnames": []},
    "internet": {"enabled": False},
})
for label, host, destination_port in (
    ("published", "127.0.0.1", int(host_port)),
    ("bridge", container_ip, int(port)),
):
    connection = http.client.HTTPConnection(host, destination_port, timeout=4)
    try:
        connection.request("PUT", "/egress", body=body,
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        response.read()
        if response.status != 204:
            raise SystemExit(f"{label} /egress returned HTTP {response.status}, expected 204")
        print(f"{label} /egress returned HTTP 204")
    finally:
        connection.close()
PY

# A TEST-NET connection must reach the transparent TPROXY rule before it can
# leave the container. This asserts interception, not external reachability.
tproxy_packets() {
  docker exec "$HOLDER" sh -c \
    "iptables -t mangle -L DOCKER_PROXY_ANYTHING_TPROXY -v -n -x | awk '\$3 == \"TPROXY\" { print \$1; exit }'"
}
before_packets="$(tproxy_packets)"
[[ "$before_packets" =~ ^[0-9]+$ ]]
set +e
timeout 4 docker exec "$HOLDER" busybox nc -w 1 198.51.100.1 443 \
  >"$LOG_DIR/transparent-flow.stdout" 2>"$LOG_DIR/transparent-flow.stderr"
set -e
after_packets="$(tproxy_packets)"
[[ "$after_packets" =~ ^[0-9]+$ ]]
if (( after_packets <= before_packets )); then
  echo "TPROXY packet counter did not increase: ${before_packets} -> ${after_packets}" >&2
  exit 1
fi
printf 'transparent TPROXY packets=%s->%s\n' "$before_packets" "$after_packets"
