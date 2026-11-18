# DJI Motion Controller for macOS — Calibration Studio

Turn the **first-generation DJI FPV Motion Controller** (`VID 0x2CA3 / PID 0x1020`) into a usable
flight-sim joystick on macOS.

> It is already a standard HID Game Pad. Three things actually get in the way: simulators'
> game-controller layer rejects it, its axes carry **absolute attitude in the earth frame** rather
> than stick offsets, and **heading is an absolute angle** rather than a yaw amount.
> This project handles all three using only public macOS APIs — no driver, no security-policy changes.

![Calibration](docs/screenshots/calibration.png)

![Key mapping](docs/screenshots/keymap.png)

---

## What the device reports

The 1st-gen Motion Controller is a **motion controller**: no mechanical gimbal, attitude comes from an
IMU. Physical controls: lock/brake, throttle trigger, gear, emergency stop, a **three-position gimbal
switch**, and record.

It enumerates as a composite device: **1 HID Game Pad + 2 CDC-ACM serial ports**.

### HID report — 13 bytes, ~196 Hz, no Report ID

| Offset | Size | Content |
|---|---|---|
| 0..2 | 3 B | 24-button bitmap (little-endian, bit0 = Button 1) |
| 3..4 | int16 LE | **X** |
| 5..6 | int16 LE | **Y** |
| 7..8 | int16 LE | **Z** |
| 9..10 | int16 LE | **Rx** |
| 11..12 | int16 LE | **Ry** |

### What the five axes actually mean

| Axis | Meaning | Measured span |
|---|---|---|
| **X / Y** | attitude components **in the earth frame** — not body pitch/roll | ±1024 |
| **Rx** | **absolute heading** (−π..π, north = 0, wraps near south) | ±1024 |
| **Z** | throttle trigger | `-660 .. +660` (= ±0.64 full scale) |
| **Ry** | gimbal **three-position switch** (up / centre / down) | `−0.64 / 0 / +0.64` |

Only **four** buttons ever appear in the bitmap (`#1–#4`).

### Why it can't be used as a stick directly

**① X / Y are earth-frame.** Rotate your body and both change together. Body pitch/roll require a
heading rotation first:

```
h     = Rx / 1024 · π
Pitch = −( Y/1024 · cos h − X/1024 · sin h )
Roll  = −( X/1024 · cos h + Y/1024 · sin h )
```

The transform is orthonormal (magnitude preserved). Enable it with the **手部坐标系** (body frame)
toggle in the client.

**② Rx is absolute heading, not a yaw amount.** Point north → 0, east ≈ +0.5, south ≈ ±1 then wraps.
Wiring it straight to a rudder pins the control at full deflection. With **锁定 (Ry 触发)** enabled:

- hold the gimbal switch up → heading deltas are tracked relative to that instant and used as yaw
- release → yaw returns to zero and you can swing your arm freely

**③ The resting values are not zero.** Measured over 96 seconds at rest it drifts by one count — very
stable — but rests at `X=-301 Y=-392 Rx=-729`, because that *is* the current attitude. Calibrate once
in your flying grip and declare that pose neutral.

---

## Three ways to use it

### 1. Per-channel calibration + keyboard emulation (most reliable)

Every simulator accepts keyboard input — no HID recognition, no driver, no system entitlements beyond
the Accessibility grant for synthetic key events.

Per channel: hold in your **flying grip** → **Recenter**; tilt to full deflection → **Set +max**;
tilt the other way → **Set −max**. Ranges are stored **per side**, so an asymmetric feel is directly
reproducible.

Then map deflection to keys (Pitch ↓/↑, Roll →/←, Yaw E/Q, Throttle =/−). The four physical buttons
can each be bound to a key in **hold** or **toggle** mode.

### 2. SDL mapping string (Liftoff / Velocidrone / DRL / Uncrashed)

```bash
export SDL_GAMECONTROLLERCONFIG='0300703ba32c00002010000004040000,DJI C5,a:b0,b:b1,x:b2,y:b3,back:b4,start:b5,leftshoulder:b6,rightshoulder:b7,guide:b8,leftx:a0,lefty:a1,rightx:a3,righty:a4,lefttrigger:a2,platform:Mac OS X,'
```

Or append the line from [`docs/gamecontrollerdb.txt`](docs/gamecontrollerdb.txt) to the sim bundle's
`Contents/Resources/gamecontrollerdb.txt`.

> A `gamecontrollerdb.txt` in the working directory is **not** auto-loaded.

### 3. X-Plane UDP (DREF)

Enable "Drive X-Plane (UDP)"; it pushes at 50 Hz to `sim/joystick/yoke_*_ratio` and
`sim/cockpit2/engine/actuators/throttle_ratio_all`. Don't also assign axes to `C5` inside X-Plane.

---

## Prior art

As far as this search reaches, **no native macOS implementation of this exact controller existed**:

| Project | Platform | Approach | Handles heading? |
|---|---|---|---|
| [f2knpw/DJI_motionController_JoystickGremlin_Plugin](https://github.com/f2knpw/DJI_motionController_JoystickGremlin_Plugin) | Windows | JoystickGremlin + vJoy, Python | ✅ rotation + Ry latch |
| [Hackaday #204697](https://hackaday.io/project/204697-hacking-dji-motion-controller-as-regular-joystick) | Android | B4A test app + research notes | ✅ rotation + Ry latch |
| [Achilles10101/dji-rc-mac](https://github.com/Achilles10101/dji-rc-mac) | macOS | Raspberry Pi bridge → USB HID gamepad (DJI RC, not this controller) | — |
| **This project** | **native macOS** | HID direct + calibration + keyboard + UDP | ✅ rotation + Ry latch |

Cross-validation of measured values:

| Item | Measured here | Independently reported |
|---|---|---|
| Button count | only `#1–#4` ever assert | "4 buttons, 5 axes" |
| Trigger span | `−660..+660` (±0.645) | "Z capped at ±0.64" |
| Gimbal axis at rest | constant `0` | three-position switch, centre |

---

## Quick start

Requires macOS 13+ and Xcode Command Line Tools.

```bash
git clone https://github.com/zhanghanlin10/dji-motion-controller-macos.git
cd dji-motion-controller-macos
./client/build.sh
open "client/DJI 穿越摇杆 标定台.app"
```

Grant Accessibility for keyboard emulation:
**System Settings → Privacy & Security → Accessibility → enable `DJI 穿越摇杆 标定台`**

> Ad-hoc signed locally, so **every rebuild** may require re-granting.

## Limitations

- Only the **1st-gen** controller is verified (`hidutil list | grep 0x2ca3` to check yours).
- macOS user space cannot create a system-level virtual HID joystick without Apple's
  `com.apple.developer.hid.virtual.device` entitlement, so the paths are keyboard, SDL mapping, or UDP.
- A hardware bridge needs a **High-Speed USB host**: Pi Zero 2 W / Pi 4 / Pi 5. RP2040 and ESP32-S3
  are Full-Speed only and cannot read this device — its interrupt endpoint uses 512-byte MPS, far above
  the 64/128-byte Full-Speed limit.

## License

MIT
