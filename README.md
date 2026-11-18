# DJI 穿越摇杆 · macOS 标定台

把**大疆初代穿越摇杆**（DJI FPV Motion Controller，`VID 0x2CA3 / PID 0x1020`）变成 macOS 上可用的飞行摇杆。

> 官方从没给这根杆做过 macOS 驱动或模拟器支持。但它本身就是个标准 HID Game Pad——
> 真正卡住的是两件事：**模拟器的控制器层不认它**，以及**它输出的是绝对姿态，不是摇杆偏移量**。
> 这个项目把这两件事都解决了。

![通道标定](docs/screenshots/calibration.png)

![按键映射](docs/screenshots/keymap.png)

---

## 它到底是根什么杆

初代穿越摇杆是**体感控制器**：没有机械摇杆，飞行姿态全靠 IMU。官方控件只有
锁键（刹车）、油门扳机、档位键、急停、**云台俯仰拨轮**、录像键。

插上 macOS 后它枚举成一个复合设备：**1 个 HID Game Pad + 2 个 CDC-ACM 串口**。

### HID 报文（13 字节，约 196 Hz，无 Report ID）

| 偏移 | 长度 | 内容 |
|---|---|---|
| 0..2 | 3 B | 24 键位图（小端，bit0 = Button 1） |
| 3..4 | int16 LE | **X** |
| 5..6 | int16 LE | **Y** |
| 7..8 | int16 LE | **Z** |
| 9..10 | int16 LE | **Rx** |
| 11..12 | int16 LE | **Ry** |

### 轴映射（实测确证）

| 轴 | 物理动作 | 满量程实测 |
|---|---|---|
| **X** | 俯仰：手腕上下点头 | ±250~296 |
| **Y** | 横滚：手腕左右歪 | 501 |
| **Rx** | 偏航：手腕左右拧 | 855 |
| **Z** | 油门扳机 | `-660 → +660`（单向，行程 1313） |
| **Ry** | 云台俯仰拨轮 | 居中复位，常驻 `0` |

### 关键性质：输出的是「绝对姿态」

静止 96 秒实测只漂 1 个计数，稳得很——但静止值是 `X=-301 Y=-392 Rx=-729`，**不归零**。

它报告的是「机身当前朝向」，不是「你推了多少」。平放在桌上，它认为你一直歪着飞。
所以必须**用飞行握姿标定一次**，把那一姿态定义为中立点——这正是大疆自家 App 里那步"校准"。

---

## 三种用法

### ① 通道标定 + 模拟键盘（最稳，推荐）

任何模拟器/游戏都吃键盘，不依赖 HID 识别、不需要驱动、不需要权限（除了辅助功能的按键授权）。

每个通道独立标定：

1. 摆出**实际飞行握姿** → 点「回中」，这一姿态成为中点
2. 向前倾到想当满舵的角度 → 点「设 +最大」
3. 向后倾到反向满舵 → 点「设 -最大」

量程**正负分开存**，所以「向前 15°、向后 25°」这种真实摇杆手感可以直接复刻。

然后把倾斜量映射成按键：

| 通道 | 推 + | 拉 − |
|---|---|---|
| 俯仰 | ↓ | ↑ |
| 横滚 | → | ← |
| 偏航 | E | Q |
| 油门 | = | - |

物理按键 `#1–#4` 也能各自绑一个键盘键，支持**按住**和**切换**两种模式。

### ② SDL 映射串（Liftoff / Velocidrone / DRL / Uncrashed）

SDL 的摇杆层能看见它，但控制器层不认（`isGameController = 0`）——这些模拟器里它就是空气。
注入一条映射串即可解决：

```bash
export SDL_GAMECONTROLLERCONFIG='0300703ba32c00002010000004040000,DJI C5,a:b0,b:b1,x:b2,y:b3,back:b4,start:b5,leftshoulder:b6,rightshoulder:b7,guide:b8,leftx:a0,lefty:a1,rightx:a3,righty:a4,lefttrigger:a2,platform:Mac OS X,'
```

也可以把 [`docs/gamecontrollerdb.txt`](docs/gamecontrollerdb.txt) 里的那一行追加到
模拟器包内 `Xxx.app/Contents/Resources/gamecontrollerdb.txt` 末尾。

> 注意：把 `gamecontrollerdb.txt` 放在工作目录**不会**被自动加载。

### ③ X-Plane UDP 直驱

勾选客户端里的「驱动 X-Plane (UDP)」，按 50 Hz 用 DREF 协议推送：

| 通道 | dataref |
|---|---|
| 俯仰 | `sim/joystick/yoke_pitch_ratio` |
| 横滚 | `sim/joystick/yoke_roll_ratio` |
| 偏航 | `sim/joystick/yoke_heading_ratio` |
| 油门 | `sim/cockpit2/engine/actuators/throttle_ratio_all` |

这条路绕开了「模拟器认不认这块 HID」的全部问题。
用时记得在 X-Plane 里**别**再给 `C5` 指派轴，否则两路输入打架。

---

## 快速开始

要求：macOS 13+、Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/zhanghanlin10/dji-motion-controller-macos.git
cd dji-motion-controller-macos
./client/build.sh
open "client/DJI 穿越摇杆 标定台.app"
```

首次使用模拟键盘，需要授权：

**系统设置 → 隐私与安全性 → 辅助功能 → 勾选 `DJI 穿越摇杆 标定台`**

> app 为本地自签名（ad-hoc）。**每次重新编译后**系统会忘记授权，需重新勾一次。

配置保存在 `~/Library/Application Support/DJIJoystickClient/profile.json`，
包含通道标定 + 按键映射 + 阈值映射，下次启动自动载入。

---

## 目录结构

```
client/          SwiftUI 客户端（通道标定 + 模拟键盘 + X-Plane UDP）
  DJIJoystickClient.swift   单文件，约 800 行
  build.sh                  编译并打包 .app
tools/           逆向过程中用的诊断工具（纯 C，无依赖）
  hid_dump.c       原始报文十六进制转储
  hid_watch2.c     动作事件识别（自动切分"哪根轴动了"）
  dji_hud.c        终端实时 HUD + 回中捕获
  sdl_probe.c      看 SDL 到底能不能认出它
  sdl_map_test.c   验证映射串能否让 isGameController 翻成 1
docs/
  protocol.zh.md   完整逆向报告（设备指纹、报文协议、轴证据）
  gamecontrollerdb.txt
  screenshots/
```

编译诊断工具：`./tools/build.sh`

---

## 已知限制

- **只验证过初代穿越摇杆**（配初代 DJI FPV）。二代/Motion Controller 2 的 VID/PID 可能不同，
  用 `hidutil list | grep 0x2ca3` 确认自己的设备。
- macOS 用户态**无法**凭空造系统级虚拟 HID 摇杆（需要 Apple 的
  `com.apple.developer.hid.virtual.device` 授权）。所以要么走 SDL 映射，要么走键盘/UDP，
  要么上硬件桥（RP2040 之类做真 HID 摇杆）。
- 标定是一次性的：中途换握姿，中立点就变了，需要重新「回中」。
- 绝对姿态轴在中点附近有轻微噪声，靠死区处理。

---

## 逆向工具链

本项目不带任何私有 SDK，全部通过 macOS 公开的 IOKit HID API 完成：

- `IOHIDManager` 读原始输入报文
- `hidutil list` / `ioreg` 确认设备指纹与 Report Descriptor
- SDL2 复现模拟器侧的可见性判断
- CGEvent 合成键盘事件（需要辅助功能授权）

详细过程见 [`docs/protocol.zh.md`](docs/protocol.zh.md)。

---

## English

A macOS calibration studio + keyboard mapper for the **first-generation DJI FPV Motion Controller**
(`VID 0x2CA3 / PID 0x1020`).

The device already enumerates as a standard HID Game Pad (13-byte reports, 24 buttons + 5 axes).
Two things break simulator support: (1) SDL's game-controller layer rejects it, and
(2) the axes carry **absolute hand attitude**, not centred stick offsets.

This repo fixes both: per-channel asymmetric-range calibration, keyboard emulation
(works in any sim), an SDL mapping string, and an optional X-Plane DREF/UDP driver.

See [README.en.md](README.en.md) for details.

---

## License

MIT
