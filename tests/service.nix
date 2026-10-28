{ pkgs, module }:
let
  stubClient = pkgs.writeScriptBin "mesl-cli" ''
    #!${pkgs.python3}/bin/python3
    import fcntl
    import json
    import os
    import pathlib
    import signal
    import sys

    arguments = sys.argv[1:]
    dataDir = pathlib.Path(os.environ["MESL_DATA_DIR"])
    if "--data-dir" in arguments:
        dataDir = pathlib.Path(arguments[arguments.index("--data-dir") + 1])
    dataDir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if arguments[0] == "down":
        (dataDir / "cleanup").touch()
        sys.exit(0)
    if arguments[0] == "status":
        print(dataDir)
        sys.exit(0)
    assert arguments[0] == "daemon"
    assert "--no-proxy" in arguments
    assert dataDir == pathlib.Path("/var/lib/mesl")
    if "--tun" in arguments:
        tunFd = os.open("/dev/net/tun", os.O_RDWR)
        # TUNSETIFF: create a real interface to exercise device and network access.
        fcntl.ioctl(tunFd, 0x400454ca, b"mesl-test\0".ljust(16, b"\0") + b"\x01\x10")
        (dataDir / "tun-ready").touch()

    def Stop(signum, frame):
        (dataDir / "stopped").touch()
        sys.exit(0)

    signal.signal(signal.SIGTERM, Stop)
    (dataDir / "arguments.json").write_text(json.dumps(arguments))
    while True:
        signal.pause()
  '';
  Configure = autoStart: tun: { ... }: {
    imports = [ module ];
    services.mesl = {
      enable = true;
      package = stubClient;
      inherit autoStart;
      tun.enable = tun;
    };
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "mesl-service";
  nodes = {
    manual = Configure false false;
    automatic = Configure true false;
    tun = Configure true true;
  };
  testScript = ''
    start_all()
    manual.wait_for_unit("multi-user.target")
    manual.fail("systemctl is-active mesl.service")
    manual.succeed("systemctl start mesl.service")
    for machine in (manual, automatic, tun):
        machine.wait_for_unit("mesl.service")
        machine.wait_until_succeeds("test -f /var/lib/mesl/arguments.json")
        machine.succeed("test $(stat -c '%a:%U:%G' /var/lib/mesl) = 700:root:root")
        machine.succeed("test $(stat -c '%a' /var/lib/mesl/arguments.json) = 600")
        machine.succeed("test $(mesl-cli status) = /var/lib/mesl")
    tun.succeed("test -f /var/lib/mesl/tun-ready")
    tun.succeed("ip link show mesl-test")
    manual.succeed("rm /var/lib/mesl/arguments.json; systemctl kill --signal=KILL mesl.service")
    manual.wait_until_succeeds("test $(systemctl show -p NRestarts --value mesl.service) -ge 1")
    manual.wait_for_unit("mesl.service")
    manual.wait_until_succeeds("test -f /var/lib/mesl/arguments.json")
    for machine in (manual, automatic, tun):
        machine.succeed("systemctl stop mesl.service")
        machine.succeed("test -f /var/lib/mesl/stopped; test -f /var/lib/mesl/cleanup")
    tun.fail("ip link show mesl-test")
  '';
}
