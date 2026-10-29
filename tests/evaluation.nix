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
          users.users.alice.isNormalUser = true;
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
  userManual = Evaluate {
    enable = true;
    user = "alice";
  };
  userTun = Evaluate {
    enable = true;
    user = "alice";
    autoStart = true;
    tun.enable = true;
  };
  guarded = Evaluate {
    enable = true;
    tun.enable = true;
    killSwitch.enable = true;
  };
  userGuarded = Evaluate {
    enable = true;
    user = "alice";
    tun.enable = true;
    killSwitch.enable = true;
  };
  invalidGuard = Evaluate {
    enable = true;
    killSwitch.enable = true;
  };
  invalidUser = Evaluate {
    enable = true;
    user = "missing-user";
  };
  FindClient =
    evaluatedConfig:
    lib.findFirst (
      package: (package.name or "") == "mesl-cli-system"
    ) (throw "MESL launcher missing") evaluatedConfig.environment.systemPackages;
  userClient = FindClient userTun;
  manualClient = FindClient userManual;
  rootClient = FindClient manual;
in
assert !(disabled.systemd.services ? mesl);
assert !manual.services.mesl.killSwitch.enable;
assert !(manual.systemd.services ? mesl-guard);
assert guarded.systemd.services.mesl.serviceConfig.Restart == "always";
assert builtins.length guarded.systemd.services.mesl.serviceConfig.ExecStartPre == 1;
assert builtins.any (
  rule:
  rule.users == [ "alice" ]
  && builtins.any (
    command: lib.hasSuffix "/bin/mesl-guard arm" command.command && command.options == [ "NOPASSWD" ]
  ) rule.commands
) userGuarded.security.sudo.extraRules;
assert builtins.length userGuarded.systemd.user.services.mesl.serviceConfig.ExecStartPre == 1;
assert builtins.any (
  check: lib.hasPrefix "services.mesl.killSwitch" check.message && !check.assertion
) invalidGuard.assertions;
assert !(builtins.elem "tun" disabled.boot.kernelModules);
assert manual.systemd.services.mesl.wantedBy == [ ];
assert automatic.systemd.services.mesl.wantedBy == [ "multi-user.target" ];
assert !(lib.hasInfix "--tun" manual.systemd.services.mesl.serviceConfig.ExecStart);
assert lib.hasInfix "--tun" tun.systemd.services.mesl.serviceConfig.ExecStart;
assert builtins.elem "tun" tun.boot.kernelModules;
assert tun.systemd.services.mesl.serviceConfig.DeviceAllow == [ "/dev/net/tun rw" ];
assert manual.systemd.services.mesl.serviceConfig.StateDirectoryMode == "0700";
assert !(userManual.systemd.services ? mesl);
assert userManual.systemd.user.services.mesl.wantedBy == [ ];
assert userManual.users.users.alice.linger == null;
assert !(userManual.security.wrappers ? mesl-mihomo);
assert !(userManual.security.wrappers ? mesl-client);
assert userManual.systemd.user.services.mesl.serviceConfig.NoNewPrivileges;
assert userTun.systemd.user.services.mesl.wantedBy == [ "default.target" ];
assert userTun.systemd.user.services.mesl.unitConfig.ConditionUser == "alice";
assert userTun.users.manageLingering && userTun.users.users.alice.linger;
assert userTun.users.groups.mesl.members == [ "alice" ];
assert userTun.security.wrappers.mesl-mihomo.capabilities == "cap_net_admin+ep";
assert userTun.security.wrappers.mesl-mihomo.owner == "root";
assert userTun.security.wrappers.mesl-mihomo.group == "mesl";
assert userTun.security.wrappers.mesl-mihomo.permissions == "u=rx,g=rx,o=";
assert userTun.security.wrappers.mesl-client.capabilities == "cap_net_admin+ep";
assert userTun.security.wrappers.mesl-client.owner == "root";
assert userTun.security.wrappers.mesl-client.group == "mesl";
assert userTun.security.wrappers.mesl-client.permissions == "u=rx,g=rx,o=";
assert
  userTun.security.wrappers.mesl-client.source
  == "${userTun.services.mesl.package}/libexec/mesl/mesl-cli";
assert
  userTun.security.wrappers.mesl-mihomo.source
  == "${userTun.services.mesl.package}/libexec/mesl/mihomo";
assert !(userTun.systemd.user.services.mesl.serviceConfig.NoNewPrivileges);
assert lib.hasInfix "--data-dir %h/.config/mesl"
  userTun.systemd.user.services.mesl.serviceConfig.ExecStart;
assert lib.hasInfix "--tun" userTun.systemd.user.services.mesl.serviceConfig.ExecStart;
assert !(lib.hasInfix "--tun" userManual.systemd.user.services.mesl.serviceConfig.ExecStart);
assert builtins.any (
  check: lib.hasPrefix "services.mesl.user" check.message && !check.assertion
) invalidUser.assertions;
assert
  builtins.length manual.environment.systemPackages
  > builtins.length disabled.environment.systemPackages;
pkgs.runCommand "mesl-module-evaluation" { } ''
  grep -F '${userTun.security.wrapperDir}/mesl-mihomo' ${lib.getExe userClient}
  grep -F '${userTun.security.wrapperDir}/mesl-client' ${lib.getExe userClient}
  grep -F 'MESL_CORE' ${lib.getExe userClient}
  if grep -F 'MESL_DATA_DIR' ${lib.getExe userClient} ${lib.getExe manualClient}; then
    echo 'User launchers must preserve the upstream data-directory default' >&2
    exit 1
  fi
  grep -F 'MESL_DATA_DIR' ${lib.getExe rootClient}
  grep -F '/var/lib/mesl' ${lib.getExe rootClient}
  touch "$out"
''
