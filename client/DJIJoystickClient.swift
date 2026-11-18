import SwiftUI
import AppKit
import Combine
import IOKit.hid
import ApplicationServices
import Darwin

// ═══════════════════════════════════════════════════════════
// MARK: - 通道模型
// ═══════════════════════════════════════════════════════════
struct Channel: Identifiable, Codable {
    var id = UUID()
    var name: String
    var axis: Int
    var enabled: Bool = true
    var invert: Bool = false
    var bipolar: Bool = true
    var center: Double = 0
    var maxPos: Double = 1024
    var maxNeg: Double = -1024
    var deadzone: Double = 0.02
    var expo: Double = 0.0
    var dataref: String = ""
    var key: String = ""

    func normalize(_ raw: Double) -> Double {
        guard enabled else { return 0 }
        let d = raw - center
        var n: Double
        if d >= 0 {
            n = min(1.0, d / max(1.0, maxPos - center))
        } else {
            n = max(-1.0, d / max(1.0, center - maxNeg))
        }
        let dz = max(0.0, min(0.9, deadzone))
        if abs(n) <= dz { n = 0 } else {
            let s = (abs(n) - dz) / (1.0 - dz)
            n = s * (n < 0 ? -1 : 1)
        }
        let e = max(0.0, min(1.0, expo))
        if e > 0 {
            let a = abs(n)
            n = ((1 - e) * a + e * a * a * a) * (n < 0 ? -1 : 1)
        }
        if invert { n = -n }
        return n
    }

    func output(_ raw: Double) -> Double {
        let n = normalize(raw)
        return bipolar ? n : (n + 1.0) * 0.5
    }

    var posSpan: Double { max(1, maxPos - center) }
    var negSpan: Double { max(1, center - maxNeg) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 键位表
// ═══════════════════════════════════════════════════════════
let keyCodeNames: [UInt16: String] = [
    0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
    12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",
    22:"6",23:"5",25:"9",26:"7",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",
    37:"L",38:"J",40:"K",45:"N",46:"M",24:"=",27:"-",30:"]",33:"[",39:"'",
    41:";",42:"\\",43:",",44:"/",47:".",50:"`",
    36:"Return",48:"Tab",49:"Space",51:"Delete",53:"Esc",
    96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",
    105:"F13",107:"F14",109:"F10",111:"F12",113:"F15",
    115:"Home",116:"PageUp",117:"FwdDel",118:"F4",119:"End",120:"F2",
    121:"PageDown",122:"F1",123:"←",124:"→",125:"↓",126:"↑"
]
func keyLabel(_ code: UInt16, _ mods: UInt) -> String {
    var s = ""
    let f = CGEventFlags(rawValue: UInt64(mods))
    if f.contains(.maskControl) { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift) { s += "⇧" }
    if f.contains(.maskCommand) { s += "⌘" }
    return s + (keyCodeNames[code] ?? "key\(code)")
}

// ═══════════════════════════════════════════════════════════
// MARK: - 键盘发送
// ═══════════════════════════════════════════════════════════
final class KeySender {
    static let shared = KeySender()
    private var held = Set<String>()

    var trusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func down(_ code: UInt16, _ mods: UInt) {
        let tag = "\(code)-\(mods)"
        guard !held.contains(tag) else { return }
        held.insert(tag)
        post(code, true, mods)
    }

    func up(_ code: UInt16, _ mods: UInt) {
        let tag = "\(code)-\(mods)"
        guard held.contains(tag) else { return }
        held.remove(tag)
        post(code, false, mods)
    }

    func releaseAll() {
        for tag in held {
            let parts = tag.split(separator: "-")
            if parts.count == 2, let c = UInt16(parts[0]), let m = UInt(parts[1]) {
                post(c, false, m)
            }
        }
        held.removeAll()
    }

    private func post(_ code: UInt16, _ down: Bool, _ mods: UInt) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { return }
        ev.flags = CGEventFlags(rawValue: UInt64(mods))
        ev.post(tap: .cghidEventTap)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 绑定模型
// ═══════════════════════════════════════════════════════════
struct KeyBinding: Identifiable, Codable {
    var id = UUID()
    var button: Int            // 1-based HID 按键号
    var keyCode: Int = -1      // -1 = 未绑定
    var mods: UInt = 0
    var toggle: Bool = false   // true = 按一下锁住，再按松开
    var enabled: Bool = true

    var label: String {
        keyCode < 0 ? "—" : keyLabel(UInt16(keyCode), mods)
    }
}

struct AxisKeyBinding: Identifiable, Codable {
    var id = UUID()
    var axis: Int
    var dir: Int               // 0 = 正向(推), 1 = 反向(拉)
    var threshold: Double = 0.5
    var keyCode: Int = -1
    var mods: UInt = 0
    var enabled: Bool = true

    var label: String { keyCode < 0 ? "—" : keyLabel(UInt16(keyCode), mods) }
}

struct Profile: Codable {
    var channels: [Channel]
    var keyBindings: [KeyBinding]
    var axisBindings: [AxisKeyBinding]
}

func defaultChannels() -> [Channel] {
    [
        Channel(name: "俯仰 Pitch", axis: 0, dataref: "sim/joystick/yoke_pitch_ratio", key: "手腕上下点头"),
        Channel(name: "横滚 Roll", axis: 1, dataref: "sim/joystick/yoke_roll_ratio", key: "手腕左右歪"),
        Channel(name: "油门 Throttle", axis: 2, bipolar: false, dataref: "sim/cockpit2/engine/actuators/throttle_ratio_all", key: "扳机"),
        Channel(name: "偏航 Yaw", axis: 3, dataref: "sim/joystick/yoke_heading_ratio", key: "手腕左右拧"),
        Channel(name: "云台 Gimbal", axis: 4, dataref: "", key: "侧面拨轮")
    ]
}
func defaultKeyBindings() -> [KeyBinding] { (1...24).map { KeyBinding(button: $0) } }
func defaultAxisBindings() -> [AxisKeyBinding] {
    var a: [AxisKeyBinding] = []
    for ax in 0..<5 { for d in 0..<2 { a.append(AxisKeyBinding(axis: ax, dir: d)) } }
    return a
}

// ═══════════════════════════════════════════════════════════
// MARK: - HID 读取
// ═══════════════════════════════════════════════════════════
final class HIDReader: ObservableObject {
    static let shared = HIDReader()
    @Published var raw: [Double] = [0, 0, 0, 0, 0]
    @Published var ema: [Double] = [0, 0, 0, 0, 0]
    @Published var buttons: UInt32 = 0
    @Published var connected = false
    @Published var rate: Double = 0

    private var manager: IOHIDManager?
    private var frameCount = 0, lastCount = 0
    private var lastTick = Date()
    private var timer: Timer?

    private init() { start() }

    private func start() {
        let ctx = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x2CA3,
            kIOHIDProductIDKey as String: 0x1020
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(mgr, hidReportCallback, ctx)
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidMatched, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        connected = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        manager = mgr
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let dt = Date().timeIntervalSince(self.lastTick)
            if dt > 0 { self.rate = Double(self.frameCount - self.lastCount) / dt }
            self.lastCount = self.frameCount
            self.lastTick = Date()
        }
    }

    fileprivate func ingest(_ v: [Double], _ b: UInt32) {
        raw = v
        let a = 0.25
        for i in 0..<5 { ema[i] = ema[i] * (1 - a) + v[i] * a }
        buttons = b
        frameCount += 1
    }
}

private func hidMatched(context: UnsafeMutableRawPointer?, result: IOReturn,
                        sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    DispatchQueue.main.async { HIDReader.shared.connected = true }
}

private func hidReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                               sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                               reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                               reportLength: CFIndex) {
    guard reportLength >= 13 else { return }
    var v = [Double](repeating: 0, count: 5)
    for i in 0..<5 {
        var x = Double(report[3 + i * 2]) + Double(report[4 + i * 2]) * 256.0
        if x >= 32768 { x -= 65536 }
        v[i] = x
    }
    let b = UInt32(report[0]) | (UInt32(report[1]) << 8) | (UInt32(report[2]) << 16)
    DispatchQueue.main.async { HIDReader.shared.ingest(v, b) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - X-Plane UDP
// ═══════════════════════════════════════════════════════════
final class XPlaneLink {
    static let shared = XPlaneLink()
    var enabled = false
    var host = "127.0.0.1"
    var port: UInt16 = 49000

    func send(_ path: String, _ value: Float) {
        guard enabled, !path.isEmpty else { return }
        var p = [UInt8]()
        p.append(contentsOf: Array("DREF".utf8)); p.append(0)
        var f = value.bitPattern.littleEndian
        withUnsafeBytes(of: &f) { p.append(contentsOf: $0) }
        p.append(contentsOf: Array(path.utf8))
        if p.count > 509 { return }
        while p.count < 509 { p.append(0) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        p.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, buf.baseAddress, p.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 存储
// ═══════════════════════════════════════════════════════════
let storageURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DJIJoystickClient", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("profile.json")
}()

// ═══════════════════════════════════════════════════════════
// MARK: - 小组件
// ═══════════════════════════════════════════════════════════
struct AxisBar: View {
    var n: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height, mid = w / 2
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.18))
                Rectangle().fill(Color.orange.opacity(0.45)).frame(width: 1.5, height: h).offset(x: w * 0.2)
                Rectangle().fill(Color.orange.opacity(0.45)).frame(width: 1.5, height: h).offset(x: w * 0.8)
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: h).offset(x: mid)
                let x = mid + max(-1, min(1, n)) * mid
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                    .frame(width: 3, height: h)
                    .offset(x: max(0, min(w - 3, x)))
            }
        }
    }
}

struct AttitudeScope: View {
    var pitch: Double, roll: Double, yaw: Double, thr: Double
    var body: some View {
        VStack(spacing: 8) {
            Text("姿态盘").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let r = s / 2 - 6
                ZStack {
                    Circle().fill(Color.black.opacity(0.20))
                    Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    Circle().strokeBorder(Color.orange.opacity(0.30), lineWidth: 1)
                        .frame(width: r * 2 * 0.55, height: r * 2 * 0.55)
                    Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: 1, height: r * 2)
                    Rectangle().fill(Color.secondary.opacity(0.22)).frame(width: r * 2, height: 1)
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                        .position(x: c.x + max(-1, min(1, roll)) * r,
                                  y: c.y - max(-1, min(1, pitch)) * r)
                }
            }
            .frame(width: 150, height: 150)
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "俯仰 %+.2f", pitch)).font(.system(size: 10, design: .monospaced))
                    Text(String(format: "横滚 %+.2f", roll)).font(.system(size: 10, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "偏航 %+.2f", yaw)).font(.system(size: 10, design: .monospaced))
                    Text(String(format: "油门 %+.2f", thr)).font(.system(size: 10, design: .monospaced))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 通道标定行
// ═══════════════════════════════════════════════════════════
struct ChannelRow: View {
    @Binding var ch: Channel
    var rawValue: Double
    var capture: Double
    var onRecenter: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: $ch.enabled).labelsHidden().controlSize(.mini)
                TextField("通道名", text: $ch.name).textFieldStyle(.roundedBorder).frame(width: 120)
                Text(ch.key).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 86, alignment: .leading)
                Text("\(Int(rawValue))").font(.system(size: 12, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(ch.enabled ? Color.primary : Color.secondary)
                AxisBar(n: ch.normalize(rawValue)).frame(width: 200, height: 16)
                Text(String(format: "%+.2f", ch.normalize(rawValue)))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
                    .foregroundStyle(ch.normalize(rawValue) == 0 ? Color.secondary : Color.accentColor)
                Spacer()
                Button("回中") { onRecenter() }.controlSize(.small)
                Button("设 +最大") { ch.maxPos = max(ch.center + 1, capture) }.controlSize(.small)
                Button("设 -最大") { ch.maxNeg = min(ch.center - 1, capture) }.controlSize(.small)
                Toggle("反向", isOn: $ch.invert).controlSize(.mini).padding(.trailing, 8)
            }
            HStack(spacing: 12) {
                Group {
                    Text("中点 \(Int(ch.center))")
                    Text("正满 +\(Int(ch.posSpan))")
                    Text("负满 -\(Int(ch.negSpan))")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1).fixedSize()

                Text("死区").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Slider(value: $ch.deadzone, in: 0...0.3).frame(width: 80).controlSize(.mini)
                Text(String(format: "%.2f", ch.deadzone)).font(.system(size: 10, design: .monospaced)).frame(width: 30)

                Text("曲线").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Slider(value: $ch.expo, in: 0...1).frame(width: 80).controlSize(.mini)
                Text(String(format: "%.2f", ch.expo)).font(.system(size: 10, design: .monospaced)).frame(width: 30)

                Text("输出").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Picker("", selection: $ch.bipolar) {
                    Text("-1…1").tag(true)
                    Text("0…1").tag(false)
                }.labelsHidden().frame(width: 72).controlSize(.mini).fixedSize()

                Text("Dataref").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                TextField("X-Plane dataref", text: $ch.dataref)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(minWidth: 250).layoutPriority(1)
            }
        }
        .padding(.vertical, 6)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 按键映射面板
// ═══════════════════════════════════════════════════════════
enum CaptureTarget: Equatable {
    case button(Int)
    case axis(UUID)
}

struct KeymapView: View {
    @Binding var keyBindings: [KeyBinding]
    @Binding var axisBindings: [AxisKeyBinding]
    @Binding var channels: [Channel]
    @Binding var captureTarget: CaptureTarget?
    @ObservedObject var hid = HIDReader.shared
    @State private var selectedButton = 1
    @State private var permTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionBanner
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("物理按键 → 键盘").font(.system(size: 12, weight: .semibold))
                    Text("点一下按键卡片选中，再点「学习按键」按下你要绑的键")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 6), count: 12), spacing: 6) {
                        ForEach(keyBindings) { b in
                            Button {
                                selectedButton = b.button
                            } label: {
                                VStack(spacing: 1) {
                                    Text("#\(b.button)")
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(b.label)
                                        .font(.system(size: 9, design: .monospaced))
                                        .lineLimit(1)
                                }
                                .frame(width: 56, height: 30)
                                .background(chipColor(b))
                                .foregroundStyle(chipFg(b))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                editorPanel
            }
            Divider()
            axisPanel
        }
    }

    func isPressed(_ n: Int) -> Bool {
        n - 1 < 24 && ((hid.buttons >> UInt32(n - 1)) & 1) == 1
    }
    func isLearning(_ n: Int) -> Bool {
        if case .button(let x) = captureTarget { return x == n }
        return false
    }
    func chipColor(_ b: KeyBinding) -> Color {
        if isLearning(b.button) { return Color.orange.opacity(0.85) }
        if isPressed(b.button) { return Color.accentColor }
        if b.keyCode < 0 { return Color.secondary.opacity(0.12) }
        return Color.secondary.opacity(0.25)
    }
    func chipFg(_ b: KeyBinding) -> Color {
        (isPressed(b.button) || isLearning(b.button)) ? .white : .primary
    }

    var permissionBanner: some View {
        HStack(spacing: 10) {
            let ok = KeySender.shared.trusted
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(ok ? "辅助功能权限：已授权，可以发送键盘事件"
                    : "辅助功能权限：未授权 —— 模拟键盘不会生效")
                .font(.system(size: 11))
                .foregroundStyle(ok ? Color.secondary : Color.orange)
            if !ok {
                Button("去授权") { KeySender.shared.requestPermission(); permTick += 1 }
                    .controlSize(.small)
            }
            Button("重新检测") { permTick += 1 }.controlSize(.small)
            Text("").id(permTick)
            Spacer()
        }
    }

    var editorPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let idx = keyBindings.firstIndex(where: { $0.button == selectedButton }) {
                Text("按键 #\(selectedButton)").font(.system(size: 13, weight: .semibold))
                HStack {
                    Text("当前绑定").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(keyBindings[idx].label)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(keyBindings[idx].keyCode < 0 ? Color.secondary : Color.accentColor)
                }
                HStack(spacing: 8) {
                    Button(isLearning(selectedButton) ? "等待按键…" : "学习按键") {
                        captureTarget = .button(selectedButton)
                    }
                    Button("清除") {
                        keyBindings[idx].keyCode = -1
                        keyBindings[idx].mods = 0
                    }
                    Button("测试") {
                        if keyBindings[idx].keyCode >= 0 {
                            let k = UInt16(keyBindings[idx].keyCode)
                            KeySender.shared.down(k, keyBindings[idx].mods)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                KeySender.shared.up(k, keyBindings[idx].mods)
                            }
                        }
                    }
                }
                .controlSize(.small)
                Toggle("切换模式（按一下锁住，再按松开）",
                       isOn: Binding(get: { keyBindings[idx].toggle },
                                     set: { keyBindings[idx].toggle = $0 }))
                    .controlSize(.mini)
                Toggle("启用", isOn: Binding(get: { keyBindings[idx].enabled },
                                            set: { keyBindings[idx].enabled = $0 }))
                    .controlSize(.mini)
                Text("实测该摇杆有 4 个 HID 按键（#1–#4），其余位不会触发")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 300, alignment: .leading)
    }

    var axisPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("通道阈值 → 键盘").font(.system(size: 12, weight: .semibold))
            Text("把倾斜/扳机越过阈值转成按键（方向键、W/S 之类），适合只吃键盘的模拟器")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(channels.indices, id: \.self) { ci in
                HStack(spacing: 10) {
                    Text(channels[ci].name).font(.system(size: 11)).frame(width: 110, alignment: .leading)
                    ForEach(axisBindings.filter { $0.axis == ci }) { ab in
                        if let ai = axisBindings.firstIndex(where: { $0.id == ab.id }) {
                            HStack(spacing: 4) {
                                Text(ab.dir == 0 ? "推 +" : "拉 −")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 34)
                                Text(ab.label)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 54)
                                    .foregroundStyle(ab.keyCode < 0 ? Color.secondary : Color.accentColor)
                                Button("学习") { captureTarget = .axis(ab.id) }.controlSize(.small)
                                Slider(value: Binding(get: { axisBindings[ai].threshold },
                                                      set: { axisBindings[ai].threshold = $0 }),
                                       in: 0.1...0.95).frame(width: 80).controlSize(.mini)
                                Text(String(format: "%.2f", ab.threshold))
                                    .font(.system(size: 9, design: .monospaced)).frame(width: 28)
                                Toggle("", isOn: Binding(get: { axisBindings[ai].enabled },
                                                         set: { axisBindings[ai].enabled = $0 }))
                                    .labelsHidden().controlSize(.mini)
                            }
                            .frame(width: 360, alignment: .leading)
                        }
                    }
                    Spacer()
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - 主界面
// ═══════════════════════════════════════════════════════════
struct ContentView: View {
    @ObservedObject var hid = HIDReader.shared
    @AppStorage("tab") private var tab = 0
    @State private var channels: [Channel] = defaultChannels()
    @State private var keyBindings: [KeyBinding] = defaultKeyBindings()
    @State private var axisBindings: [AxisKeyBinding] = defaultAxisBindings()
    @State private var captureTarget: CaptureTarget?
    @State private var xplaneOn = false
    @State private var xplaneHost = "127.0.0.1"
    @State private var xplanePort = "49000"
    @State private var didAutoCenter = false
    @State private var status = ""
    @State private var tick: Timer?
    @State private var monitor: Any?
    @State private var btnWas: [Int: Bool] = [:]
    @State private var axisWas: [UUID: Bool] = [:]
    @State private var toggleLocked: [Int: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $tab) {
                Text("通道标定").tag(0)
                Text("按键映射").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Divider()
            if tab == 0 { calibration } else {
                KeymapView(keyBindings: $keyBindings, axisBindings: $axisBindings,
                           channels: $channels, captureTarget: $captureTarget)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(minWidth: 1420, minHeight: 620)
        .onAppear { load(); startLoops(); startKeyMonitor() }
        .onDisappear {
            tick?.invalidate()
            if let m = monitor { NSEvent.removeMonitor(m) }
            KeySender.shared.releaseAll()
        }
        .onChange(of: hid.raw) { _, _ in autoCenterOnce() }
    }

    var calibration: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach($channels) { $ch in
                        ChannelRow(ch: $ch, rawValue: raw(for: ch.axis), capture: smooth(for: ch.axis)) {
                            ch.center = smooth(for: ch.axis)
                        }
                        Divider().opacity(0.25)
                    }
                }
            }
            AttitudeScope(pitch: channels[0].normalize(smooth(for: 0)),
                          roll: channels[1].normalize(smooth(for: 1)),
                          yaw: channels[3].normalize(smooth(for: 3)),
                          thr: channels[2].normalize(smooth(for: 2)))
                .frame(width: 180)
        }
    }

    func raw(for a: Int) -> Double { a < hid.raw.count ? hid.raw[a] : 0 }
    func smooth(for a: Int) -> Double { a < hid.ema.count ? hid.ema[a] : 0 }

    var header: some View {
        HStack(spacing: 14) {
            Text("DJI 穿越摇杆 · 标定台").font(.system(size: 15, weight: .semibold))
            Circle().fill(hid.connected ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(hid.connected ? "已连接 C5 (0x2CA3:0x1020)" : "未连接")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("\(Int(hid.rate)) Hz").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Button("全部回中") {
                for i in channels.indices { channels[i].center = smooth(for: channels[i].axis) }
                status = "所有通道已以当前姿态为中点"
            }
            .keyboardShortcut("r", modifiers: .command)
            .controlSize(.large)
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("驱动 X-Plane (UDP)", isOn: $xplaneOn)
                    .onChange(of: xplaneOn) { _, v in
                        XPlaneLink.shared.enabled = v
                        XPlaneLink.shared.host = xplaneHost
                        XPlaneLink.shared.port = UInt16(xplanePort) ?? 49000
                    }
                TextField("主机", text: $xplaneHost).frame(width: 100).textFieldStyle(.roundedBorder)
                TextField("端口", text: $xplanePort).frame(width: 66).textFieldStyle(.roundedBorder)
                Spacer()
                Button("保存") { save() }
                Button("载入") { load() }
                Button("恢复默认") {
                    channels = defaultChannels()
                    keyBindings = defaultKeyBindings()
                    axisBindings = defaultAxisBindings()
                    didAutoCenter = true
                }
            }
            HStack(spacing: 12) {
                Text("按键").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(0..<24, id: \.self) { i in
                    let on = (hid.buttons >> UInt32(i)) & 1 == 1
                    Text("#\(i + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.12))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    func autoCenterOnce() {
        guard !didAutoCenter, hid.raw.contains(where: { $0 != 0 }) else { return }
        didAutoCenter = true
        for i in channels.indices {
            let r = smooth(for: channels[i].axis)
            channels[i].center = r
            channels[i].maxPos = r + 300
            channels[i].maxNeg = r - 300
        }
        status = "已自动把当前姿态设为中点（请在实际飞行握姿下重新点「回中」）"
    }

    func startLoops() {
        tick = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            processButtons()
            processAxes()
            if XPlaneLink.shared.enabled {
                for ch in channels where ch.enabled && !ch.dataref.isEmpty {
                    XPlaneLink.shared.send(ch.dataref, Float(ch.output(raw(for: ch.axis))))
                }
            }
        }
    }

    func processButtons() {
        for b in keyBindings where b.enabled && b.keyCode >= 0 {
            let pressed = b.button >= 1 && b.button <= 24
                && ((hid.buttons >> UInt32(b.button - 1)) & 1) == 1
            let was = btnWas[b.button] ?? false
            let code = UInt16(b.keyCode)
            if b.toggle {
                if pressed && !was {
                    let locked = toggleLocked[b.button] ?? false
                    if locked {
                        KeySender.shared.up(code, b.mods)
                        toggleLocked[b.button] = false
                    } else {
                        KeySender.shared.down(code, b.mods)
                        toggleLocked[b.button] = true
                    }
                }
            } else {
                if pressed && !was { KeySender.shared.down(code, b.mods) }
                else if !pressed && was { KeySender.shared.up(code, b.mods) }
            }
            btnWas[b.button] = pressed
        }
    }

    func processAxes() {
        for ab in axisBindings where ab.enabled && ab.keyCode >= 0 {
            guard ab.axis < channels.count else { continue }
            let n = channels[ab.axis].normalize(smooth(for: ab.axis))
            let v = ab.dir == 0 ? n : -n
            let was = axisWas[ab.id] ?? false
            let on = was ? (v > ab.threshold - 0.06) : (v > ab.threshold)
            if on != was {
                axisWas[ab.id] = on
                let code = UInt16(ab.keyCode)
                if on { KeySender.shared.down(code, ab.mods) }
                else { KeySender.shared.up(code, ab.mods) }
            }
        }
    }

    func startKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { ev in
            guard let t = captureTarget else { return ev }
            if ev.keyCode == 53 { captureTarget = nil; return nil }
            var mods: UInt = 0
            if ev.modifierFlags.contains(.control) { mods |= UInt(CGEventFlags.maskControl.rawValue) }
            if ev.modifierFlags.contains(.option)  { mods |= UInt(CGEventFlags.maskAlternate.rawValue) }
            if ev.modifierFlags.contains(.shift)   { mods |= UInt(CGEventFlags.maskShift.rawValue) }
            if ev.modifierFlags.contains(.command) { mods |= UInt(CGEventFlags.maskCommand.rawValue) }
            switch t {
            case .button(let n):
                if let i = keyBindings.firstIndex(where: { $0.button == n }) {
                    keyBindings[i].keyCode = Int(ev.keyCode)
                    keyBindings[i].mods = mods
                    status = "按键 #\(n) → \(keyBindings[i].label)"
                }
            case .axis(let id):
                if let i = axisBindings.firstIndex(where: { $0.id == id }) {
                    axisBindings[i].keyCode = Int(ev.keyCode)
                    axisBindings[i].mods = mods
                    status = "通道 \(channels[axisBindings[i].axis].name) \(axisBindings[i].dir == 0 ? "推" : "拉") → \(axisBindings[i].label)"
                }
            }
            captureTarget = nil
            return nil
        }
    }

    func save() {
        let p = Profile(channels: channels, keyBindings: keyBindings, axisBindings: axisBindings)
        do {
            try JSONEncoder().encode(p).write(to: storageURL)
            status = "已保存"
        } catch { status = "保存失败: \(error.localizedDescription)" }
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        if let p = try? JSONDecoder().decode(Profile.self, from: data) {
            channels = p.channels
            keyBindings = p.keyBindings.isEmpty ? defaultKeyBindings() : p.keyBindings
            axisBindings = p.axisBindings.isEmpty ? defaultAxisBindings() : p.axisBindings
            didAutoCenter = true
            status = "已载入配置"
        } else if let arr = try? JSONDecoder().decode([Channel].self, from: data), arr.count == 5 {
            channels = arr
            didAutoCenter = true
            status = "已载入旧版配置（仅通道）"
        }
    }
}

@main
struct DJIJoystickClientApp: App {
    var body: some Scene {
        WindowGroup("DJI 穿越摇杆 标定台") { ContentView() }
            .windowResizability(.contentMinSize)
    }
}
