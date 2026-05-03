{
  pkgs,
  rustTarget,
}:
pkgs.writeShellScriptBin "cargo" ''
  set -euo pipefail

  real_cargo="${pkgs.cargo}/bin/cargo"

  if [ "''${1:-}" != "build" ]; then
    exec "$real_cargo" "$@"
  fi

  shift
  target_dir=""
  args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target-dir)
        target_dir="$2"
        args+=("$1" "$2")
        shift 2
        ;;
      --target-dir=*)
        target_dir="''${1#--target-dir=}"
        args+=("$1")
        shift
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  ${pkgs.coreutils}/bin/env \
    -u LD_LIBRARY_PATH \
    -u NIX_CFLAGS_COMPILE \
    -u NIX_ENFORCE_NO_NATIVE \
    -u NIX_LDFLAGS \
    PATH="${pkgs.cargo-zigbuild}/bin:${pkgs.zig}/bin:${pkgs.rustc}/bin:${pkgs.cargo}/bin:${pkgs.stdenv.cc}/bin:$PATH" \
    CC="${pkgs.stdenv.cc}/bin/cc" \
    CXX="${pkgs.stdenv.cc}/bin/c++" \
    "$real_cargo" zigbuild --target "${rustTarget}" "''${args[@]}"

  if [ -n "$target_dir" ]; then
    mkdir -p "$target_dir/release"
    echo "mirage cargo wrapper: scanning $target_dir for Rust cdylibs" >&2
    while IFS= read -r so_path; do
      echo "mirage cargo wrapper: copying $so_path to $target_dir/release/" >&2
      ${pkgs.binutils}/bin/strip -s "$so_path" || true
      rm -f "$target_dir/release/$(basename "$so_path")"
      cp -a "$so_path" "$target_dir/release/"
    done < <(${pkgs.findutils}/bin/find "$target_dir" -type f -name 'lib*.so' ! -path "$target_dir/release/*")
    ls -l "$target_dir/release" >&2
  fi
''
