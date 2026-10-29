"""Privileged, configuration-specific MESL firewall controller."""

import fcntl
import json
import os
import pathlib
import pwd
import subprocess
import sys


def Run(arguments, **kwargs):
    return subprocess.run(arguments, check=True, **kwargs)


def Main():
    settings = json.loads(pathlib.Path(sys.argv[1]).read_text())
    action = sys.argv[2] if len(sys.argv) == 3 else ""
    if os.geteuid() != 0 or action not in {"boot", "arm", "start", "stop", "status"}:
        sys.exit("Run sudo mesl-guard {start|stop|status}")
    userName = settings["user"]
    userId = pwd.getpwnam(userName).pw_uid
    cgroupPath = (
        f"user.slice/user-{userId}.slice/user@{userId}.service/app.slice/mesl.service"
        if userName != "root"
        else "system.slice/mesl.service"
    )
    serviceCommand = [settings["systemctl"]]
    if userName != "root":
        serviceCommand = [
            settings["runuser"],
            "-u",
            userName,
            "--",
            settings["env"],
            f"XDG_RUNTIME_DIR=/run/user/{userId}",
            f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{userId}/bus",
            settings["systemctl"],
            "--user",
        ]
    runtimeDir = pathlib.Path("/run/mesl-guard")
    runtimeDir.mkdir(mode=0o700, exist_ok=True)

    def UpdateRules(allowService=False, preserve=False):
        with (runtimeDir / "rules.lock").open("w") as lockFile:
            fcntl.flock(lockFile, fcntl.LOCK_EX)
            exists = (
                subprocess.run(
                    [settings["nft"], "list", "table", "inet", "mesl_guard"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                ).returncode
                == 0
            )
            if preserve and exists:
                return
            rules = "destroy table inet mesl_guard\n"
            rules += "table inet mesl_guard {\n"
            rules += (
                "chain output { type filter hook output priority 10; policy drop;\n"
            )
            rules += 'oifname "lo" accept\n'
            rules += f"oifname {json.dumps(settings['interface'])} accept\n"
            if allowService:
                depth = len(cgroupPath.split("/"))
                rules += f'socket cgroupv2 level {depth} "{cgroupPath}" accept\n'
            rules += "jump local_network\n}\n"
            rules += (
                "chain forward { type filter hook forward priority 10; policy drop;\n"
            )
            rules += f"oifname {json.dumps(settings['interface'])} accept\n"
            # Replies from the tunnel are safe; established physical-interface
            # connections deliberately do not receive a general exemption.
            rules += f"iifname {json.dumps(settings['interface'])} ct state established,related accept\n"
            rules += "jump local_network\n}\n"
            rules += "chain local_network {\n"
            rules += "ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } accept\n"
            rules += "ip6 daddr { fc00::/7, fe80::/10 } accept\n"
            rules += "udp sport 68 udp dport 67 ip daddr 255.255.255.255 accept\n"
            rules += "ip6 hoplimit 255 meta l4proto ipv6-icmp icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept\n"
            rules += "ip6 daddr ff02::1:2 udp sport 546 udp dport 547 accept\n"
            rules += "}\n}\n"
            Run([settings["nft"], "-f", "-"], input=rules, text=True)

    if action == "arm":
        # sudo retains the caller's cgroup. Never accept a caller-supplied
        # cgroup or exempt the whole selected UID.
        actualCgroup = pathlib.Path("/proc/self/cgroup").read_text().strip()
        if actualCgroup != f"0::/{cgroupPath}":
            sys.exit("arm may only run inside the configured MESL service")
        UpdateRules(allowService=True)
        return
    if action == "boot":
        UpdateRules(preserve=True)
        return
    if action == "status":
        Run([settings["nft"], "list", "table", "inet", "mesl_guard"])
        return
    with (runtimeDir / "control.lock").open("w") as lockFile:
        fcntl.flock(lockFile, fcntl.LOCK_EX)
        if action == "start":
            UpdateRules(preserve=True)
            if userName != "root":
                Run([settings["systemctl"], "start", f"user@{userId}.service"])
            Run(serviceCommand + ["start", "mesl.service"])
        else:
            Run(serviceCommand + ["stop", "mesl.service"])
            with (runtimeDir / "rules.lock").open("w") as rulesLock:
                fcntl.flock(rulesLock, fcntl.LOCK_EX)
                # A concurrent ordinary start either arms after this transaction,
                # or is already visible here; never disarm a running service.
                result = Run(
                    serviceCommand
                    + ["show", "mesl.service", "--property=ActiveState", "--value"],
                    capture_output=True,
                    text=True,
                )
                if result.stdout.strip() not in {"inactive", "failed"}:
                    sys.exit("MESL is starting or running; keeping the guard armed")
                if pathlib.Path("/sys/fs/cgroup", cgroupPath, "cgroup.events").exists():
                    events = pathlib.Path(
                        "/sys/fs/cgroup", cgroupPath, "cgroup.events"
                    ).read_text()
                    if "populated 1" in events:
                        sys.exit("MESL processes remain; keeping the guard armed")
                Run([settings["nft"], "destroy", "table", "inet", "mesl_guard"])


if __name__ == "__main__":
    Main()
