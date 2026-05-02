{
  description = "Minimal Mirage consumer for nix-manylinux-envs";

  nixConfig = {
    extra-substituters = [
      "https://cuda-maintainers.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    manylinux-env = {
      url = "github:Marco-Christiani/nix-manylinux-envs";
    };
    mirage-src = {
      url = "github:Marco-Christiani/mirage?ref=marco/ci-infra-fixes";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    manylinux-env,
    mirage-src,
  }: let
    systems = ["x86_64-linux"];
    forAllSystems = f:
      builtins.listToAttrs (
        map (system: {
          name = system;
          value = f system;
        })
        systems
      );
  in {
    packages = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          cudaSupport = true;
          allowUnfree = true;
        };
      };
    in {
      default = self.packages.${system}.mirage-wheel;
      mirage-wheel = pkgs.callPackage ./nix/mirage-wheel.nix {
        inherit manylinux-env mirage-src system;
      };
      mirage-wheel-raw = pkgs.callPackage ./nix/mirage-wheel.nix {
        inherit manylinux-env mirage-src system;
        repairMode = "none";
      };
    });

    apps = forAllSystems (system: let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          cudaSupport = true;
          allowUnfree = true;
        };
      };
      cudaPackages = pkgs.cudaPackages_12_9;

      buildWheel = pkgs.writeShellApplication {
        name = "build-mirage-manylinux-wheel";
        checkPhase = "";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.nix
        ];
        text = ''
          SRC="''${MIRAGE_SRC:-${toString mirage-src}}"
          OUT_DIR="''${OUT_DIR:-$PWD/dist}"
          TARGET="''${MANYLINUX_TARGET:-manylinux_2_28_candidate}"
          REPAIR_MODE="''${REPAIR_MODE:-none}"
          cuda_home="${cudaPackages.cudatoolkit}"

          workdir=$(mktemp -d)
          cleanup() {
            rm -rf "$workdir"
          }
          trap cleanup EXIT

          setup_hook="$workdir/manylinux-build-setup.sh"
          cat > "$setup_hook" <<'HOOK'
          cuda_home="${cudaPackages.cudatoolkit}"
          py_ver="$("$NIX_MANYLINUX_PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
          venv_site="$PWD/.venv/lib/python$py_ver/site-packages"
          wrapper_dir="$workdir/wrappers"
          mkdir -p "$wrapper_dir"
          cat > "$wrapper_dir/cargo" <<'CARGO'
          #!${pkgs.bash}/bin/bash
          set -euo pipefail

          real_cargo="${pkgs.cargo}/bin/cargo"
          rust_target="''${MANYLINUX_RUST_TARGET:-x86_64-unknown-linux-gnu.2.28}"

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

            if [ -n "$target_dir" ] && [ -d "$target_dir/x86_64-unknown-linux-gnu/release" ]; then
              mkdir -p "$target_dir/release"
              cp -a "$target_dir/x86_64-unknown-linux-gnu/release"/lib*.so "$target_dir/release/" 2>/dev/null || true
            fi
            exit 0
          fi

          exec "$real_cargo" "$@"
          CARGO
          chmod +x "$wrapper_dir/cargo"

          export PATH="$wrapper_dir:$cuda_home/bin:${pkgs.rustc}/bin:${pkgs.cargo}/bin:$PATH"
          export CUDA_HOME="$cuda_home"
          export CUDACXX="$cuda_home/bin/nvcc"
          export CMAKE_BUILD_TYPE="Release"
          export CPATH="$cuda_home/include"
          export Z3_LIBRARY_PATH="$venv_site/z3/lib"
          export LIBRARY_PATH="$cuda_home/lib/stubs''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export LD_LIBRARY_PATH="$venv_site/z3/lib:${pkgs.stdenv.cc.cc.lib}/lib:$cuda_home/lib/stubs''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          HOOK

          mkdir -p "$OUT_DIR"
          export NIX_MANYLINUX_BUILD_SETUP="$setup_hook"
          exec ${manylinux-env}/scripts/build_external_package.sh \
            --repair-mode "$REPAIR_MODE" \
            "$TARGET" \
            "$SRC" \
            "$OUT_DIR" \
            setuptools \
            wheel \
            auditwheel \
            build \
            cython \
            cmake \
            'z3-solver==4.16'
        '';
      };
    in {
      default = {
        type = "app";
        program = "${buildWheel}/bin/build-mirage-manylinux-wheel";
      };
      build-wheel = {
        type = "app";
        program = "${buildWheel}/bin/build-mirage-manylinux-wheel";
      };
    });
  };
}
