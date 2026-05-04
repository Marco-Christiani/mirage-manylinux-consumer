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
      url = "git+https://github.com/Marco-Christiani/mirage.git?ref=marco/ci-infra-fixes&submodules=1";
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
    pythonTargets = {
      cp312 = {
        pythonAttr = "python312";
        pythonImage = "python:3.12-slim";
      };
      cp313 = {
        pythonAttr = "python313";
        pythonImage = "python:3.13-slim";
      };
    };
    policyTargetNames = {
      manylinux_2_28 = "manylinux_2_28_candidate";
      manylinux_2_34 = "manylinux_2_34_candidate";
    };
    cudaTargets = {
      cuda128.cudaAttr = "cudaPackages_12_8";
      cuda129.cudaAttr = "cudaPackages_12_9";
    };
    releaseTargets = builtins.listToAttrs (
      builtins.concatMap (
        pyName:
          builtins.concatMap (
            policyName:
              map (cudaName: let
                py = pythonTargets.${pyName};
                policyTargetAttr = policyTargetNames.${policyName};
                cuda = cudaTargets.${cudaName};
              in {
                name = "${pyName}-${policyName}-${cudaName}";
                value = py // {inherit policyTargetAttr;} // cuda;
              })
              (builtins.attrNames cudaTargets)
          )
          (builtins.attrNames policyTargetNames)
      )
      (builtins.attrNames pythonTargets)
    );
    forAllSystems = f:
      builtins.listToAttrs (
        map (system: {
          name = system;
          value = f system;
        })
        systems
      );
    mkPkgs = system:
      import nixpkgs {
        inherit system;
        config = {
          cudaSupport = true;
          allowUnfree = true;
        };
      };
  in {
    apps = forAllSystems (system: let
      pkgs = mkPkgs system;
      verifyMirageWheel = pkgs.writeShellApplication {
        name = "verify-mirage-wheel";
        text = ''
          exec ${manylinux-env.packages.${system}.verifyWheelInContainer}/bin/verify-wheel-in-container \
            "$@" \
            --dependency z3-solver \
            --dependency numpy \
            --dependency torch \
            --dependency graphviz \
            --import-code 'import mirage; from mirage import *; print("mirage", "DTensor" in globals())'
        '';
      };
    in {
      verify-mirage-wheel = {
        type = "app";
        program = "${verifyMirageWheel}/bin/verify-mirage-wheel";
        meta.description = "Verify a Mirage wheel in a Python container with Mirage runtime dependencies";
      };
    });

    packages = forAllSystems (system: let
      pkgs = mkPkgs system;
      manylinuxTargets = manylinux-env.legacyPackages.${system}.buildTargets;
      mkMirageWheel = target: let
        manylinuxTarget = manylinuxTargets.${target.policyTargetAttr};
      in
        import ./nix/mirage-wheel.nix {
          inherit pkgs manylinux-env mirage-src system;
          inherit (pkgs) lib;
          inherit (manylinuxTarget) targetAttr targetShell rustTarget;
          cudaPackages = pkgs.${target.cudaAttr};
          pythonInterpreter = pkgs.${target.pythonAttr};
          repairMode = target.repairMode or "target";
        };
      defaultTarget = {
        pythonAttr = "python312";
        policyTargetAttr = "manylinux_2_28_candidate";
        cudaAttr = "cudaPackages_12_9";
      };
    in
      {
        default = self.packages.${system}.mirage-wheel;
        mirage-wheel = mkMirageWheel defaultTarget;
        mirage-wheel-raw = mkMirageWheel (defaultTarget // {repairMode = "none";});
      }
      // builtins.mapAttrs (
        _: mkMirageWheel
      )
      releaseTargets
      // builtins.mapAttrs (
        name: target: mkMirageWheel (target // {repairMode = "none";})
      )
      (builtins.listToAttrs (
        map (name: {
          name = "${name}-raw";
          value = releaseTargets.${name};
        }) (builtins.attrNames releaseTargets)
      )));
  };
}
