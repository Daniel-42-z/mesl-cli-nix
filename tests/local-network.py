"""UDP discovery peers used only inside the kill-switch VMs."""

import json
import selectors
import socket
import struct
import subprocess
import sys
import time


def OpenSocket(family):
    connection = socket.socket(family, socket.SOCK_DGRAM)
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"eth1")
    return connection


def Join(connection, group):
    interfaceIndex = socket.if_nametoindex("eth1")
    if connection.family == socket.AF_INET:
        membership = struct.pack(
            "=4s4si", socket.inet_aton(group), b"\0" * 4, interfaceIndex
        )
        connection.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)
    else:
        membership = socket.inet_pton(socket.AF_INET6, group) + struct.pack(
            "@I", interfaceIndex
        )
        connection.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, membership)


def Receive():
    selector = selectors.DefaultSelector()
    for family, groups in [
        (
            socket.AF_INET,
            {
                5353: "224.0.0.251",
                1900: "239.255.255.250",
                3702: "239.255.255.250",
                5355: "224.0.0.252",
                54321: None,
            },
        ),
        (
            socket.AF_INET6,
            {5353: "ff02::fb", 1900: "ff02::c", 3702: "ff02::c", 5355: "ff02::1:3"},
        ),
    ]:
        for port, group in groups.items():
            connection = OpenSocket(family)
            if family == socket.AF_INET6:
                connection.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            connection.bind(("0.0.0.0" if family == socket.AF_INET else "::", port))
            if group:
                Join(connection, group)
            selector.register(connection, selectors.EVENT_READ)
    print("ready", flush=True)
    while True:
        for key, _ in selector.select():
            connection = key.fileobj
            payload, address = connection.recvfrom(1024)
            connection.sendto(payload, address)


def Send(familyName, destination, port):
    family = socket.AF_INET if familyName == "ipv4" else socket.AF_INET6
    with OpenSocket(family) as connection:
        connection.settimeout(1)
        if family == socket.AF_INET:
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            address = (destination, int(port))
        else:
            interfaceIndex = socket.if_nametoindex("eth1")
            connection.setsockopt(
                socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, interfaceIndex
            )
            address = (destination, int(port), 0, interfaceIndex)
        connection.sendto(b"guard-local-probe", address)
        assert connection.recv(1024) == b"guard-local-probe"


def Membership():
    with (
        OpenSocket(socket.AF_INET) as ipv4Socket,
        OpenSocket(socket.AF_INET6) as ipv6Socket,
    ):
        Join(ipv4Socket, "239.255.42.42")
        Join(ipv6Socket, "ff02::4242")
        time.sleep(1)


def CheckMembership():
    ruleset = json.loads(
        subprocess.check_output(
            ["nft", "-j", "list", "chain", "inet", "mesl_guard", "output"]
        )
    )
    for protocol in ["igmp", "icmpv6"]:
        matchingRules = [
            item["rule"]
            for item in ruleset["nftables"]
            if "rule" in item and f'"{protocol}"' in json.dumps(item["rule"])
        ]
        assert any(
            expression.get("counter", {}).get("packets", 0) > 0
            for rule in matchingRules
            for expression in rule["expr"]
        ), protocol


if __name__ == "__main__":
    action = sys.argv[1]
    if action == "receive":
        Receive()
    elif action == "send":
        Send(*sys.argv[2:])
    elif action == "membership":
        Membership()
    elif action == "check-membership":
        CheckMembership()
    else:
        sys.exit("Unknown probe action")
