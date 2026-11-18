# DJI 初代穿越摇杆（DJI FPV Motion Controller）→ 飞行摇杆 逆向报告

目标设备：`DJI C5`，初代体感摇杆（配初代 DJI FPV），USB 直连 macOS。

---

## 1. 设备指纹（实测）

| 项 | 值 |
|---|---|
| VID / PID | `0x2CA3` / `0x1020`（十进制 11427 / 4128） |
| 产品字符串 | `C5` |
| 序列号 | `3PSZKC########（已脱敏）` |
| bDeviceClass | `0xEF` / Sub 2 / Proto 1（复合设备 IAD） |
| USB 速度 | 480 Mbps（High Speed） |
| 复合功能 | HID GamePad × 1 + CDC-ACM 串口 × 2 |
| 串口节点 | `/dev/cu.usbmodem<SERIAL>3`、`…M5` |

**结论：它不需要"破解"就能被系统识别成标准 HID 手柄。** 真正卡住模拟器的是第 3 节那两条。

---

## 2. HID 协议（从 Report Descriptor 解出）

```
05 01 09 05  A1 01              Usage Page Generic Desktop / Usage Game Pad
  A1 00                          Collection (Physical)
  05 09 19 01 29 18 15 00 25 01 95 18 75 01 81 02   ; 24 buttons
  05 01 09 30 09 31 09 32 09 33 09 34               ; X Y Z Rx Ry
  16 00 FC  26 00 04                               ; logical -1024 .. +1024
  75 10 95 05 81 02                                ; 5 axes × int16 LE
```

输入报文 **13 字节**，无 Report ID，约 **196 Hz** 持续上报：

| 偏移 | 长度 | 内容 |
|---|---|---|
| 0..2 | 3 B | 24 键位图（小端，bit0 = Button 1） |
| 3..4 | int16 LE | **X** |
| 5..6 | int16 LE | **Y** |
| 7..8 | int16 LE | **Z** |
| 9..10 | int16 LE | **Rx** |
| 11..12 | int16 LE | **Ry** |

---

## 3. 轴语义（实测 + 官方控件表推导）

官方控件（DJI FPV 零售培训手册）：Lock 刹车键、Throttle trigger 扳机、Gear 档位键、
Emergency stop 急停键、**Gimbal tilt slide 云台俯仰拨轮**、Record 录像键。
**它没有机械摇杆**——姿态全部来自 IMU 体感。

| 轴 | 实际语义 | 实测依据 | 置信度 |
|---|---|---|---|
| **X / Y** | **地球坐标系**下的姿态分量（**不是**机身俯仰/横滚） | 改变朝向时两轴同时变化 | **确证** |
| **Rx** | **绝对航向**（−π..π，正北 = 0，正南处跳变） | 静止值随指向改变：−408 / −728 / −841 | **确证** |
| **Z** | **油门扳机** | 静止恒定 `-660`；扣到底 `+660`，行程 1291 | **确证** |
| **Ry** | 云台俯仰**三档开关**（上/中/下） | 全程恒定 `0`（中位），未被触发 | 高 |

> ⚠️ **重要修正（v1 报告写错，已改正）**
>
> 初版把 `X` / `Y` 直接当成机身俯仰/横滚、把 `Rx` 当成偏航角速度。这只在**朝向固定**时近似成立。
> 实际上 X/Y 是地球系分量、Rx 是绝对航向。其它实现（Hackaday #204697、
> f2knpw/DJI_motionController_JoystickGremlin_Plugin）给出了独立证据：
> Rx 从 −1..+1 映射到 −π..π，正北 = 0、正东 ≈ +0.5、正南 ≈ ±1 后回绕。

### 实测手势序列（三段手势，每段只有一根原始轴大幅运动）

| 时间 | 手势 | 主导原始轴 | 跨度 | 次要轴 |
|---|---|---|---|---|
| 174–177s | 上下点头 | **X** | 296 | Y≈19, Rx≈24 |
| 179–183s | 左右歪 | **Y** | 501 | X≈50, Rx≈90 |
| 185–188s | 左右拧 | **Rx** | 855 | X≈150, Y≈150 |
| 194–195s | 扣扳机 | **Z** | 1313 | — |

注意：这张表记录的是**原始轴**的变化，不是机身俯仰/横滚。当时朝向约 −128°，
所以「点头」主要改变原始 X，而机身的 pitch 与 roll 都随之变化。

### 从地球系转回机身系

```
h     = Rx / 1024 · π            (rad, 正北 = 0)
Pitch = −( Y/1024 · cos h − X/1024 · sin h )
Roll  = −( X/1024 · cos h + Y/1024 · sin h )
```

该变换正交，模长守恒（已在 0°/45°/90°/135°/180°/−90° 六个航向下验证）。
客户端「手部坐标系」开关即启用此式。

### 偏航要锁存

Rx 是绝对航向，直接接方向舵会一直满舵。可行做法（客户端已实现）：
按住云台开关上档时以按下瞬间为基准，输出**相对航向差**；松开则偏航归零。

### 按键（HID Button 位，已确认存在 4 个）

实测按下顺序与位号：`#4` → `#1` → `#2` → `#3` → `#3`（重复按）。

按键位到物理功能的**对应关系未确认**——按键报位不会自带标签。最快的确认方式：
打开 `DJI-HUD.command`，逐个按一遍，HUD 底部会实时高亮 `#N`，按一次记一个即可。
预期共 4 个 HID 键（Lock 刹车 / Gear 档位 / Emergency stop 急停 / Record 录像），
电源键不走 HID。

### 关键性质：**绝对姿态输出，不是摇杆偏移量**

静止 42 秒实测：`X=-301 Y=-392 Z=-660 Rx=-728 Ry=0`，全程只漂 1 个计数。

它报告的是"机身当前朝向"，而不是"你推了多少"。所以：

- 平放在桌上 → 它认为你一直歪着飞；
- **必须用你飞行时的握持姿势做一次标定**，把那一刻定义为中立点；
- 标定后，倾斜手掌 = 压杆，回正手掌 = 归中。这正是 DJI 自家 App 里那步"校准"。

---

## 4. 两条真实卡点

| 卡点 | 现象 | 解法 |
|---|---|---|
| SDL 控制器层不认 | `isGameController = 0`，SDL 系模拟器完全看不到它 | 注入映射串（第 5 节，已实测生效） |
| 绝对姿态不归零 | 模拟器满舵 | 标定中立点（第 6 / 7 节） |
| 航向是绝对值 | 方向舵一直满舵 | 航向差分 + Ry 锁存 |
| X/Y 在地球系 | 转身后俯仰横滚串味 | 按航向做旋转（见上节公式） |

已验证：加映射后 `isGameController` 由 `0` → `1`，可作为 GameController 打开并读到全部轴。

---

## 5. 路线 A：SDL 系模拟器（Liftoff / Velocidrone / DRL / Uncrashed…）

**投放方式 1（推荐，实测有效）**：启动前设环境变量

```bash
export SDL_GAMECONTROLLERCONFIG='0300703ba32c00002010000004040000,DJI C5,a:b0,b:b1,x:b2,y:b3,back:b4,start:b5,leftshoulder:b6,rightshoulder:b7,guide:b8,leftx:a0,lefty:a1,rightx:a3,righty:a4,lefttrigger:a2,platform:Mac OS X,'
open -a "Liftoff"
```

**投放方式 2**：把 `gamecontrollerdb.txt` 里那一行追加到模拟器包内
`Xxx.app/Contents/Resources/gamecontrollerdb.txt` 末尾。

> 实测：把 `gamecontrollerdb.txt` 放在工作目录**不会**被自动加载，只有环境变量和
> app bundle 内的文件两条路可靠。

---

## 6. 路线 B：X-Plane 12（已装，读 HID 直连）

设置 → **摇杆** → 左侧设备列表选 `C5`：

1. 点 **校准 / Calibrate**，按提示把姿态倾到各极限；
   **标定时用你实际飞行的握持姿势**，这决定中立点。
2. 逐轴指派：

| 轴 | 指派到 | 备注 |
|---|---|---|
| X | 俯仰 Pitch | 可能需要勾"反向" |
| Y | 滚转 Roll | 同上 |
| Rx | 偏航 Yaw | |
| Z（扳机） | 油门 Throttle | 单向：松手=`-660`，扣到底=`+660`，按最小/最大两点标定 |
| Ry（云台拨轮） | 不指派，或指到视角 | |

3. 保存为 control profile，换机型不用重做。

**注意**：X-Plane 的标定是一次性的。中途放下手柄或换握姿，中立点就变了 → 重新校准一次。

---

## 7. 路线 C：想让"任何模拟器"都认（硬件桥）

macOS 上用户态**无法**凭空造一个系统级虚拟 HID 手柄——`IOHIDUserDevice` 需要 Apple 的
`com.apple.developer.hid.virtual.device` 权限（Karabiner 那类才有）。
所以要让不支持原始 HID 的模拟器也认，现实方案是**外置一块 HID 桥**：

- 硬件：**必须能当 High-Speed USB 主机**——Pi Zero 2 W / Pi 4 / Pi 5（或同级 Linux SBC）
- 做法：板子做 USB Host 直读本设备，再用 USB gadget 模式对外呈现为标准 HID 摇杆；
  Pi 上可用 `/dev/hidraw` + `uinput`/`gadgetfs`，或参考
  [Achilles10101/dji-rc-mac](https://github.com/Achilles10101/dji-rc-mac) 的树莓派中转思路
- 优点：Windows / macOS / Linux 通吃，模拟器看成正牌摇杆
- 代价：要一块板子

> ⚠️ **RP2040 / ESP32-S3 不行。** 这类 MCU 的 USB 主机只支持 Full-Speed（12 Mbps），
> 而本设备是 High-Speed（480 Mbps），其**中断端点最大包长（MPS）为 512 字节**，
> 远超 Full-Speed 主机 64/128 字节的物理上限。实测会直接报
> `EP MPS (512) exceeds supported limit (128)` 与 `EP Alloc error: ESP_ERR_NOT_SUPPORTED`。
> 出处：[Hackaday #204697 的 ESP32-S3 失败记录](https://hackaday.io/project/204697/log/245281-esp32-s3-fails-to-read-dji-motion-controller)。
> 同理 MAX3421E（USB Host Shield）也是 Full-Speed，同样读不出来。

> 同一思路的 Windows 版参考实现：[LBValueX/DJI_RC-N1_winGamePad](https://github.com/LBValueX/DJI_RC-N1_winGamePad)
> （用 `vgamepad` 造虚拟手柄读 DJI 遥控器）——印证了"DJI 遥控器必须靠软件层转成游戏设备"。

---

## 8. 工具

| 文件 | 用途 |
|---|---|
| `dji_hud` / `DJI-HUD.command` | 实时 HUD，`c` 键把当前姿态设为中立点，显示各轴行程 |
| `hid_watch2` | 后台记录动作事件（抓轴/键对应关系） |
| `hid_dump` | 原始报文十六进制转储 |
| `sdl_probe2` / `sdl_map_test` | 验证模拟器侧到底能不能看见它 |
| `gamecontrollerdb.txt` | SDL 映射串 |

双击 `DJI-HUD.command` 即可打开。
