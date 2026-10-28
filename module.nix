{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.mesl;
  clientPackage = pkgs.symlinkJoin {
    name = "mesl-cli-system";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/mesl-cli" \
        --set-default MESL_DATA_DIR /var/lib/mesl
    '';
    meta.mainProgram = "mesl-cli";
  };
  client = lib.getExe clientPackage;
in
{
  options.services.mesl = {
    enable = lib.mkEnableOption "the machine-wide MESL proxy service and command";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "MESL client package, including its bundled Mihomo core and geodata.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start MESL at boot. Log in with sudo mesl-cli login before starting it.";
    };

    tun.enable = lib.mkEnableOption "TUN routing through MESL's bundled Mihomo core";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ clientPackage ];
    boot.kernelModules = lib.optional cfg.tun.enable "tun";

    systemd.services.mesl = {
      description = "MESL proxy client";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      wantedBy = lib.optional cfg.autoStart "multi-user.target";
      startLimitIntervalSec = 0;

      serviceConfig = {
        Type = "simple";
        User = "root";
        StateDirectory = "mesl";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ExecStart =
          "${client} daemon --data-dir /var/lib/mesl --no-proxy" + lib.optionalString cfg.tun.enable " --tun";
        ExecStopPost = "${client} down --data-dir /var/lib/mesl";
        KillSignal = "SIGTERM";
        KillMode = "mixed";
        TimeoutStopSec = 25;
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        # MESL checks /proc/net/tcp and the core's file descriptors before
        # sending its controller secret. Keep the host network and /proc view.
        PrivateNetwork = false;
        PrivateDevices = false;
        DevicePolicy = "closed";
        DeviceAllow = lib.optional cfg.tun.enable "/dev/net/tun rw";
      };
    };
  };
}
