{
  description = "MESL CLI binary packages and NixOS service module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # Only the bundled proprietary client needs unfree permission in our checks.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "mesl-cli";
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          mesl-cli = pkgs.callPackage ./package.nix { };
          update = pkgs.writeShellApplication {
            name = "mesl-update";
            runtimeInputs = [ pkgs.python3 ];
            text = ''exec python3 ${./scripts/update.py} "$@"'';
          };
          default = mesl-cli;
        }
      );

      apps = forAllSystems (system: rec {
        mesl-cli = {
          type = "app";
          program = "${self.packages.${system}.mesl-cli}/bin/mesl-cli";
          meta.description = "MESL command-line proxy client";
        };
        default = mesl-cli;
        update = {
          type = "app";
          program = "${self.packages.${system}.update}/bin/mesl-update";
          meta.description = "Verify and update MESL release metadata";
        };
      });

      nixosModules = rec {
        mesl = import ./module.nix;
        default = mesl;
      };

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          package = self.packages.${system}.mesl-cli;
        in
        {
          package = import ./tests/package.nix { inherit pkgs package; };
          automation = import ./tests/automation.nix {
            inherit pkgs;
            source = self;
          };
          module = import ./tests/evaluation.nix {
            inherit pkgs;
            inherit (self) nixosModules;
          };
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          service = import ./tests/service.nix {
            inherit pkgs;
            module = self.nixosModules.default;
          };
          user-service = import ./tests/user-service.nix {
            inherit pkgs;
            module = self.nixosModules.default;
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);
    };
}
