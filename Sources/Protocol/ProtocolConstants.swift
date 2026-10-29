import Foundation
import CoreBluetooth

/// BLE GATT 参数。
///
/// 逆向依据：`ValeoCoreCommunication.framework` 二进制中的 UUID 字面量，
/// 且服务发现回调（`0xa880`–`0xaa60`）经反汇编确认了读写分工：
/// - 命中 `F000FF12` 的分支 → `setReadCharacteristic:` + `setNotifyValue:forCharacteristic:`
/// - 命中 `F000FF11` 的分支 → `setWriteCharacteristic:`
///
/// 后缀 `0451-4000-B000-000000000000` 是 TI BLE 芯片的基准 UUID。
public enum GATT {
    // CBUUID 不是 Sendable，这里显式标注以通过 Swift 6 并发检查
    public nonisolated(unsafe) static let serviceUUID = CBUUID(string: "F000FF10-0451-4000-B000-000000000000")

    /// ★★★ **广播里带的 Service UUID（16-bit `0x10FF`）—— 扫描时必须用这个**。
    ///
    /// ## 反汇编证据
    /// `ValeoCoreCommunication` 的 `-[VCBBluetoothManager startScan]`（`vcb.asm` `0x5974`）：
    /// ```asm
    /// adr  x2, #59908 ; Objc cfstring ref: @"10FF"
    /// bl   +[CBUUID UUIDWithString:]
    /// bl   +[NSArray arrayWithObjects:count:]
    /// bl   -[x0 scanForPeripheralsWithServices:options:]    ← 用 "10FF" 扫描
    /// ```
    ///
    /// ## 为什么这个区别是致命的
    /// - **`10FF`** 是车端**广播包里**带的 Service（16-bit）→ 用于**扫描过滤**
    /// - **`F000FF10`** 是**连接后**的 GATT Service（128-bit）→ 用于**发现服务**
    ///
    /// 两者**不是同一个 UUID**。之前拿 `F000FF10` 去扫描，
    /// iOS 会在系统层直接过滤掉（设备广播里没这个），表现为
    /// `isScanning = true` 但 `didDiscover` **零回调**。
    public nonisolated(unsafe) static let advServiceUUID = CBUUID(string: "10FF")
    /// 手机 → 模块（写）
    public nonisolated(unsafe) static let writeCharUUID = CBUUID(string: "F000FF11-0451-4000-B000-000000000000")
    /// 模块 → 手机（读 + notify）
    public nonisolated(unsafe) static let notifyCharUUID = CBUUID(string: "F000FF12-0451-4000-B000-000000000000")
}

/// **InBlue 命令号 —— 同时也是 `03` 帧末尾的控制码（同一个数）**。
///
/// ## 同一性证明（三段闭环）
///
/// **① `03` 帧末字节 = `command` 原值**
/// `+[IBMessageFactory responseMessageWithCommand:randomData:cidpu:]` @`0x13904`：
/// ```asm
/// mov   x23, x2                      ; x2 = command
/// strb  w23, [sp, #0x1f]
/// dataWithBytes:&cmd length:1        ; command 参与响应计算
/// ... calculateResponseforCidpu:randomData:command:
/// strb  w8, #0x03 ; appendBytes:1    ; 帧首字节 0x03
/// appendData:(16B 响应)
/// strb  w23 ; appendBytes:1          ; ★ 帧末字节 = command
/// ```
/// 长度 `dataWithCapacity:0x12` = 18 = 1 + 16 + 1，与抓包 `03` 帧 18B 完全一致。
///
/// **② 每个动作的命令号来自 `mov w2, #N` 立即数**
/// 见下表 `@` 地址，均为 `-[IBVehicle xxx]` 内 `openConnexionForCommand:` 的实参。
///
/// **③ 抓包行为吻合**
/// `20:59:50` 发 `03 …01` → `05` 首字节 `0x00`（车原本已锁，不变）；
/// `20:59:59` 发 `03 …02` → `05` 首字节 `0x40`（解锁，状态改变）。
/// 若按旧假设「`0x02` = 锁」，锁车后状态不该变化 —— 与实测矛盾。
///
/// ## 旧结论已作废
/// 早期把 `0x02`/`0x0C` 当作「锁/解锁的协议码」，那是把两个不同东西混在一起了：
/// `0x0C` 是预认证（`-[IBVehicle openConnectionWithPassiveStart]` @`0xb5a8`
/// → `openConnexionForCommand:0x0C`，日志字面量
/// `"send prehauthentification command"`），每 28 秒被后台调用一次
/// （抓包里 51 次），不是用户动作，也不是 RSSI 校准。
public enum IBCommandType: UInt8, CaseIterable, Sendable {
    /// `-[IBVehicle lock]` @`0xa0f4` → `mov w2, #1`
    case lock = 1
    /// `-[IBVehicle unlock]` @`0xa138` → `mov w2, #2`
    case unlock = 2
    /// `-[IBVehicle openCloseTrunk]` @`0xa17c` → `mov w2, #3`（开/关同一个命令，车端切换）
    case openCloseTrunk = 3
    /// `-[IBVehicle windowUp]` @`0xa1c0` → `mov w2, #4`
    case windowUp = 4
    /// `-[IBVehicle windowDown]` @`0xa204` → `mov w2, #5`
    case windowDown = 5
    /// `-[IBVehicle panic]` @`0xa248` → `mov w2, #6`（寻车/鸣笛）
    case panic = 6
    /// `-[IBVehicle requestPairedDevicesNames]` @`0xa30c` → `mov w2, #0xd`
    case requestPairedDevices = 0x0D
    /// `-[IBVehicle enablePassiveEntry]` @`0xa3d8` → `mov w2, #0x11`
    case enablePassiveEntry = 0x11
    /// `-[IBVehicle disablePassiveEntry]` @`0xa394` → `mov w2, #0x12`
    case disablePassiveEntry = 0x12
    /// `startPairing` @`0xa350`
    case pairing = 0x55

    public var label: String {
        switch self {
        case .lock:                return "锁车"
        case .unlock:              return "解锁"
        case .openCloseTrunk:      return "开关后备箱"
        case .windowUp:            return "关窗"
        case .windowDown:          return "开窗"
        case .panic:               return "寻车/鸣笛"
        case .requestPairedDevices: return "查询已配对设备"
        case .enablePassiveEntry:  return "开启无感进入"
        case .disablePassiveEntry: return "关闭无感进入"
        case .pairing:             return "配对"
        }
    }

    /// `03` 帧末尾的控制码 —— **与 `rawValue` 完全相同**。
    ///
    /// 保留这个别名是为了在调用点表达意图（"这是要写进帧里的字节"），
    /// 而不是让人以为还有第二层映射。所有 11 个命令都有值，
    /// 不存在"未确认所以拒发"的情况。
    public var controlCode: UInt8 { rawValue }
}
