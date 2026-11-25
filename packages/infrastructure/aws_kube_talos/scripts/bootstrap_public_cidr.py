#!/usr/bin/env python3
"""Detect the public IPv4 address of the runner managing a new cluster."""

import ipaddress
import json
import sys
import urllib.request


def operator_cidr():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open("https://checkip.amazonaws.com", timeout=5) as response:
        address = ipaddress.IPv4Address(response.read(64).decode("ascii").strip())

    if not address.is_global or address.is_multicast:
        raise ValueError("The address is not a public IPv4 address")
    return f"{address}/32"


if __name__ == "__main__":
    try:
        print(json.dumps({"operator_cidr": operator_cidr()}))
    except (OSError, ValueError):
        sys.exit("Cannot detect the Talos runner's public IPv4 address. Set bootstrap_public.operator_cidr or run from a network with direct IPv4 egress.")
