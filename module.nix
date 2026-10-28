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
  commonServiceConfig = {
    Type = "simple";
    UMask = "0077";
    KillSignal = "SIGTERM";
    KillMode = "mixed";
    TimeoutStopSec = 25;
    Restart = "on-failure";
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

    tun.enable = lib.mkEnableOption "TUN routing through MESL's bundled Mihomo core";
  };

  config = lib.mkIf cfg.enable (
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
      (lib.mkIf (!userMode) {
        systemd.services.mesl = {
          description = "MESL proxy client";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          wantedBy = lib.optional cfg.autoStart "multi-user.target";
          startLimitIntervalSec = 0;

          serviceConfig = commonServiceConfig // {
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
  );
}
