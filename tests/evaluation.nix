{ pkgs, nixosModules }:
let
  lib = pkgs.lib;
  Evaluate =
    settings:
    (import (pkgs.path + "/nixos/lib/eval-config.nix") {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        nixosModules.default
        {
          nixpkgs.pkgs = pkgs;
          system.stateVersion = "26.05";
          services.mesl = settings;
        }
      ];
    }).config;
  disabled = Evaluate { };
  manual = Evaluate { enable = true; };
  automatic = Evaluate {
    enable = true;
    autoStart = true;
  };
  tun = Evaluate {
    enable = true;
    tun.enable = true;
  };
in
assert !(disabled.systemd.services ? mesl);
assert !(builtins.elem "tun" disabled.boot.kernelModules);
assert manual.systemd.services.mesl.wantedBy == [ ];
assert automatic.systemd.services.mesl.wantedBy == [ "multi-user.target" ];
assert !(lib.hasInfix "--tun" manual.systemd.services.mesl.serviceConfig.ExecStart);
assert lib.hasInfix "--tun" tun.systemd.services.mesl.serviceConfig.ExecStart;
assert builtins.elem "tun" tun.boot.kernelModules;
assert tun.systemd.services.mesl.serviceConfig.DeviceAllow == [ "/dev/net/tun rw" ];
assert manual.systemd.services.mesl.serviceConfig.StateDirectoryMode == "0700";
assert
  builtins.length manual.environment.systemPackages
  > builtins.length disabled.environment.systemPackages;
pkgs.runCommand "mesl-module-evaluation" { } ''touch "$out"''
