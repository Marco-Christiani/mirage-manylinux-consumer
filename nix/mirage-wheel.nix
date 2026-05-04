{
  lib,
  pkgs,
  manylinux-env,
  mirage-src,
  system,
  pythonInterpreter ? pkgs.python312,
  targetAttr ? "manylinux_2_28_candidate",
  targetShell ? manylinux-env.devShells.${system}.${targetAttr},
  cudaPackages ? pkgs.cudaPackages_12_9,
  rustTarget ? "x86_64-unknown-linux-gnu.2.28",
  repairMode ? "target",
}: let
  cargoWrapper = import ./mirage-cargo-wrapper.nix {
    inherit pkgs rustTarget;
  };
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
      cudaPackages.cudatoolkit
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
      # TODO(upstream): remove when Mirage stops committing generated egg-info.
      # Stale egg-info can force the wrong wheel tag, e.g. cp312 metadata in a cp313 build.
      rm -rf ./*.egg-info python/*.egg-info

      # TODO(upstream): remove when Mirage links the extension against a dynamic/system Z3.
      # This lets the Nix build use the vendored z3-solver wheel location explicitly.
      substituteInPlace setup.py \
        --replace-fail \
          'z3_path = path.dirname(z3.__file__)' \
          'z3_path = os.environ.get("Z3_ROOT", path.dirname(z3.__file__))'

      # TODO(upstream): remove when Mirage no longer injects build-tree rpaths for Rust cdylibs.
      # Those rpaths are not redistributable and break auditwheel repair.
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
      export CUDA_HOME="${cudaPackages.cudatoolkit}"
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

      # TODO(upstream): remove when Mirage's Rust subbuilds expose their cdylibs in
      # the locations expected by setup.py without a cargo wrapper.
      export PATH="${cargoWrapper}/bin:$CUDA_HOME/bin:${pkgs.rustc}/bin:${pkgs.cargo}/bin:$PATH"
    '';

    meta = {
      description = "Mirage wheel built inside the nix-manylinux-envs ${targetAttr} builder";
      platforms = ["x86_64-linux"];
    };
  }
