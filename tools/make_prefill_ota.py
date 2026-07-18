#!/usr/bin/env python3
"""Assemble the pre-fill OTA artifact: [64-byte header][app][littlefs image].

Invoked at build time by the littlefs_prefill_ota_bin target (see project_include.cmake).
A stock OTA sender streams the output file unchanged; the patched receiver recognises the
header magic on the first bytes and routes the stream at the seam in a single pass.

Header, big endian:
  magic "EPF2" (4) | app_size u32 | image_size u32 | label (32, NUL-padded) |
  image MD5 (16) | reserved zeros (4)
"""

import argparse
import hashlib
import sys

MAGIC = b"EPF2"
HEADER_SIZE = 64


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True)
    p.add_argument("--image", required=True)
    p.add_argument("--label", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()

    label = args.label.encode()
    if len(label) > 32:
        print(f"prefill-ota: partition label longer than 32 bytes: {args.label}", file=sys.stderr)
        return 1
    with open(args.app, "rb") as f:
        app = f.read()
    with open(args.image, "rb") as f:
        image = f.read()

    header = (
        MAGIC
        + len(app).to_bytes(4, "big")
        + len(image).to_bytes(4, "big")
        + label.ljust(32, b"\x00")
        + hashlib.md5(image).digest()
        + b"\x00" * 4
    )
    assert len(header) == HEADER_SIZE
    with open(args.output, "wb") as f:
        f.write(header + app + image)
    print(f"prefill-ota: wrote {args.output} (app {len(app)} + image {len(image)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
