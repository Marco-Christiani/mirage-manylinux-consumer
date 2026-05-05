#!/usr/bin/env bash
set -euo pipefail

flake_ref=.
gpu=0
quiet=1
targets=()
build_args=()

usage() {
  cat <<'USAGE'
Usage:
  verify-mirage-matrix [OPTIONS]

Options:
  --all                 Build and verify every release target. Default when no --target is provided.
  --target NAME         Build and verify one target. May be repeated.
  --list                Print the generated release matrix JSON and exit.
  --flake REF           Flake reference to build. Defaults to current directory.
  --gpu                 Pass Docker CDI GPU device to the verifier.
  --no-gpu              Do not pass GPU device. Default.
  --quiet               Print START/PASS lines unless a verification fails. Default.
  --show-output         Stream container output.
  --build-arg ARG       Extra argument passed to nix build. May be repeated.
  --help                Show this help.
USAGE
}

if [ -z "${MIRAGE_RELEASE_MATRIX_JSON:-}" ]; then
  echo "MIRAGE_RELEASE_MATRIX_JSON must point to the generated release matrix JSON" >&2
  exit 2
fi

if [ -z "${VERIFY_MIRAGE_WHEEL:-}" ]; then
  echo "VERIFY_MIRAGE_WHEEL must point to the verify-mirage-wheel executable" >&2
  exit 2
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      targets=()
      shift
      ;;
    --target)
      targets+=("$2")
      shift 2
      ;;
    --list)
      jq . "$MIRAGE_RELEASE_MATRIX_JSON"
      exit 0
      ;;
    --flake)
      flake_ref="$2"
      shift 2
      ;;
    --gpu)
      gpu=1
      shift
      ;;
    --no-gpu)
      gpu=0
      shift
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    --show-output)
      quiet=0
      shift
      ;;
    --build-arg)
      build_args+=("$2")
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "${#targets[@]}" -eq 0 ]; then
  mapfile -t targets < <(jq -r '.[].name' "$MIRAGE_RELEASE_MATRIX_JSON")
fi

for target in "${targets[@]}"; do
  target_json="$(jq -er --arg target "$target" '.[] | select(.name == $target)' "$MIRAGE_RELEASE_MATRIX_JSON")" || {
    echo "unknown release target: $target" >&2
    exit 2
  }
  package_name="$(jq -r '.package' <<<"$target_json")"
  python_image="$(jq -r '.pythonImage' <<<"$target_json")"
  cache_volume="$(jq -r '.cacheVolume' <<<"$target_json")"

  echo "BUILD $target"
  out="$(nix build "$flake_ref#$package_name" --no-link --print-out-paths "${build_args[@]}")"
  out="$(tail -n 1 <<<"$out")"

  verify_args=(
    --python-image "$python_image"
    --wheel-dir "$out/repaired"
    --cache-volume "$cache_volume"
  )
  if [ "$gpu" = 1 ]; then
    verify_args+=(--gpu)
  fi
  if [ "$quiet" = 1 ]; then
    verify_args+=(--quiet)
  else
    verify_args+=(--show-output)
  fi

  "$VERIFY_MIRAGE_WHEEL" "${verify_args[@]}"
done
