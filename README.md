# Thinker X400 Klipper update

This updates an Eryone Thinker X400 from the factory Klipper package to Klipper `282db764` (v0.13.0-822, 7 November 2026) and the Moonraker tree shipped here. The X400 behaviour is kept: power-loss resume, chamber-heater checks, probe retry, the RFID and pressure-sensor modules, a 2-point bed mesh, and the timer-too-close handling.

It updates the Klipper host, Moonraker, the main board, and the EECAN toolhead. It does not replace the touchscreen application or crowsnest.

The printer this was written for has:

- a main board that is an STM32F407 USB-CAN bridge, with CanBoot jumping to the application at `0x08008000` (32KiB)
- an RP2040 EECAN toolhead on CAN, GPIO8 receive and GPIO9 transmit, with no CAN bootloader

The script reads the CAN UUIDs from the printer. It refuses to write the main-board image if CanBoot reports a different application address.

## Before you start

- The printer is idle and the heaters are off.
- You can log in as `mks`. On a stock X400 the password, including for `sudo`, is `makerbase`.
- A USB lead can be plugged from the toolhead into the printer's computer. The toolhead firmware does not appear as a USB drive during normal use. The update puts it in USB boot mode, copies the new firmware, and it returns to CAN. If that drive does not appear, power-cycle the printer and it comes back on the firmware it already had.
- The on-screen Update button downloads the old Eryone package and will undo this. Do not use it after updating.

## Update

On the printer:

```bash
cd ~
git clone https://github.com/stonewatered/thinker-x400-klipper.git
cd thinker-x400-klipper
./update.sh
```

The script asks you to type `yes` after the toolhead USB lead is plugged in. The first run downloads Klipper and its libraries, then builds both boards on the printer. When it finishes, Klipper reports ready and the USB lead can be unplugged.

`./update.sh --build-only` downloads and compiles without flashing or restarting.

Klipper no longer accepts `max_accel_to_decel`. The script replaces it with `minimum_cruise_ratio`. When the old value was equal to `max_accel`, the new value is `0`, which is the same limit. The screen control that used to send `ACCEL_TO_DECEL` no longer works, because Klipper removed that command.

Previous trees are kept on the printer as `/home/mks/klipper-pre-x400-update` and `/home/mks/moonraker-pre-x400-update`. A log is written to `/home/mks/x400-update-backup/update.log`.

## What is in this repository

`overlay/` is the X400 code copied onto Klipper `282db764`. `moonraker/` is the Python 3.7-compatible Moonraker tree used by the X400, including the Eryone file-manager and machine changes. The stock timelapse component stays installed on the printer and is linked back in during the update. `configs/` are the two firmware builds.

Klipper and Moonraker are GPL-3.0. The overlay is distributed under the same license.
