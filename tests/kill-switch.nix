{ pkgs, module }:
let
  clientScript = pkgs.writeText "mesl-guard-test.py" ''
    import os
    import pathlib
    import subprocess
    import sys
    import time

    if sys.argv[1] == "down":
        sys.exit(0)
    if pathlib.Path("/tmp/mesl-fail").exists():
        sys.exit(1)
    while True:
        result = subprocess.run(["${pkgs.curl}/bin/curl", "--noproxy", "*", "--max-time", "2", "-fsS", "http://203.0.113.1:8000"], stdout=subprocess.DEVNULL)
        if result.returncode == 0:
            pathlib.Path(f"/tmp/mesl-ready-{os.getuid()}").touch()
        time.sleep(0.2)
  '';
  stubPackage = pkgs.runCommand "mesl-guard-test" { nativeBuildInputs = [ pkgs.stdenv.cc ]; } ''
    mkdir -p "$out/bin" "$out/libexec/mesl"
    cat > launcher.c <<'C'
    #include <unistd.h>
    #include <stdlib.h>
    int main(int argc, char **argv) {
      char **arguments = calloc(argc + 2, sizeof(char *));
      arguments[0] = "${pkgs.python3}/bin/python3";
      arguments[1] = "${clientScript}";
      for (int index = 1; index < argc; index++) arguments[index + 1] = argv[index];
      execv(arguments[0], arguments);
      return 1;
    }
    C
    cc launcher.c -o "$out/libexec/mesl/mesl-cli"
    cp "$out/libexec/mesl/mesl-cli" "$out/libexec/mesl/mihomo"
    ln -s ../libexec/mesl/mesl-cli "$out/bin/mesl-cli"
  '';
  echoScript = pkgs.writeText "mesl-echo-test.py" ''
    import socket

    connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    connection.bind(("203.0.113.1", 8002))
    while True:
        payload, address = connection.recvfrom(1024)
        connection.sendto(payload, address)
  '';
  existingProbe = pkgs.writeScriptBin "mesl-existing-probe" ''
    #!${pkgs.python3}/bin/python3
    import pathlib
    import socket
    import time

    connection = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    connection.settimeout(0.3)
    connection.connect(("203.0.113.1", 8002))
    receivedCount = 0
    while True:
        try:
            connection.send(b"probe")
            connection.recv(1024)
            receivedCount += 1
            pathlib.Path("/tmp/mesl-packets").write_text(str(receivedCount))
        except OSError:
            pass
        time.sleep(0.1)
  '';
  MakeNode = user: {
    imports = [ module ];
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
    };
    services.mesl = {
      enable = true;
      inherit user;
      package = stubPackage;
      tun.enable = true;
      killSwitch.enable = true;
    };
    environment.systemPackages = [
      pkgs.curl
      existingProbe
    ];
    networking.firewall.enable = false;
    networking.nftables = {
      enable = true;
      flushRuleset = false;
      tables.test = {
        family = "inet";
        content = "chain harmless { }";
      };
    };
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "mesl-kill-switch";
  nodes = {
    root = MakeNode null;
    user = MakeNode "alice";
    boot = pkgs.lib.recursiveUpdate (MakeNode null) {
      services.mesl.autoStart = true;
    };
    server = { pkgs, ... }: {
      networking.firewall.enable = false;
      systemd.services.echo = {
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${echoScript}";
      };
      systemd.services.web = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /tmp";
      };
      system.stateVersion = "26.05";
    };
  };
  testScript = ''
    start_all()
    for machine in [boot, root, user, server]:
        machine.wait_for_unit("multi-user.target")
        machine.wait_until_succeeds("ip -4 -o addr show dev eth1 | grep -q 'inet '")
    serverIp = server.succeed("ip -4 -o addr show dev eth1").split()[3].split("/")[0]
    server.succeed("ip addr add 203.0.113.1/32 dev lo")
    server.succeed("systemctl start echo")
    server.succeed("ip -6 addr add 2001:db8:99::1/64 dev eth1")
    server.wait_for_unit("web.service")
    boot.wait_for_unit("mesl-guard.service")
    boot.succeed("ip route add 203.0.113.1/32 via " + serverIp)
    boot.fail("curl --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8000")
    boot.wait_until_succeeds("test -f /tmp/mesl-ready-0")
    boot.succeed("mesl-guard stop")
    for machine, uid, serviceCommand in [
        (root, 0, "systemctl"),
        (user, 1000, "runuser -u alice -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user"),
    ]:
        machine.succeed("ip route add 203.0.113.1/32 via " + serverIp)
        probe = "curl --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8000 >/dev/null"
        machine.wait_until_succeeds(probe)
        machine.succeed(f"ip -6 addr add 2001:db8:99::{uid + 10}/64 dev eth1")
        ipv6Probe = "ping -6 -c 1 -W 2 2001:db8:99::1"
        machine.wait_until_succeeds(ipv6Probe)
        machine.succeed("ip netns add guest")
        machine.succeed("ip link add guard-host type veth peer name guard-guest")
        machine.succeed("ip link set guard-guest netns guest")
        machine.succeed("ip addr add 172.31.0.1/24 dev guard-host; ip link set guard-host up")
        machine.succeed("ip -n guest addr add 172.31.0.2/24 dev guard-guest; ip -n guest link set guard-guest up; ip -n guest link set lo up; ip -n guest route add default via 172.31.0.1")
        machine.succeed("sysctl -w net.ipv4.ip_forward=1")
        server.succeed("ip route replace 172.31.0.0/24 via " + machine.succeed("ip -4 -o addr show dev eth1").split()[3].split("/")[0])
        forwardedProbe = "ip netns exec guest " + probe
        machine.succeed(forwardedProbe)
        machine.succeed("mesl-existing-probe >/tmp/mesl-existing-probe.log 2>&1 &")
        machine.wait_until_succeeds("test -s /tmp/mesl-packets")
        machine.succeed("mesl-guard start")
        machine.wait_until_succeeds(f"test -f /tmp/mesl-ready-{uid}")
        machine.fail(probe)
        receivedCount = machine.succeed("cat /tmp/mesl-packets")
        machine.fail(ipv6Probe)
        machine.fail(forwardedProbe)
        assert machine.succeed("cat /tmp/mesl-packets") == receivedCount
        machine.fail("runuser -u alice -- " + probe)
        machine.succeed("curl --noproxy '*' --max-time 2 -fsS http://" + serverIp + ":8000 >/dev/null")
        machine.fail("runuser -u alice -- mesl-guard arm")
        machine.succeed(serviceCommand + " kill --signal=SIGKILL --kill-whom=all mesl")
        machine.fail(probe)
        machine.succeed(f"rm -f /tmp/mesl-ready-{uid}")
        machine.wait_until_succeeds(f"test -f /tmp/mesl-ready-{uid}")
        machine.fail(probe)
        machine.succeed(serviceCommand + " stop mesl")
        machine.fail(probe)
        machine.succeed("systemctl reload nftables")
        machine.fail(probe)
        machine.succeed("systemctl restart mesl-guard")
        machine.fail(probe)
        machine.succeed("mesl-guard stop")
        machine.succeed(probe)
        machine.succeed(ipv6Probe)
        machine.succeed(forwardedProbe)
        machine.succeed(f"rm -f /tmp/mesl-ready-{uid}")
        machine.succeed("touch /tmp/mesl-fail")
        machine.succeed("mesl-guard start")
        machine.fail(probe)
        machine.succeed("rm /tmp/mesl-fail")
        machine.wait_until_succeeds(f"test -f /tmp/mesl-ready-{uid}")
        machine.succeed("mesl-guard start")
        machine.fail(probe)
        machine.succeed(serviceCommand + " kill --signal=SIGKILL --kill-whom=all mesl")
        machine.succeed("mesl-guard stop")
        machine.succeed(probe)
  '';
}
