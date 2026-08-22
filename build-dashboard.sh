#!/usr/bin/env bash

set -euo pipefail

DASHBOARD_VERSION="${DASHBOARD_VERSION:-v2.2.10}"
ADMIN_FRONTEND_VERSION="${ADMIN_FRONTEND_VERSION:-v2.2.5}"
OUTPUT_DIR="${OUTPUT_DIR:-dist}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

case "$DASHBOARD_VERSION" in
  v2.2.10)
    [ "$ADMIN_FRONTEND_VERSION" = "v2.2.5" ] || {
      echo "DASHBOARD_VERSION v2.2.10 requires ADMIN_FRONTEND_VERSION v2.2.5." >&2
      exit 1
    }
    ;;
  *)
    echo "Unsupported patched Dashboard version: $DASHBOARD_VERSION" >&2
    exit 1
    ;;
esac

command -v git >/dev/null || { echo "git is required." >&2; exit 1; }
command -v npm >/dev/null || { echo "npm is required." >&2; exit 1; }
command -v go >/dev/null || { echo "go is required." >&2; exit 1; }
command -v swag >/dev/null || { echo "swag is required." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

: "${IPINFO_TOKEN:?IPINFO_TOKEN is required to download the GeoIP country database.}"

ADMIN_DIR="$BUILD_DIR/admin-frontend"
NEZHA_DIR="$BUILD_DIR/nezha"

git clone --depth 1 --branch "$ADMIN_FRONTEND_VERSION" \
  https://github.com/nezhahq/admin-frontend.git "$ADMIN_DIR"
git -C "$ADMIN_DIR" apply --check "$ROOT_DIR/patches/admin-frontend-v2.2.5-server.patch"
git -C "$ADMIN_DIR" apply "$ROOT_DIR/patches/admin-frontend-v2.2.5-server.patch"

npm --prefix "$ADMIN_DIR" ci
npm --prefix "$ADMIN_DIR" run build

git clone --depth 1 --branch "$DASHBOARD_VERSION" \
  https://github.com/nezhahq/nezha.git "$NEZHA_DIR"

# 升级 grpc-go：v2.2.10 锁定的 1.81.1 服务端在大规模 agent 场景下会周期性重置
# gRPC 连接（批量掉线），最新 nezha 使用 1.83.0 无此问题
(
  cd "$NEZHA_DIR"
  go get google.golang.org/grpc@v1.83.0
  go mod tidy
)

GEOIP_DB="$NEZHA_DIR/pkg/geoip/geoip.db"
GEOIP_URL="https://ipinfo.io/data/free/country.mmdb?token=${IPINFO_TOKEN}"
rm -f "$GEOIP_DB"
curl --fail --silent --show-error --location \
  --retry 3 --retry-all-errors \
  --output "$GEOIP_DB" "$GEOIP_URL"

python3 - "$GEOIP_DB" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
if len(data) < 1024:
    raise SystemExit(f"GeoIP database is unexpectedly small: {len(data)} bytes")
if b"\xab\xcd\xefMaxMind.com" not in data[-131072:]:
    raise SystemExit("Downloaded GeoIP file does not contain a MaxMind DB metadata marker")
print(f"Validated GeoIP country database: {len(data)} bytes")
PY

(
  cd "$NEZHA_DIR"
  ./script/fetch-frontends.sh
  swag init --pd -d cmd/dashboard -g main.go -o cmd/dashboard/docs
)
rm -rf "$NEZHA_DIR/cmd/dashboard/admin-dist"
cp -a "$ADMIN_DIR/dist" "$NEZHA_DIR/cmd/dashboard/admin-dist"

mkdir -p "$ROOT_DIR/$OUTPUT_DIR"

build_dashboard() {
  local arch="$1"
  local cc="$2"
  local output="$ROOT_DIR/$OUTPUT_DIR/dashboard-linux-$arch"

  (
    cd "$NEZHA_DIR"
    CGO_ENABLED=1 GOOS=linux GOARCH="$arch" CC="$cc" \
      go build -trimpath -buildvcs=false -tags go_json \
      -ldflags "-s -w -X github.com/nezhahq/nezha/service/singleton.Version=${DASHBOARD_VERSION#v} -extldflags '-static -fpic'" \
      -o "$output" ./cmd/dashboard
  )
}

build_dashboard amd64 x86_64-linux-gnu-gcc
build_dashboard arm64 aarch64-linux-gnu-gcc

for arch in amd64 arm64; do
  archive="$ROOT_DIR/$OUTPUT_DIR/dashboard-linux-$arch.zip"
  rm -f "$archive"
  (
    cd "$ROOT_DIR/$OUTPUT_DIR"
    zip -q "dashboard-linux-$arch.zip" "dashboard-linux-$arch"
  )
done
