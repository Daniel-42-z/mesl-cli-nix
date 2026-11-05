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
  localProbe = pkgs.writeShellScriptBin "mesl-local-probe" ''
    exec ${pkgs.python3}/bin/python3 ${./local-network.py} "$@"
  '';
  invalidSettings = pkgs.writeText "mesl-invalid-subnets.json" (
    builtins.toJSON {
      extraAllowedSubnets = [ "192.168.0.0/16; accept" ];
    }
  );
  scopedSettings = pkgs.writeText "mesl-scoped-subnets.json" (
    builtins.toJSON {
      extraAllowedSubnets = [ "fe80::1%eth0/128" ];
    }
  );
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
      localProbe
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
      services.mesl.killSwitch = {
        allowedDiscoveryProtocols = [ ];
        allowUdpBroadcast = false;
        extraAllowedSubnets = [
          "203.0.113.3/31"
          "2001:db8:99::2/128"
        ];
      };
    };
    server = { pkgs, ... }: {
      networking.firewall.enable = false;
      systemd.services.discovery = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${localProbe}/bin/mesl-local-probe receive";
      };
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
    server.succeed("ip addr add 203.0.113.2/32 dev lo")
    server.succeed("systemctl start echo")
    server.succeed("ip -6 addr add 2001:db8:99::1/64 dev eth1")
    server.succeed("ip -6 addr add 2001:db8:99::2/64 dev eth1")
    server.wait_for_unit("web.service")
    server.wait_until_succeeds("journalctl -u discovery --no-pager | grep -q ready")

    def CheckLocalTraffic(machine, enabled=True):
        for family, destinations in [
            ("ipv4", [("224.0.0.251", 5353), ("239.255.255.250", 1900), ("239.255.255.250", 3702), ("224.0.0.252", 5355), ("255.255.255.255", 54321)]),
            ("ipv6", [("ff02::fb", 5353), ("ff02::c", 1900), ("ff02::c", 3702), ("ff02::1:3", 5355)]),
        ]:
            for destination, port in destinations:
                command = f"mesl-local-probe send {family} {destination} {port}"
                if enabled:
                    machine.succeed(command)
                else:
                    machine.fail(command)

    boot.wait_for_unit("mesl-guard.service")
    boot.succeed("ip route add 203.0.113.1/32 via " + serverIp)
    boot.fail("curl --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8000")
    boot.wait_until_succeeds("test -f /tmp/mesl-ready-0")
    boot.succeed("mesl-guard stop")
    boot.succeed("ip -6 addr add 2001:db8:99::20/64 dev eth1")
    boot.succeed("ip route add 203.0.113.2/32 via " + serverIp)
    # Verify the peers work without the guard before testing opt-outs.
    CheckLocalTraffic(boot)
    boot.succeed("mesl-guard start")
    CheckLocalTraffic(boot, enabled=False)
    boot.succeed("curl --noproxy '*' --max-time 2 -fsS http://203.0.113.2:8000 >/dev/null")
    boot.wait_until_succeeds("ping -6 -c 1 -W 2 2001:db8:99::2")
    boot.fail("curl --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8000")
    boot.fail("ping -6 -c 1 -W 2 2001:db8:99::1")
    boot.succeed("ip netns add guest")
    boot.succeed("ip link add guard-host type veth peer name guard-guest")
    boot.succeed("ip link set guard-guest netns guest")
    boot.succeed("ip addr add 172.31.1.1/24 dev guard-host; ip link set guard-host up")
    boot.succeed("ip -n guest addr add 172.31.1.2/24 dev guard-guest; ip -n guest link set guard-guest up; ip -n guest link set lo up; ip -n guest route add default via 172.31.1.1")
    boot.succeed("sysctl -w net.ipv4.ip_forward=1")
    server.succeed("ip route add 172.31.1.0/24 via " + boot.succeed("ip -4 -o addr show dev eth1").split()[3].split("/")[0])
    boot.succeed("ip netns exec guest curl --noproxy '*' --max-time 2 -fsS http://203.0.113.2:8000 >/dev/null")
    boot.fail("ip netns exec guest curl --noproxy '*' --max-time 2 -fsS http://203.0.113.1:8000")
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
        CheckLocalTraffic(machine)
        machine.succeed("mesl-local-probe membership")
        machine.wait_until_succeeds("mesl-local-probe check-membership")
        machine.succeed("nft -s list table inet mesl_guard >/tmp/guard-before")
        machine.fail("${pkgs.python3}/bin/python3 ${../guard.py} ${invalidSettings} boot")
        machine.fail("${pkgs.python3}/bin/python3 ${../guard.py} ${scopedSettings} boot")
        machine.succeed("nft -s list table inet mesl_guard | cmp /tmp/guard-before -")
        machine.fail("mesl-local-probe send ipv4 203.0.113.1 8002")
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
        CheckLocalTraffic(machine)
        machine.wait_until_succeeds(f"test -f /tmp/mesl-ready-{uid}")
        machine.fail(probe)
        machine.succeed(serviceCommand + " stop mesl")
        machine.fail(probe)
        machine.succeed("systemctl reload nftables")
        machine.fail(probe)
        machine.succeed("systemctl restart mesl-guard")
        machine.fail(probe)
        CheckLocalTraffic(machine)
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
