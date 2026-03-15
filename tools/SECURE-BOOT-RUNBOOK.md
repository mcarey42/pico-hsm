# Pico HSM — Secure Boot Runbook

**Device:** Waveshare RP2350-One
**Firmware:** pico-hsm v6.4
**Last verified:** 2026-03-15

This document is the complete reference for building, signing, flashing, and locking
the Pico HSM firmware. Follow it in order for a fresh setup. Use individual sections
as a reference for day-to-day operations.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Signing Key Management](#3-signing-key-management)
4. [Building Signed Firmware](#4-building-signed-firmware)
5. [Verifying the Signed Firmware](#5-verifying-the-signed-firmware)
6. [Flashing the Firmware](#6-flashing-the-firmware)
7. [Functional Testing](#7-functional-testing)
8. [Enabling Secure Boot (OTP)](#8-enabling-secure-boot-otp)
9. [Locking the Device (Irreversible)](#9-locking-the-device-irreversible)
10. [Recovery and Re-keying](#10-recovery-and-re-keying)
11. [Complete Fresh-Start Checklist](#11-complete-fresh-start-checklist)
12. [Quick Reference](#12-quick-reference)

---

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Key hierarchy                                                   │
│                                                                  │
│  ec_private_key.pem (secp256k1)  ← lives at ~/Projects/         │
│       │                                                          │
│       ├─ used by: picotool seal  → signs firmware ELF/UF2       │
│       │                                                          │
│       └─ SHA-256(pubkey x||y)    → BOOTKEY in pico-hsm-tool.py  │
│                                      written to OTP row 0x80    │
│                                                                  │
│  After OTP is programmed:                                        │
│  RP2350 boot ROM verifies firmware signature on every boot.      │
│  No valid signature = device does not boot.                      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│  Build → Flash → Lock sequence (one-time)                        │
│                                                                  │
│  1. Generate secp256k1 key pair                                  │
│  2. Derive BOOTKEY hash → update pico-hsm-tool.py               │
│  3. Build firmware  →  signed UF2 + otp.json                    │
│  4. Flash signed UF2 onto device                                 │
│  5. Functional test (HSM + OpenBao unseal)                       │
│  6. otp secure_boot --index 0   (sets OTP, no lock yet)          │
│  7. Reboot and re-test                                           │
│  8. otp secure_boot --index 0 --lock  ← IRREVERSIBLE            │
└──────────────────────────────────────────────────────────────────┘
```

### Why secp256k1 and not P-256?

The RP2350 boot ROM implements ECDSA with **secp256k1** specifically.
`prime256v1` (P-256/NIST) keys will compile and generate signatures but
`picotool seal` will fail at the verification step with:
`ERROR: Signature verification failed`

---

## 2. Prerequisites

### Tools

| Tool | Install | Purpose |
|------|---------|---------|
| `picotool` v2.2.0+ | `/usr/local/bin/picotool` | Sign, flash, OTP |
| `openssl` | system | Key generation |
| `arm-none-eabi-gcc` | system | Cross-compiler |
| `cmake`, `make` | system | Build system |
| Python 3 + venv | `~/Projects/picohsm-runtime/venv` | HSM tool runtime |

### Python environment

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
alias hsm="python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py"
```

Ensure local packages are current after any pip changes:

```bash
pip install --force-reinstall --no-deps ~/Projects/pypicokey
pip install --force-reinstall --no-deps ~/Projects/py-picohsm
```

### Repository layout

```
~/Projects/
├── pico-hsm/                  ← firmware source
│   ├── build_pico_hsm.sh      ← build script (reads key from ../../ec_private_key.pem)
│   ├── build_release/         ← cmake build output
│   │   └── pico_hsm.otp.json  ← OTP programming data (generated at build time)
│   ├── release/               ← output UF2 files
│   └── tools/
│       ├── pico-hsm-tool.py   ← HSM management tool (contains BOOTKEY)
│       ├── hsm-setup.sh       ← device provisioning script
│       └── PICO-HSM-OPENBAO.md
├── ec_private_key.pem         ← signing private key (secp256k1, chmod 600)
├── pico-sdk/
├── py-picohsm/
└── pypicokey/
```

---

## 3. Signing Key Management

### 3a. Generate the key (first time or re-key)

```bash
openssl ecparam -name secp256k1 -genkey -noout -out ~/Projects/ec_private_key.pem
chmod 600 ~/Projects/ec_private_key.pem
```

Verify the curve:

```bash
openssl ec -in ~/Projects/ec_private_key.pem -text -noout 2>&1 | grep "ASN1 OID"
# Expected: ASN1 OID: secp256k1
```

### 3b. Derive BOOTKEY and update the tool

The `BOOTKEY` in `pico-hsm-tool.py` is SHA-256 of the raw 64-byte public key
(uncompressed x‖y, without the 0x04 prefix). Run this after generating or rotating
the key:

```bash
python3 - <<'EOF'
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PublicFormat
import hashlib

with open('/home/mcarey/Projects/ec_private_key.pem', 'rb') as f:
    key = load_pem_private_key(f.read(), password=None)

raw = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
digest = hashlib.sha256(raw[1:]).digest()   # SHA-256(x||y, 64 bytes)
print("BOOTKEY =", list(digest))
print("hex:    ", digest.hex())
EOF
```

Edit `tools/pico-hsm-tool.py` line ~60:

```python
BOOTKEY = [<paste output list here>]
```

Commit the updated `BOOTKEY` before building.

### 3c. Key backup

> **The private key must be backed up securely. If lost, you cannot sign future
> firmware. If the device is locked (Step 9), it becomes a permanent brick.**

Backup options (pick one or more):
- Encrypted removable media stored offline
- Encrypted with the HSM's AES slot 1 key (see below)
- Split with Shamir's secret sharing across trusted parties

**Optional: protect key at rest with the HSM**

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate

IV=$(python3 -c "import os; print(os.urandom(12).hex())")
echo $IV > ~/Projects/ec_key.iv

python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 cipher -k 1 --iv $IV \
    --file-in  ~/Projects/ec_private_key.pem \
    --file-out ~/Projects/ec_private_key.pem.enc \
    encrypt --alg AES-GCM

shred -u ~/Projects/ec_private_key.pem
```

**Decrypt before a rebuild:**

```bash
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 cipher -k 1 --iv $(cat ~/Projects/ec_key.iv) \
    --file-in  ~/Projects/ec_private_key.pem.enc \
    --file-out ~/Projects/ec_private_key.pem \
    decrypt --alg AES-GCM

chmod 600 ~/Projects/ec_private_key.pem
# ... build ...
shred -u ~/Projects/ec_private_key.pem   # re-encrypt when done
```

---

## 4. Building Signed Firmware

The build script reads `SECURE_BOOT_PKEY` which defaults to
`../../ec_private_key.pem` (relative to `build_release/`), resolving to
`~/Projects/ec_private_key.pem`.

```bash
cd ~/Projects/pico-hsm
./build_pico_hsm.sh
```

The cmake build calls `pico_sign_binary()` which runs:

```
picotool seal <firmware.elf> <firmware.elf> \
    ../../ec_private_key.pem pico_hsm.otp.json \
    --sign --hash --major 6 --minor 4 --rollback 3
```

**Outputs:**

| File | Description |
|------|-------------|
| `release/pico_hsm_waveshare_rp2350_one-6.4.uf2` | Signed firmware for this device |
| `release/pico_hsm_pico2-6.4.uf2` | Signed firmware for Pico 2 |
| `release/pico_hsm_pico-6.4.uf2` | RP2040 firmware (no secure boot) |
| `build_release/pico_hsm.otp.json` | OTP programming data (public key hash + boot flags) |

> The `otp.json` is generated from the last board in the loop (waveshare_rp2350_one).
> Keep this file — it is the authoritative OTP programming source.

---

## 5. Verifying the Signed Firmware

**Verify the UF2 file before flashing:**

```bash
picotool info --all release/pico_hsm_waveshare_rp2350_one-6.4.uf2
```

Look for:

```
hash:              verified
signature:         verified
rollback version:  3
```

If either shows `not present` or `failed`, do not flash. Check that
`ec_private_key.pem` is the correct secp256k1 key and rebuild.

**Cross-check BOOTKEY matches otp.json:**

```bash
python3 - <<'EOF'
import json
with open('/home/mcarey/Projects/pico-hsm/build_release/pico_hsm.otp.json') as f:
    otp = json.load(f)
print("otp.json bootkey0:", otp['bootkey0'])

# Compare with tool
import sys
sys.path.insert(0, '/home/mcarey/Projects/pico-hsm/tools')
# Quick grep instead of importing
import re
tool = open('/home/mcarey/Projects/pico-hsm/tools/pico-hsm-tool.py').read()
m = re.search(r'BOOTKEY = (\[.*?\])', tool)
print("tool BOOTKEY:     ", eval(m.group(1)))
print("Match:", otp['bootkey0'] == eval(m.group(1)))
EOF
```

---

## 6. Flashing the Firmware

### Enter BOOTSEL mode

- Hold **BOOTSEL** button and press **RESET** (or replug USB while holding BOOTSEL)
- Device appears as a USB mass storage drive at `/media/mcarey/RP2350`

### Flash

```bash
cp ~/Projects/pico-hsm/release/pico_hsm_waveshare_rp2350_one-6.4.uf2 /media/mcarey/RP2350/
```

The device reboots automatically after the copy completes.

### Confirm the device is running

```bash
sleep 4 && systemctl restart pcscd
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py --pin 648219 memory
```

Expected output includes `Free:` and `Used:` memory stats.

---

## 7. Functional Testing

Run all checks before programming OTP. These confirm the firmware and HSM keys are intact.

### 7a. Key inventory

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 - <<'EOF'
from picohsm import PicoHSM, DOPrefixes
dev = PicoHSM('648219')
keys = dev.list_keys(prefix=DOPrefixes.KEY_PREFIX)
type_names = {1: 'RSA', 2: 'ECC', 3: 'AES'}
for kid in keys:
    info = dev.keyinfo(kid)
    ktype = type_names.get(info.get('type', 0), 'Unknown')
    print(f"  Slot {kid}: {ktype}-{info.get('key_size','?')}")
EOF
```

Expected: Slot 0 (ECC-256 device key), Slot 1 (AES-256 unseal key).

### 7b. AES-GCM round-trip

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
IV=$(python3 -c "import os; print(os.urandom(12).hex())")
echo -n "test-payload" > /tmp/plain.bin

python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 cipher -k 1 --iv $IV \
    --file-in /tmp/plain.bin --file-out /tmp/enc.bin \
    encrypt --alg AES-GCM

python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 cipher -k 1 --iv $IV \
    --file-in /tmp/enc.bin --file-out /tmp/dec.bin \
    decrypt --alg AES-GCM

diff /tmp/plain.bin /tmp/dec.bin && echo "PASS" || echo "FAIL"
```

### 7c. OpenBao unseal

Restart OpenBao (forces sealed state), then run the unseal script:

```bash
BAO=/home/linuxbrew/.linuxbrew/opt/openbao/bin/bao
export BAO_ADDR=http://127.0.0.1:8200

kill $(pgrep -f "bao server") 2>/dev/null; sleep 3
$BAO server -config=/home/mcarey/openbao/config.hcl \
    &>/home/mcarey/openbao/logs/openbao.log &
disown $!
sleep 3

source ~/Projects/picohsm-runtime/venv/bin/activate
bash /home/mcarey/openbao/unseal/hsm-unseal.sh
```

Expected final line: `Sealed   false`

**All three tests must pass before proceeding to Step 8.**

---

## 8. Enabling Secure Boot (OTP)

> **OTP writes are one-way. The bits set here cannot be unset.**
> Complete Step 7 successfully before continuing.

This step writes your public key hash to OTP and sets `SECURE_BOOT_ENABLE`.
After this, the boot ROM checks the firmware signature. Debug access is still
available and additional boot keys can still be added.

### Option A: via pico-hsm-tool (uses BOOTKEY from the tool)

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 otp secure_boot --index 0
```

### Option B: via picotool (uses otp.json from the build)

Enter BOOTSEL mode first, then:

```bash
picotool otp load ~/Projects/pico-hsm/build_release/pico_hsm.otp.json
```

Either method programs the same three OTP fields:
- `bootkey0` — SHA-256 of your public key (rows 0x80–0x8F)
- `boot_flags1.key_valid` — marks bootkey0 as valid
- `crit1.secure_boot_enable` — enables signature checking

### Verify OTP was written (device in BOOTSEL mode)

```bash
picotool otp get SECURE_BOOT_ENABLE
picotool otp get KEY_VALID
```

Both should return `1`.

### Reboot and re-run all tests from Step 7

If the device boots and all tests pass: secure boot is active and working.
If the device does not boot: the firmware was not signed with the matching key —
see [Section 10](#10-recovery-and-re-keying).

---

## 9. Locking the Device (Irreversible)

> ⚠️ **This cannot be undone. Ever.**
>
> After locking:
> - Debug access is disabled permanently
> - Glitch detector is enabled
> - All other boot key slots are invalidated (only your key will ever work)
> - OTP pages 1 & 2 are locked against further writes
>
> If your signing key is lost after this point, the device cannot be recovered.
> **Back up the key before proceeding (Section 3c).**

Confirm you have completed:
- [ ] Section 3c — key backed up securely
- [ ] Section 7 — all functional tests pass with secure boot active (Section 8)
- [ ] You have the signed UF2 and `otp.json` archived

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 otp secure_boot --index 0 --lock
```

The tool will prompt:

```
This will lock the chip without possibility to add more bootkeys and will run
only with Pico Keys firmware. Type 'LOCK' to continue:
```

Type `LOCK` and press Enter.

Reboot and run the full functional test suite (Section 7) one final time to confirm.

---

## 10. Recovery and Re-keying

### Device won't boot after OTP programming (before lock)

The firmware signature doesn't match the key hash in OTP. To recover:

1. Enter BOOTSEL — the boot ROM falls back to BOOTSEL even when secure boot is active
   (until locked, BOOTSEL remains accessible)
2. Re-flash with correctly signed firmware:
   ```bash
   cp release/pico_hsm_waveshare_rp2350_one-6.4.uf2 /media/mcarey/RP2350/
   ```

### Need to rotate the signing key (device NOT yet locked)

OTP rows are write-once, but there are 4 boot key slots (index 0–3).
You can add a new key in a second slot before invalidating the old one.

1. Generate new key: `openssl ecparam -name secp256k1 -genkey -noout -out ~/Projects/ec_private_key_new.pem`
2. Derive new BOOTKEY, update `pico-hsm-tool.py`
3. Build new signed firmware
4. Flash new firmware
5. Program new key into a second OTP slot:
   ```bash
   python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
       --pin 648219 otp secure_boot --index 1
   ```
6. Verify device still boots, then lock with `--lock` using `--index 1`

### Device is locked and key is lost

There is no recovery. The device cannot be re-flashed with new firmware.
The HSM data (keys in flash) is intact but inaccessible through new firmware.

**This is why key backup (Section 3c) is mandatory before locking.**

---

## 11. Complete Fresh-Start Checklist

Use this when setting up from scratch on a new machine or after a key rotation.

```
[ ] 1.  Clone repos and set up venv
        cd ~/Projects && git clone git@github.com:mcarey42/pico-hsm.git
        bash ~/Projects/build-picohsm-venv.sh

[ ] 2.  Generate signing key
        openssl ecparam -name secp256k1 -genkey -noout \
            -out ~/Projects/ec_private_key.pem
        chmod 600 ~/Projects/ec_private_key.pem

[ ] 3.  Derive BOOTKEY and update tools/pico-hsm-tool.py
        (run the python snippet from Section 3b)
        git add tools/pico-hsm-tool.py && git commit -m "Update BOOTKEY"
        git push

[ ] 4.  Build firmware
        cd ~/Projects/pico-hsm && ./build_pico_hsm.sh

[ ] 5.  Verify UF2
        picotool info --all \
            release/pico_hsm_waveshare_rp2350_one-6.4.uf2
        # Must show: hash: verified  /  signature: verified

[ ] 6.  Initialize HSM (if new device or after full wipe)
        cd ~/Projects/pico-hsm/tools
        ./hsm-setup.sh --so-pin <YOUR_SO_PIN> --pin 648219

[ ] 7.  Flash signed firmware
        # Enter BOOTSEL mode, then:
        cp release/pico_hsm_waveshare_rp2350_one-6.4.uf2 /media/mcarey/RP2350/

[ ] 8.  Run functional tests (Section 7a, 7b, 7c)
        All three must pass.

[ ] 9.  Back up signing key (Section 3c)

[ ] 10. Program OTP — secure boot without lock (Section 8)
        pico-hsm-tool.py --pin 648219 otp secure_boot --index 0

[ ] 11. Reboot and re-run all functional tests
        All three must pass.

[ ] 12. Lock device (Section 9) — only when fully satisfied
        pico-hsm-tool.py --pin 648219 otp secure_boot --index 0 --lock
```

---

## 12. Quick Reference

### Build

```bash
cd ~/Projects/pico-hsm && ./build_pico_hsm.sh
```

### Verify UF2

```bash
picotool info --all release/pico_hsm_waveshare_rp2350_one-6.4.uf2
```

### Flash (BOOTSEL mode required)

```bash
cp release/pico_hsm_waveshare_rp2350_one-6.4.uf2 /media/mcarey/RP2350/
```

### Enable secure boot (no lock)

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 otp secure_boot --index 0
```

### Lock device (irreversible)

```bash
python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 otp secure_boot --index 0 --lock
```

### Derive BOOTKEY from current key

```bash
python3 - <<'EOF'
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PublicFormat
import hashlib
with open('/home/mcarey/Projects/ec_private_key.pem', 'rb') as f:
    key = load_pem_private_key(f.read(), password=None)
raw = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
digest = hashlib.sha256(raw[1:]).digest()
print("BOOTKEY =", list(digest))
print("hex:    ", digest.hex())
EOF
```

### OpenBao unseal

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
bash /home/mcarey/openbao/unseal/hsm-unseal.sh
```

### Key slot inventory

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
python3 - <<'EOF'
from picohsm import PicoHSM, DOPrefixes
dev = PicoHSM('648219')
for kid in dev.list_keys(prefix=DOPrefixes.KEY_PREFIX):
    info = dev.keyinfo(kid)
    t = {1:'RSA',2:'ECC',3:'AES'}.get(info.get('type',0),'?')
    print(f"Slot {kid}: {t}-{info.get('key_size','?')}")
EOF
```

---

*Key file: `~/Projects/ec_private_key.pem` (secp256k1, never commit to git)*
*OTP data: `~/Projects/pico-hsm/build_release/pico_hsm.otp.json` (archive with each release)*
