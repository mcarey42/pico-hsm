# Pico HSM — Operations Guide & OpenBao Auto-Unseal

**Device:** Waveshare RP2350-One
**Firmware:** pico-hsm v6.4
**Tool:** `tools/pico-hsm-tool.py`
**Venv:** `~/Projects/picohsm-runtime/venv`

---

## Quick Reference

```bash
# Activate the environment
source ~/Projects/picohsm-runtime/venv/bin/activate
alias hsm="python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py"
```

---

## 1. Initial Provisioning

Use the setup script for first-time device setup:

```bash
cd ~/Projects/pico-hsm/tools
./hsm-setup.sh --so-pin 12345678 --pin 648219
```

This script:
1. Initializes the device (erases all keys)
2. Generates a dedicated AES-256 key at slot 1 for unsealing
3. Prints memory usage and the key slot inventory

> **SO-PIN** is the Security Officer PIN — required for device re-initialization.
> **PIN** is the user PIN — required for all key operations.
> Both must be recorded securely. The defaults are `648219` (PIN) and whatever you pass as `--so-pin`.

---

## 2. Key Slot Management

### List all provisioned slots

```bash
hsm --pin 648219 memory
```

Or directly via Python for full detail:

```python
from picohsm import PicoHSM, DOPrefixes

dev = PicoHSM('648219')
keys = dev.list_keys(prefix=DOPrefixes.KEY_PREFIX)
for kid in keys:
    info = dev.keyinfo(kid)
    print(f"Slot {kid}: {info}")
```

### Slot numbering

Slots are integers starting at **1** (slot 0 is reserved for the internal device key).
Keys are assigned the next free ID automatically when generated.

### Generate keys

```bash
# AES-256 (for symmetric encryption / unsealing)
hsm --pin 648219 keygen aes --size 256

# AES-128
hsm --pin 648219 keygen aes --size 128

# Ed25519 signing key
hsm --pin 648219 keygen ed25519

# X25519 key exchange key
hsm --pin 648219 keygen x25519
```

Each command prints the assigned slot ID — record it.

### Delete a key

```python
from picohsm import PicoHSM
dev = PicoHSM('648219')
dev.delete_key(KEY_ID)
```

---

## 3. Encrypt / Decrypt Data

The primary cipher for unseal operations is **AES-256-GCM** — authenticated encryption with a 12-byte IV and 16-byte tag appended to the ciphertext.

### Encrypt a file

> **Note:** `-k`, `--iv`, `--file-in`, `--file-out`, and `--aad` all belong to the `cipher`
> parent command and must come **before** the `encrypt`/`decrypt` subcommand.

```bash
# Generate a random 12-byte IV (hex)
IV=$(python3 -c "import os; print(os.urandom(12).hex())")

hsm --pin 648219 cipher -k 1 --iv $IV \
    --file-in plaintext.bin --file-out ciphertext.bin \
    encrypt --alg AES-GCM
```

Store `$IV` alongside `ciphertext.bin` — you need it to decrypt.

### Decrypt a file

```bash
hsm --pin 648219 cipher -k 1 --iv $IV \
    --file-in ciphertext.bin --file-out plaintext.bin \
    decrypt --alg AES-GCM
```

### Pipe plaintext inline

```bash
echo -n "my secret" | hsm --pin 648219 cipher -k 1 --iv $IV encrypt --alg AES-GCM > secret.enc
```

---

## 4. OpenBao Auto-Unseal with Pico HSM

### Strategy

OpenBao's unseal keys are sensitive — storing them on disk defeats the purpose of a vault.
The Pico HSM acts as a **hardware-bound key custodian**: the AES-256 key never leaves the device, so the encrypted unseal blob is useless without the physical HSM present.

```
┌─────────────────────────────────────────────────────┐
│  Seal flow (one-time, at vault init)                │
│                                                     │
│  openbao operator init  →  unseal_key.txt           │
│  hsm cipher encrypt     →  unseal_key.enc  + iv.hex │
│  shred unseal_key.txt                               │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│  Auto-unseal flow (every restart)                   │
│                                                     │
│  hsm cipher decrypt unseal_key.enc  →  plaintext    │
│  openbao operator unseal  <plaintext                │
└─────────────────────────────────────────────────────┘
```

### Step 1 — Initialize OpenBao and capture unseal key

```bash
openbao operator init -key-shares=1 -key-threshold=1 > /tmp/vault-init.txt

# Extract the unseal key
UNSEAL_KEY=$(grep 'Unseal Key 1' /tmp/vault-init.txt | awk '{print $NF}')
ROOT_TOKEN=$(grep 'Initial Root Token' /tmp/vault-init.txt | awk '{print $NF}')

echo "Root token: $ROOT_TOKEN"  # store this securely too
```

> Using `-key-shares=1 -key-threshold=1` gives a single unseal key.
> For higher security, use more shares (e.g. 3-of-5) and encrypt each share separately on the HSM.

### Step 2 — Encrypt the unseal key onto the HSM

```bash
# Generate and save the IV
IV=$(python3 -c "import os; print(os.urandom(12).hex())")
echo $IV > /etc/openbao/unseal.iv

# Encrypt
echo -n "$UNSEAL_KEY" | \
  python3 ~/Projects/pico-hsm/tools/pico-hsm-tool.py \
    --pin 648219 cipher -k 1 --iv $IV \
    encrypt --alg AES-GCM \
  > /etc/openbao/unseal.enc

# Destroy the plaintext
shred -u /tmp/vault-init.txt
unset UNSEAL_KEY
```

`/etc/openbao/unseal.enc` and `/etc/openbao/unseal.iv` are safe to store on disk —
decryption requires the physical Pico HSM **and** the PIN.

### Step 3 — Auto-unseal script

Create `/usr/local/bin/openbao-unseal`:

```bash
#!/bin/bash
set -e

VENV=~/Projects/picohsm-runtime/venv
TOOL=~/Projects/pico-hsm/tools/pico-hsm-tool.py
PIN="648219"
KEY_ID=1
ENC_FILE=/etc/openbao/unseal.enc
IV_FILE=/etc/openbao/unseal.iv
BAO_ADDR="${OPENBAO_ADDR:-http://127.0.0.1:8200}"

# Wait for vault to be up
for i in $(seq 1 30); do
    openbao status -address="$BAO_ADDR" 2>/dev/null | grep -q "Sealed.*true" && break
    sleep 1
done

IV=$(cat "$IV_FILE")

UNSEAL_KEY=$(
    source "$VENV/bin/activate"
    python3 "$TOOL" --pin "$PIN" cipher -k "$KEY_ID" --iv "$IV" \
        --file-in "$ENC_FILE" \
        decrypt --alg AES-GCM
)

openbao operator unseal -address="$BAO_ADDR" "$UNSEAL_KEY"
unset UNSEAL_KEY
echo "Vault unsealed."
```

```bash
chmod 700 /usr/local/bin/openbao-unseal
```

### Step 4 — Systemd service for auto-unseal on boot

`/etc/systemd/system/openbao-unseal.service`:

```ini
[Unit]
Description=OpenBao Auto-Unseal via Pico HSM
After=openbao.service
Requires=openbao.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openbao-unseal
RemainAfterExit=yes
User=root

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable openbao-unseal
```

On every boot: OpenBao starts sealed → the unseal service fires → Pico HSM decrypts the key → vault unseals automatically. Pull the physical HSM and the vault stays sealed on next restart.

---

## 5. PHY / Device Configuration

### Check current PHY settings

```bash
hsm phy vidpid
hsm phy led_gpio
hsm phy led_brightness
```

### Set LED brightness (0–15)

```bash
hsm phy led_brightness 8
```

### Set a custom USB VID:PID

```bash
hsm phy vidpid 1234:5678
```

After any PHY change the device must be restarted:

```bash
hsm reboot
```

---

## 6. OTP / Secure Boot (RP2350 only)

### Signing key

The firmware signing key lives **outside the source tree** at `~/Projects/ec_private_key.pem`.
It is an EC P-256 key whose SHA-256 public key hash is embedded in `pico-hsm-tool.py` as `BOOTKEY`.

The build script already defaults to this path:

```bash
# build_pico_hsm.sh:
SECURE_BOOT_PKEY="${SECURE_BOOT_PKEY:-../../ec_private_key.pem}"
# ../../ from build_release/ = ~/Projects/
```

To rebuild with signing, just run `./build_pico_hsm.sh` — it picks up the key automatically.

If the key needs to be regenerated (e.g. new machine), derive the new `BOOTKEY` and update the tool:

```bash
python3 - <<'EOF'
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PublicFormat
import hashlib
with open('/home/mcarey/Projects/ec_private_key.pem', 'rb') as f:
    key = load_pem_private_key(f.read(), password=None)
raw = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
digest = hashlib.sha256(raw[1:]).digest()   # SHA-256(x||y, 64 bytes)
print("BOOTKEY =", list(digest))
print("hex:", digest.hex())
EOF
```

Then replace `BOOTKEY = [...]` in `tools/pico-hsm-tool.py` with the new value.

### Read an OTP row

```bash
hsm otp read --row 0x00
```

### Enable Secure Boot

Writes the `BOOTKEY` hash from `pico-hsm-tool.py` into OTP and sets `SECURE_BOOT_ENABLE`.
The firmware **must** have been built with the matching signing key before this is run,
otherwise the device will not boot.

```bash
# Without lock — secure boot enabled, debug still accessible, more boot keys can be added
hsm otp secure_boot --index 0

# With lock — IRREVERSIBLE: disables debug, invalidates other key slots, locks OTP pages 1 & 2
hsm otp secure_boot --index 0 --lock
```

---

## 7. Common Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `PicoKeyNotFoundError` | Device not connected or pcscd dropped it | Replug device, `systemctl restart pcscd` |
| `SW:6982` | Wrong PIN or not logged in | Check `--pin` argument |
| `SW:6D00` | Wrong applet selected | Ensure py-picohsm local version is installed (see notes below) |
| `SW:6A82` | File/key not found | Key ID doesn't exist; check `list_keys()` |
| Long RSA operations cause disconnect | PCSC timeout on 4096-bit ops | Use shorter key sizes or split test runs |

### Keeping local packages current

After any `pip install` of pypicokey or pypicohsm, force-reinstall from the local clones:

```bash
source ~/Projects/picohsm-runtime/venv/bin/activate
pip install --force-reinstall --no-deps ~/Projects/pypicokey
pip install --force-reinstall --no-deps ~/Projects/py-picohsm
```

---

## 8. Key Slot Conventions (suggested)

| Slot | Purpose |
|------|---------|
| 0    | Internal device key (reserved, do not use) |
| 1    | OpenBao unseal key (AES-256-GCM) |
| 2–9  | Application-specific symmetric keys |
| 10+  | Asymmetric keys (ECC/Ed25519) |
