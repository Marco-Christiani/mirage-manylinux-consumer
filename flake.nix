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
    policyTargets = {
      manylinux_2_28 = {
        targetAttr = "manylinux_2_28_candidate";
        rustTarget = "x86_64-unknown-linux-gnu.2.28";
      };
      manylinux_2_34 = {
        targetAttr = "manylinux_2_34_candidate";
        rustTarget = "x86_64-unknown-linux-gnu.2.34";
      };
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
                policy = policyTargets.${policyName};
                cuda = cudaTargets.${cudaName};
              in {
                name = "${pyName}-${policyName}-${cudaName}";
                value = py // policy // cuda;
              })
              (builtins.attrNames cudaTargets)
          )
          (builtins.attrNames policyTargets)
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
    packages = forAllSystems (system: let
      pkgs = mkPkgs system;
      mkMirageWheel = target:
        import ./nix/mirage-wheel.nix {
          inherit pkgs manylinux-env mirage-src system;
          inherit (pkgs) lib;
          inherit (target) targetAttr rustTarget;
          cudaPackages = pkgs.${target.cudaAttr};
          pythonInterpreter = pkgs.${target.pythonAttr};
          repairMode = target.repairMode or "target";
        };
      defaultTarget = {
        pythonAttr = "python312";
        targetAttr = "manylinux_2_28_candidate";
        cudaAttr = "cudaPackages_12_9";
        rustTarget = "x86_64-unknown-linux-gnu.2.28";
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
