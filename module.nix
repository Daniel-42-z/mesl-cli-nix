{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mesl;
  userMode = cfg.user != null;
  selectedUser = if userMode then cfg.user else "root";
  useCapabilityWrapper = userMode && cfg.tun.enable;
  corePath = "${config.security.wrapperDir}/mesl-mihomo";
  capabilityLauncher = pkgs.writeShellScript "mesl-cli" ''
    export MESL_CORE=${lib.escapeShellArg corePath}
    exec ${lib.escapeShellArg "${config.security.wrapperDir}/mesl-client"} "$@"
  '';
  clientPackage = pkgs.symlinkJoin {
    name = "mesl-cli-system";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      ${
        if useCapabilityWrapper then
          ''
            rm "$out/bin/mesl-cli"
            ln -s ${capabilityLauncher} "$out/bin/mesl-cli"
          ''
        else
          ''
            wrapProgram "$out/bin/mesl-cli" ${
              lib.optionalString (!userMode) "--set-default MESL_DATA_DIR /var/lib/mesl"
            }
          ''
      }
    '';
    meta.mainProgram = "mesl-cli";
  };
  client = lib.getExe clientPackage;
  guardSettings = pkgs.writeText "mesl-guard-settings.json" (
    builtins.toJSON {
      user = selectedUser;
      interface = cfg.killSwitch.interface;
      nft = lib.getExe pkgs.nftables;
      systemctl = lib.getExe' pkgs.systemd "systemctl";
      runuser = lib.getExe' pkgs.util-linux "runuser";
      env = lib.getExe' pkgs.coreutils "env";
    }
  );
  guardPackage = pkgs.writeShellScriptBin "mesl-guard" ''
    exec ${lib.getExe pkgs.python3} -I ${./guard.py} ${guardSettings} "$@"
  '';
  guard = lib.getExe guardPackage;
  armCommand =
    if userMode then "${config.security.wrapperDir}/sudo -n -- ${guard} arm" else "${guard} arm";
  commonServiceConfig = {
    Type = "simple";
    UMask = "0077";
    KillSignal = "SIGTERM";
    KillMode = "mixed";
    TimeoutStopSec = 25;
    Restart = if cfg.killSwitch.enable then "always" else "on-failure";
    RestartSec = 5;
    NoNewPrivileges = !useCapabilityWrapper;
    # Preserve the host network and process view used by MESL.
    PrivateNetwork = false;
    PrivateDevices = false;
  };
in
{
  options.services.mesl = {
    enable = lib.mkEnableOption "the MESL proxy service and command";

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "yourusername";
      description = ''
        Existing normal user whose profile and systemd user service MESL uses.
        Null preserves the root system service with state in /var/lib/mesl.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "MESL client package, including its bundled Mihomo core and geodata.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Start MESL at boot. In user mode this enables lingering for the selected
        account. Log in with mesl-cli login as that user first; root mode uses sudo.
      '';
    };

    killSwitch = {
      enable = lib.mkEnableOption "host-wide fail-closed MESL TUN protection";
      interface = lib.mkOption {
        type = lib.types.strMatching "[a-zA-Z0-9_.-]{1,15}";
        default = "Meta";
        description = "MESL TUN interface name allowed by the kill switch.";
      };
    };

    tun.enable = lib.mkEnableOption "TUN routing through MESL's bundled Mihomo core";
  };

  config = lib.mkMerge [
    {
      system.activationScripts.meslGuardCleanup = lib.mkIf (!cfg.enable || !cfg.killSwitch.enable) ''
        if ${lib.getExe pkgs.nftables} list table inet mesl_guard >/dev/null 2>&1; then
          ${lib.getExe pkgs.nftables} destroy table inet mesl_guard
        fi
      '';
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          assertions = [
            {
              assertion = !userMode || (config.users.users.${cfg.user}.isNormalUser or false);
              message = "services.mesl.user must name an existing normal NixOS user.";
            }
          ];
          environment.systemPackages = [ clientPackage ];
          boot.kernelModules = lib.optional cfg.tun.enable "tun";
        }
        (lib.mkIf cfg.killSwitch.enable {
          assertions = [
            {
              assertion = cfg.tun.enable;
              message = "services.mesl.killSwitch.enable requires services.mesl.tun.enable.";
            }
            {
              assertion = !config.networking.nftables.enable || !config.networking.nftables.flushRuleset;
              message = "MESL kill switch requires networking.nftables.flushRuleset = false to preserve its table on reload.";
            }
          ];
          boot.kernelModules = [
            "nf_tables"
            "nft_socket"
          ];
          environment.systemPackages = [ guardPackage ];
          systemd.services.mesl-guard = {
            description = "Arm MESL internet kill switch";
            wantedBy = lib.optional cfg.autoStart "sysinit.target";
            before = [ "network-pre.target" ];
            after = [
              "local-fs.target"
              "systemd-modules-load.service"
            ];
            unitConfig.DefaultDependencies = false;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${guard} boot";
              # Stopping or restarting this unit must never release protection.
            };
          };
          security.sudo.extraRules = lib.optionals userMode [
            {
              users = [ cfg.user ];
              commands = [
                {
                  command = "${guard} arm";
                  options = [ "NOPASSWD" ];
                }
              ];
            }
          ];
        })
        (lib.mkIf (!userMode) {
          systemd.services.mesl = {
            description = "MESL proxy client";
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            wantedBy = lib.optional cfg.autoStart "multi-user.target";
            startLimitIntervalSec = 0;

            serviceConfig = commonServiceConfig // {
              ExecStartPre = lib.optional cfg.killSwitch.enable armCommand;
              User = "root";
              StateDirectory = "mesl";
              StateDirectoryMode = "0700";
              ExecStart =
                "${client} daemon --data-dir /var/lib/mesl --no-proxy" + lib.optionalString cfg.tun.enable " --tun";
              ExecStopPost = "${client} down --data-dir /var/lib/mesl";
              # MESL checks /proc/net/tcp and the core's file descriptors before
              # sending its controller secret. Keep the host network and /proc view.
              DevicePolicy = "closed";
              DeviceAllow = lib.optional cfg.tun.enable "/dev/net/tun rw";
            };
          };
        })
        (lib.mkIf userMode {
          systemd.user.services.mesl = {
            description = "MESL proxy client";
            wantedBy = lib.optional cfg.autoStart "default.target";
            unitConfig = {
              ConditionUser = cfg.user;
              StartLimitIntervalSec = 0;
            };
            serviceConfig = commonServiceConfig // {
              ExecStartPre = lib.optional cfg.killSwitch.enable armCommand;
              ExecStart =
                "${client} daemon --data-dir %h/.config/mesl --no-proxy"
                + lib.optionalString cfg.tun.enable " --tun";
              ExecStopPost = "${client} down --data-dir %h/.config/mesl";
            };
          };
          users.manageLingering = lib.mkIf cfg.autoStart true;
          users.users.${selectedUser}.linger = lib.mkIf cfg.autoStart true;
        })
        (lib.mkIf useCapabilityWrapper {
          users.groups.mesl.members = [ cfg.user ];
          # MESL verifies the controller socket through /proc/<pid>/fd. Linux
          # requires the inspecting process to have the core's capabilities too.
          security.wrappers.mesl-client = {
            source = "${cfg.package}/libexec/mesl/mesl-cli";
            owner = "root";
            group = "mesl";
            permissions = "u=rx,g=rx,o=";
            capabilities = "cap_net_admin+ep";
          };
          security.wrappers.mesl-mihomo = {
            source = "${cfg.package}/libexec/mesl/mihomo";
            owner = "root";
            group = "mesl";
            permissions = "u=rx,g=rx,o=";
            capabilities = "cap_net_admin+ep";
          };
        })
      ]
    ))
  ];
}
