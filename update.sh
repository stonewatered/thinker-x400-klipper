#!/bin/bash
# Update the Klipper host, Moonraker, and both MCUs on an Eryone Thinker X400.
# Run this on the printer, as the mks user, while the printer is idle.
# Pass --build-only to download and compile without flashing or restarting.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KLIPPER_COMMIT="282db764dc568841837f68af3964762189d2baee"
BUILD="/home/mks/x400-klipper-build"
STAGE_MOON="/home/mks/moonraker-x400"
BACKUP="/home/mks/x400-update-backup"
LOG="$BACKUP/update.log"
CAN_FLASH="/home/mks/CanBoot/scripts/flash_can.py"
CONFIG_DIR="/home/mks/printer_data/config"

BUILD_ONLY=0
if [ "${1:-}" = "--build-only" ]; then
    BUILD_ONLY=1
fi

if [ "$(id -un)" != "mks" ]; then
    echo "Run this on the printer as the mks user."
    exit 1
fi

mkdir -p "$BACKUP"
exec > >(tee -a "$LOG") 2>&1

echo "Thinker X400 update"
echo "Log: $LOG"

need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing command: $1"
        exit 1
    fi
}
need git
need make
need python3
need arm-none-eabi-gcc
need curl
need rsync

if [ "$BUILD_ONLY" -eq 0 ]; then
    echo "The sudo password on a stock X400 is makerbase."
    sudo -v
fi

parse_uuids() {
    python3 - "$CONFIG_DIR/canuid.cfg" << 'PY'
import sys
path, section = sys.argv[1], None
found = {}
for raw in open(path, errors="replace"):
    line = raw.split("#", 1)[0].strip()
    if line.startswith("[") and line.endswith("]"):
        section = line[1:-1].strip()
        continue
    if section is not None and line.startswith("canbus_uuid"):
        found[section] = line.split(":", 1)[1].strip()
mcu = found.get("mcu", "")
eecan = found.get("mcu EECAN", "")
if not mcu or not eecan:
    sys.exit("canuid.cfg has no mcu and mcu EECAN uuids")
print(mcu)
print(eecan)
PY
}

require_idle() {
    python3 - << 'PY'
import json, urllib.request
url = "http://127.0.0.1:7125/printer/objects/query?print_stats&extruder&heater_bed"
raw = urllib.request.urlopen(url, timeout=5).read()
status = json.loads(raw)["result"]["status"]
state = status["print_stats"]["state"]
extruder = status["extruder"]["target"]
bed = status["heater_bed"]["target"]
print("print_state", state, "extruder_target", extruder, "bed_target", bed)
if state in ("printing", "paused") or extruder > 40 or bed > 40:
    raise SystemExit("Printer is busy. Wait until it is idle and heaters are off.")
PY
}

prepare_klipper() {
    if [ ! -d "$BUILD/.git" ]; then
        echo "Downloading Klipper..."
        git clone https://github.com/Klipper3d/klipper.git "$BUILD"
    fi
    echo "Checking out Klipper $KLIPPER_COMMIT"
    git -C "$BUILD" fetch --tags origin
    git -C "$BUILD" checkout "$KLIPPER_COMMIT"
    git -C "$BUILD" submodule update --init
    git -C "$BUILD" checkout -- .
    cp -a "$ROOT/overlay/." "$BUILD/"
    echo "Checking the Klipper host on this printer's Python..."
    /home/mks/klippy-env/bin/python -m compileall -q "$BUILD/klippy"
}

prepare_moonraker() {
    rm -rf "$STAGE_MOON"
    mkdir -p "$STAGE_MOON"
    cp -a "$ROOT/moonraker/." "$STAGE_MOON/"
    if [ -f /home/mks/moonraker-timelapse/component/timelapse.py ]; then
        ln -s /home/mks/moonraker-timelapse/component/timelapse.py \
            "$STAGE_MOON/moonraker/components/timelapse.py"
    fi
    echo "Checking Moonraker on this printer's Python..."
    /home/mks/moonraker-env/bin/python -m compileall -q "$STAGE_MOON/moonraker"
    /home/mks/moonraker-env/bin/python -c "import sys; sys.path.insert(0, '$STAGE_MOON'); import moonraker.server; print('Moonraker import ok')"
}

build_firmware() {
    local config="$1"
    local expect_vma="$2"
    local outfile="$3"
    cd "$BUILD"
    make clean
    cp "$config" .config
    make olddefconfig
    make -j"$(nproc)"
    local vma
    vma="$(arm-none-eabi-objdump -h out/klipper.elf | awk '$2==".text" {print $4; exit}')"
    echo "Built $outfile text address $vma"
    if [ "$vma" != "$expect_vma" ]; then
        echo "Refusing this image. Expected text address $expect_vma."
        exit 1
    fi
    cp -a "out/$outfile" "$BACKUP/$outfile"
}

wait_for_rp2() {
    local i dev
    for i in $(seq 1 40); do
        if [ -L /dev/disk/by-label/RPI-RP2 ]; then
            dev="$(readlink -f /dev/disk/by-label/RPI-RP2)"
            if [ -b "$dev" ]; then
                echo "$dev"
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

copy_uf2() {
    local uf2="$1"
    local dev mount
    dev="$(wait_for_rp2)" || return 1
    mount="/mnt/x400-rp2"
    sudo mkdir -p "$mount"
    sudo mount "$dev" "$mount"
    sudo cp "$uf2" "$mount/klipper.uf2"
    sync
    sudo umount "$mount"
    local i
    for i in $(seq 1 40); do
        if ! lsusb | grep -q '2e8a'; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

can_query_has() {
    local uuid="$1"
    /home/mks/klippy-env/bin/python /home/mks/klipper/scripts/canbus_query.py can0 | tee "$BACKUP/can-query.txt"
    grep -q "$uuid" "$BACKUP/can-query.txt"
}

request_bootloader() {
    python3 "$CAN_FLASH" -i can0 -u "$1" -r
}

restore_toolhead() {
    echo "Putting the previous toolhead firmware back."
    if [ ! -f "$BACKUP/eecan-previous.uf2" ]; then
        echo "No previous toolhead image was saved."
        return 1
    fi
    sudo ip link set can0 up type can bitrate 1000000 || true
    request_bootloader "$EECAN_UUID"
    copy_uf2 "$BACKUP/eecan-previous.uf2"
}

prepare_mcu_flasher() {
    python3 - "$CAN_FLASH" /tmp/x400-flash-mcu.py << 'PY'
import sys
src, dest = sys.argv[1], sys.argv[2]
text = open(src).read()
old = """        flasher = CanFlasher(self.node, fw_path)
        try:
            await flasher.connect_btl()
            await flasher.send_file()
            await flasher.verify_file()
        finally:
            # always attempt to send the complete command. If
            # there is an error it will exit the bootloader
            # unless comms were broken
            await flasher.finish()
"""
new = """        flasher = CanFlasher(self.node, fw_path)
        await flasher.connect_btl()
        if flasher.app_start_addr != 0x8008000:
            output_line("Application start is 0x%X, not 0x08008000" % flasher.app_start_addr)
            output_line("Booting the existing application without writing")
            await flasher.finish()
            raise FlashCanError("unexpected application address")
        await flasher.send_file()
        await flasher.verify_file()
        await flasher.finish()
"""
if old not in text:
    sys.exit("This printer's CanBoot flash tool is not the expected version.")
open(dest, "w").write(text.replace(old, new, 1))
print("MCU flasher ready")
PY
}

migrate_config() {
    python3 - "$CONFIG_DIR" /home/mks/KlipperScreen/config << 'PY'
import sys
from pathlib import Path
roots = [Path(p) for p in sys.argv[1:] if Path(p).is_dir()]

def migrate(path):
    lines = path.read_text(errors="replace").splitlines(keepends=True)
    max_accel = None
    for line in lines:
        body = line.split("#", 1)[0].strip()
        if body.startswith("max_accel:"):
            try:
                max_accel = float(body.split(":", 1)[1].strip())
            except ValueError:
                pass
    changed = False
    out = []
    for line in lines:
        body = line.split("#", 1)[0].strip()
        if body.startswith("max_accel_to_decel:"):
            try:
                mad = float(body.split(":", 1)[1].strip())
            except ValueError:
                out.append(line)
                continue
            if max_accel and max_accel > 0:
                ratio = max(0.0, 1.0 - min(1.0, mad / max_accel))
            else:
                ratio = 0.0
            indent = line[:len(line) - len(line.lstrip())]
            out.append("%s# Replaces %s\n" % (indent, body))
            out.append("%sminimum_cruise_ratio: %s\n" % (indent, ("%g" % ratio)))
            changed = True
            print("Updated", path, "minimum_cruise_ratio", ratio)
        else:
            out.append(line)
    if changed:
        path.write_text("".join(out))

for root in roots:
    for path in root.glob("*.cfg"):
        if path.is_file() and "max_accel_to_decel:" in path.read_text(errors="replace"):
            migrate(path)
PY
}

install_trees() {
    echo "Installing the new Klipper host and Moonraker..."
    sudo systemctl stop moonraker || true
    if [ ! -d /home/mks/klipper-pre-x400-update ]; then
        mv /home/mks/klipper /home/mks/klipper-pre-x400-update
    else
        rm -rf /home/mks/klipper
    fi
    mkdir -p /home/mks/klipper
    rsync -a --delete --exclude .git --exclude out "$BUILD/" /home/mks/klipper/
    if [ -d /home/mks/KlipperScreen/klipper ]; then
        rsync -a --delete --exclude .git --exclude out "$BUILD/" /home/mks/KlipperScreen/klipper/
    fi
    if [ ! -d /home/mks/moonraker-pre-x400-update ]; then
        mv /home/mks/moonraker /home/mks/moonraker-pre-x400-update
    else
        rm -rf /home/mks/moonraker
    fi
    mv "$STAGE_MOON" /home/mks/moonraker
    migrate_config
    sudo systemctl start moonraker
    sudo systemctl start klipper
}

wait_ready() {
    local i
    for i in $(seq 1 30); do
        if curl -sf --max-time 5 http://127.0.0.1:7125/printer/info | grep -q '"state": "ready"'; then
            echo "Printer is ready."
            curl -s --max-time 5 http://127.0.0.1:7125/printer/info
            echo
            return 0
        fi
        sleep 2
    done
    echo "Klipper did not become ready. Last log lines:"
    tail -30 /home/mks/printer_data/logs/klippy.log || true
    return 1
}

echo "Preparing source..."
prepare_klipper
prepare_moonraker
build_firmware "$ROOT/configs/eecan.config" "10000100" "klipper.uf2"
build_firmware "$ROOT/configs/mcu.config" "08008000" "klipper.bin"
cp -a "$BACKUP/klipper.uf2" "$BACKUP/eecan.uf2"
cp -a "$BACKUP/klipper.bin" "$BACKUP/mcu.bin"

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "Build finished. Nothing was flashed."
    exit 0
fi

if [ ! -f "$CAN_FLASH" ]; then
    echo "CanBoot flash tool was not found at $CAN_FLASH"
    exit 1
fi

mapfile -t UUIDS < <(parse_uuids)
MCU_UUID="${UUIDS[0]}"
EECAN_UUID="${UUIDS[1]}"
echo "Main board $MCU_UUID"
echo "Toolhead $EECAN_UUID"

require_idle

OLD_UF2=""
for candidate in /home/mks/klipper/out/klipper.uf2 /home/mks/KlipperScreen/klipper/out/klipper.uf2; do
    if [ -f "$candidate" ]; then
        OLD_UF2="$candidate"
        break
    fi
done
if [ -z "$OLD_UF2" ]; then
    echo "The previous toolhead file klipper.uf2 was not found, so this update cannot roll back the toolhead."
    exit 1
fi
cp -a "$OLD_UF2" "$BACKUP/eecan-previous.uf2"

echo
echo "Plug a USB lead from the toolhead into this printer's computer."
echo "The toolhead does not show up as a USB drive until the update asks it to."
echo "Type yes to continue."
read -r answer
if [ "$answer" != "yes" ]; then
    echo "Stopped before flashing."
    exit 1
fi

echo "Stopping Klipper."
sudo systemctl stop klipper
sudo ip link set can0 up type can bitrate 1000000

echo "Opening the toolhead USB bootloader."
request_bootloader "$EECAN_UUID"
if ! copy_uf2 "$BACKUP/eecan.uf2"; then
    echo "The toolhead USB drive did not appear, so no new toolhead firmware was written."
    echo "Power-cycle the printer. It will come back on its current firmware."
    sudo systemctl start klipper || true
    exit 1
fi
sleep 2
if ! can_query_has "$EECAN_UUID"; then
    echo "The toolhead did not return on CAN."
    restore_toolhead || true
    sudo systemctl start klipper || true
    exit 1
fi
echo "Toolhead firmware installed."

echo "Preparing the main-board flasher before resetting that board."
if ! prepare_mcu_flasher; then
    restore_toolhead || true
    sudo systemctl start klipper || true
    exit 1
fi

echo "Opening the main-board bootloader."
request_bootloader "$MCU_UUID"
found=0
for i in $(seq 1 30); do
    if [ -c /dev/ttyACM0 ] && lsusb | grep -q '1d50:6177'; then
        found=1
        break
    fi
    sleep 0.5
done
if [ "$found" != 1 ]; then
    echo "The main board did not open its serial bootloader."
    echo "If the toolhead is already on the new firmware, power-cycle the printer and run this script again."
    echo "A power cycle returns the main board to its current application."
    exit 1
fi

if ! python3 /tmp/x400-flash-mcu.py -d /dev/ttyACM0 -b 250000 -f "$BACKUP/mcu.bin"; then
    echo "Main board was not updated. Restoring the previous toolhead firmware."
    sleep 3
    sudo ip link set can0 up type can bitrate 1000000 || true
    restore_toolhead || true
    sudo systemctl start klipper || true
    exit 1
fi

echo "Waiting for the main board to return."
for i in $(seq 1 30); do
    if lsusb | grep -q '1d50:606f'; then
        break
    fi
    sleep 0.5
done
sudo ip link set can0 up type can bitrate 1000000 || true

install_trees
wait_ready

echo
echo "Update complete."
echo "Do not use the on-screen Update button. It resets the printer to the old Eryone package."
echo "The previous Klipper and Moonraker trees are in /home/mks/klipper-pre-x400-update and /home/mks/moonraker-pre-x400-update."
echo "The toolhead USB lead can be unplugged."
