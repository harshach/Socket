#!/usr/bin/env python3
"""Generate a Sparkle EdDSA keypair compatible with sign_update / SUPublicEDKey.

Sparkle's sign_update expects the private key as a base64-encoded 32-byte
Ed25519 seed — matching the `generate_keys -x` export format from Sparkle's
own tooling. (Earlier libsodium-style 64-byte seed∥public-key files are
rejected by sign_update with "Imported key must be 64 bytes or 96 bytes ...
Instead it is 64 bytes decoded.")

  - Private key file: base64 of 32-byte Ed25519 seed — paste into the
    `SPARKLE_ED_PRIVATE_KEY` GitHub secret.
  - Public key:       base64 of 32-byte Ed25519 public key — paste into
    `Socket/Info.plist` under `SUPublicEDKey`. The app refuses updates not
    signed by the matching private key.

Requires `cryptography`:
    python3 -m pip install --break-system-packages cryptography

Run once, locally:
    python3 .github/scripts/generate-keys.py
"""
from __future__ import annotations

import base64
import sys


def main() -> None:
    try:
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    except ImportError:
        sys.exit(
            "generate-keys: missing `cryptography` package. Install with:\n"
            "    python3 -m pip install --break-system-packages cryptography"
        )

    priv = Ed25519PrivateKey.generate()
    seed = priv.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub = priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )

    # Sparkle's sign_update wants a base64'd 32-byte seed (matches the
    # output of `generate_keys -x`). Not the 64-byte libsodium format.
    priv_b64 = base64.b64encode(seed).decode()
    pub_b64 = base64.b64encode(pub).decode()

    print("=" * 72)
    print("SPARKLE EdDSA KEYPAIR — generated for Socket")
    print("=" * 72)
    print()
    print("1. Private key → GitHub repo secret `SPARKLE_ED_PRIVATE_KEY`:")
    print()
    print(f"   {priv_b64}")
    print()
    print("   Set it with:")
    print(f"   gh secret set SPARKLE_ED_PRIVATE_KEY --repo harshach/Socket --body '{priv_b64}'")
    print()
    print("-" * 72)
    print()
    print("2. Public key → paste into `Socket/Info.plist` under `SUPublicEDKey`:")
    print()
    print(f"   {pub_b64}")
    print()
    print("   <key>SUPublicEDKey</key>")
    print(f"   <string>{pub_b64}</string>")
    print()
    print("-" * 72)
    print()
    print("Keep the private key SECRET — anyone who has it can push updates")
    print("to every installed copy of Socket. Do NOT commit it.")


if __name__ == "__main__":
    main()
