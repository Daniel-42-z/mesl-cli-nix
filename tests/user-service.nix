{ pkgs, module }:
let
  coreScript = pkgs.writeText "mesl-test-core.py" ''
    import fcntl
    import os
    import signal
    import socket

    tunFd = os.open("/dev/net/tun", os.O_RDWR)
    fcntl.ioctl(tunFd, 0x400454ca, b"mesl-user-test\0".ljust(16, b"\0") + b"\x01\x10")
    controller = socket.socket()
    controller.bind(("127.0.0.1", 9688))
    controller.listen()
    print("ready", flush=True)
    signal.pause()
  '';
  clientScript = pkgs.writeText "mesl-test-client.py" ''
    import os
    import pathlib
    import signal
    import subprocess
    import sys

    dataDir = pathlib.Path.home() / ".config/mesl"
    arguments = sys.argv[1:]
    if "--data-dir" in arguments:
        dataDir = pathlib.Path(arguments[arguments.index("--data-dir") + 1])
    dataDir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if arguments[0] == "down":
        (dataDir / "cleanup").touch()
        sys.exit(0)
    assert os.getuid() == 1000
    assert "--tun" in arguments
    core = subprocess.Popen([os.environ["MESL_CORE"]], stdout=subprocess.PIPE, text=True)
    try:
        assert core.stdout.readline().strip() == "ready"
        # Reproduce MESL's controller-ownership check. A client without the
        # core's capabilities gets EACCES here even with the same UID.
        socketLinks = [str(fdPath.readlink()) for fdPath in pathlib.Path(f"/proc/{core.pid}/fd").iterdir()]
        assert any(link.startswith("socket:[") for link in socketLinks)
        (dataDir / "ready").touch()

        def Stop(signum, frame):
            sys.exit(0)

        signal.signal(signal.SIGTERM, Stop)
        while True:
            signal.pause()
    finally:
        core.terminate()
        core.wait()
  '';
  MakeLauncher =
    script:
    pkgs.writeText "mesl-test-launcher.c" ''
      #include <unistd.h>
      #include <stdlib.h>

      int main(int argc, char **argv) {
        char **arguments = calloc(argc + 2, sizeof(char *));
        arguments[0] = "${pkgs.python3}/bin/python3";
        arguments[1] = "${script}";
        for (int index = 1; index < argc; index++) arguments[index + 1] = argv[index];
        execv(arguments[0], arguments);
        return 1;
      }
    '';
  stubPackage = pkgs.runCommand "mesl-user-test" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p "$out/bin" "$out/libexec/mesl"
    cc ${MakeLauncher clientScript} -o "$out/libexec/mesl/mesl-cli"
    cc ${MakeLauncher coreScript} -o "$out/libexec/mesl/mihomo"
    ln -s ../libexec/mesl/mesl-cli "$out/bin/mesl-cli"
  '';
in
pkgs.testers.runNixOSTest {
  name = "mesl-user-service";
  nodes.machine = {
    imports = [ module ];
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    users.users.bob.isNormalUser = true;
    services.mesl = {
      enable = true;
      user = "alice";
      package = stubPackage;
      autoStart = true;
      tun.enable = true;
    };
    system.stateVersion = "26.05";
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("user@1000.service")
    machine.wait_until_succeeds("test -f /home/alice/.config/mesl/ready")
    machine.succeed("ip link show mesl-user-test")
    machine.fail("runuser -u bob -- /run/wrappers/bin/mesl-client down")
    machine.fail("runuser -u bob -- /run/wrappers/bin/mesl-mihomo")
    machine.succeed("runuser -u alice -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop mesl")
    machine.succeed("test -f /home/alice/.config/mesl/cleanup")
    machine.fail("ip link show mesl-user-test")
    # The original wrapper arrangement must fail the socket inspection.
    machine.fail("runuser -u alice -- env MESL_CORE=/run/wrappers/bin/mesl-mihomo ${stubPackage}/bin/mesl-cli daemon --tun")
    machine.succeed("rm /home/alice/.config/mesl/ready")
    machine.succeed("runuser -u alice -- mesl-cli daemon --tun > /home/alice/manual.log 2>&1 &")
    machine.wait_until_succeeds("test -f /home/alice/.config/mesl/ready")
    machine.succeed("ip link show mesl-user-test")
    machine.succeed("pkill -TERM -u alice -f mesl-test-client.py")
    machine.wait_until_fails("ip link show mesl-user-test")
  '';
}
