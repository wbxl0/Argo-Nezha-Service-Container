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
