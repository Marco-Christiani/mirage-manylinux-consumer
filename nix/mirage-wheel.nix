{
  lib,
  pkgs,
  manylinux-env,
  mirage-src,
  system,
  pythonInterpreter ? pkgs.python312,
  targetAttr ? "manylinux_2_28_candidate",
  cudaAttr ? "cudaPackages_12_9",
  cudaPackageSet ? pkgs.${cudaAttr},
  rustTarget ? "x86_64-unknown-linux-gnu.2.28",
  repairMode ? "target",
}: let
  targetShell = manylinux-env.devShells.${system}.${targetAttr};
  abstractSubexprCargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "mirage-abstract-subexpr-cargo-vendor";
    src = mirage-src;
    cargoRoot = "src/search/abstract_expr/abstract_subexpr";
    hash = "sha256-NHmn/81I7Rccago8do9KYqIW3POPMijdI9OEPWde9xc=";
  };
  formalVerifierCargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    name = "mirage-formal-verifier-cargo-vendor";
    src = mirage-src;
    cargoRoot = "src/search/verification/formal_verifier_equiv";
    hash = "sha256-meKYroexmDTVRBjoiJP9KIfME1kaP+nU6GDzfUlHVKY=";
  };
  z3SolverWheel = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/py3/z/z3-solver/z3_solver-4.16.0.0-py3-none-manylinux_2_27_x86_64.whl";
    hash = "sha256-r64lUfeVZw8FIs/OghMtEpxAiiaUrf9x6wG6Dy7ORPk=";
  };
in
  manylinux-env.lib.mkManylinuxWheel {
    inherit lib pkgs repairMode;
    python = pythonInterpreter;
    pname = "mirage-project-manylinux-wheel";
    version = "0.2.4";

    src = mirage-src;
    inherit targetShell;

    nativeBuildInputs = [
      cudaPackageSet.cudatoolkit
      pkgs.bash
      pkgs.cargo
      pkgs.cargo-zigbuild
      pkgs.cmake
      pkgs.coreutils
      pkgs.gnumake
      pkgs.rustc
      pkgs.unzip
      pkgs.zig
      pythonInterpreter.pkgs.cython
    ];

    auditwheelExclude = ["libcuda.so*"];

    postPatch = ''
      rm -rf ./*.egg-info python/*.egg-info
      substituteInPlace setup.py \
        --replace-fail \
          'z3_path = path.dirname(z3.__file__)' \
          'z3_path = os.environ.get("Z3_ROOT", path.dirname(z3.__file__))'
      ${pythonInterpreter.interpreter} - <<'PY'
      from pathlib import Path

      setup = Path("setup.py")
      setup.write_text(
          "\n".join(
              line
              for line in setup.read_text().splitlines()
              if not (
                  "Wl,-rpath" in line
                  and "build" in line
                  and ("abstract_subexpr" in line or "formal_verifier" in line)
              )
          )
          + "\n"
      )
      PY
    '';

    preBuild = ''
      export CFLAGS="-ffile-prefix-map=$PWD=. -fdebug-prefix-map=$PWD=."
      export CXXFLAGS="$CFLAGS"
      export CUDA_HOME="${cudaPackageSet.cudatoolkit}"
      export CUDACXX="$CUDA_HOME/bin/nvcc"
      export CMAKE_BUILD_TYPE="Release"
      export CPATH="$CUDA_HOME/include''${CPATH:+:$CPATH}"
      export HOME="$TMPDIR/home"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      export CARGO_HOME="$TMPDIR/cargo"
      mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CARGO_HOME"
      mkdir -p \
        src/search/abstract_expr/abstract_subexpr/.cargo \
        src/search/verification/formal_verifier_equiv/.cargo
      cat > src/search/abstract_expr/abstract_subexpr/.cargo/config.toml <<CARGO_CONFIG
      [source.crates-io]
      replace-with = "vendored-sources"

      [source.vendored-sources]
      directory = "${abstractSubexprCargoDeps}/source-registry-0"
      CARGO_CONFIG
      cat > src/search/verification/formal_verifier_equiv/.cargo/config.toml <<CARGO_CONFIG
      [source.crates-io]
      replace-with = "vendored-sources"

      [source.vendored-sources]
      directory = "${formalVerifierCargoDeps}/source-registry-0"
      CARGO_CONFIG
      z3_wheel_root="$TMPDIR/z3-solver-wheel"
      mkdir -p "$z3_wheel_root"
      unzip -q ${z3SolverWheel} -d "$z3_wheel_root"
      export PYTHONPATH="$z3_wheel_root''${PYTHONPATH:+:$PYTHONPATH}"
      export Z3_ROOT="$z3_wheel_root/z3"
      export Z3_LIBRARY_PATH="$Z3_ROOT/lib"
      export LIBRARY_PATH="$CUDA_HOME/lib/stubs''${LIBRARY_PATH:+:$LIBRARY_PATH}"
      export LD_LIBRARY_PATH="$Z3_ROOT/lib:${lib.getLib pkgs.stdenv.cc.cc}/lib:$CUDA_HOME/lib/stubs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

      wrapper_dir="$TMPDIR/mirage-wrappers"
      mkdir -p "$wrapper_dir"
      cat > "$wrapper_dir/cargo" <<'CARGO'
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      real_cargo="${pkgs.cargo}/bin/cargo"
      rust_target="${rustTarget}"

      if [ "''${1:-}" = "build" ]; then
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
          "$real_cargo" zigbuild --target "$rust_target" "''${args[@]}"

        if [ -n "$target_dir" ]; then
          mkdir -p "$target_dir/release"
          echo "mirage cargo wrapper: scanning $target_dir for Rust cdylibs" >&2
          while IFS= read -r so_path; do
            echo "mirage cargo wrapper: copying $so_path to $target_dir/release/" >&2
            ${pkgs.binutils}/bin/strip -s "$so_path" || true
            rm -f "$target_dir/release/$(basename "$so_path")"
            cp -a "$so_path" "$target_dir/release/"
          done < <(find "$target_dir" -type f -name 'lib*.so' ! -path "$target_dir/release/*")
          ls -l "$target_dir/release" >&2
        fi
        exit 0
      fi

      exec "$real_cargo" "$@"
      CARGO
      chmod +x "$wrapper_dir/cargo"
      export PATH="$wrapper_dir:$CUDA_HOME/bin:${pkgs.rustc}/bin:${pkgs.cargo}/bin:$PATH"
    '';

    meta = {
      description = "Mirage wheel built inside the nix-manylinux-envs ${targetAttr} builder";
      platforms = ["x86_64-linux"];
    };
  }
