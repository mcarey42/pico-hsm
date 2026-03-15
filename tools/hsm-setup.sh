#!/bin/bash
#
# hsm-setup.sh — Pico HSM initial provisioning script
#
# Usage:
#   ./hsm-setup.sh [--pin PIN] [--so-pin SO_PIN] [--unseal-key-id ID]
#
# Defaults:
#   PIN:           648219
#   SO_PIN:        (required)
#   UNSEAL_KEY_ID: 1

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${SCRIPT_DIR}/../../picohsm-runtime/venv"
TOOL="${SCRIPT_DIR}/pico-hsm-tool.py"
PYTHON="${VENV}/bin/python3"

# Parse arguments
PIN="648219"
SO_PIN=""
UNSEAL_KEY_ID=1

while [[ $# -gt 0 ]]; do
    case $1 in
        --pin)       PIN="$2";           shift 2 ;;
        --so-pin)    SO_PIN="$2";        shift 2 ;;
        --unseal-key-id) UNSEAL_KEY_ID="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$SO_PIN" ]]; then
    echo "ERROR: --so-pin is required"
    echo "Usage: $0 --so-pin <SO_PIN> [--pin <PIN>] [--unseal-key-id <ID>]"
    exit 1
fi

echo "============================================"
echo "  Pico HSM Provisioning"
echo "============================================"
echo "  PIN:            $PIN"
echo "  SO-PIN:         $SO_PIN"
echo "  Unseal Key ID:  $UNSEAL_KEY_ID"
echo ""

# Step 1: Initialize the device
echo "[1/4] Initializing device..."
echo "" | "$PYTHON" "$TOOL" --pin "$PIN" initialize --so-pin "$SO_PIN" --no-dev-cert
echo "      Done."

# Step 2: Generate the OpenBao unseal AES-256 key
echo "[2/4] Generating AES-256 unseal key (slot $UNSEAL_KEY_ID)..."
"$PYTHON" - <<PYEOF
import sys
sys.path.insert(0, '${VENV}/lib/python3.12/site-packages')
from picohsm import PicoHSM, KeyType
dev = PicoHSM('${PIN}')
kid = dev.key_generation(KeyType.AES, 256)
if kid != ${UNSEAL_KEY_ID}:
    print(f"WARNING: Key was assigned ID {kid}, not ${UNSEAL_KEY_ID}.")
    print(f"         Use --unseal-key-id {kid} in future operations.")
else:
    print(f"      AES-256 key generated at slot {kid}.")
PYEOF

# Step 3: Show memory usage
echo "[3/4] Memory usage:"
"$PYTHON" "$TOOL" --pin "$PIN" memory

# Step 4: List provisioned keys
echo "[4/4] Provisioned key slots:"
"$PYTHON" - <<PYEOF
import sys
sys.path.insert(0, '${VENV}/lib/python3.12/site-packages')
from picohsm import PicoHSM, DOPrefixes, KeyType
dev = PicoHSM('${PIN}')
keys = dev.list_keys(prefix=DOPrefixes.KEY_PREFIX)
type_names = {1: 'RSA', 2: 'ECC', 3: 'AES'}
for kid in keys:
    info = dev.keyinfo(kid)
    ktype = type_names.get(info.get('type', 0), 'Unknown')
    label = info.get('label', '') or '(no label)'
    size = info.get('key_size', '?')
    print(f"      Slot {kid:3d}: {ktype}-{size}  label={label}")
PYEOF

echo ""
echo "============================================"
echo "  Provisioning complete."
echo ""
echo "  IMPORTANT: Record these values securely."
echo "    PIN:    $PIN"
echo "    SO-PIN: $SO_PIN"
echo "    Unseal key slot: $UNSEAL_KEY_ID (AES-256-GCM)"
echo "============================================"
