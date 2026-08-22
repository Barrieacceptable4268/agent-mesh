#!/usr/bin/env python3
"""age bech32 → base64 X25519 (für sops --age)."""
import base64
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def bech32_to_raw(s: str) -> bytes:
    s = s.lower().strip()
    if not s.startswith("age1"):
        raise ValueError("kein age1-Prefix")
    data_part = s[4:]                    # nach "age1"
    data_no_checksum = data_part[:-6]    # Checksum (6 Zeichen) abtrennen
    acc = 0
    bits = 0
    out = []
    for c in data_no_checksum:
        acc = (acc << 5) | CHARSET.index(c)
        bits += 5
        if bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
    return bytes(out)


if __name__ == "__main__":
    pub = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read().strip()
    print(base64.b64encode(bech32_to_raw(pub)).decode())
