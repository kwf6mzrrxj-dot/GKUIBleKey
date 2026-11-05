import Foundation

/// `IBCommandType`（蓝牙控制码）→ `VehicleCommand`（通道无关）的映射。
///
/// **故意单独一个文件**：`IBCommandType` 属于 BLE 协议层，而 `ControlChannel.swift`
/// 里放的是「通道无关」的类型（手表端也要编译）。
/// 如果把它们放一起，手表 target 就不得不把整个蓝牙协议栈一起编进去 ——
/// 那正是这次重构要去掉的东西。
extension IBCommandType {
    /// 蓝牙指令 → 通道无关指令。返回 nil 表示这条指令**只能走蓝牙**
    /// （配对、无感进入开关、查询已配对设备都是链路本地操作，云端没有对应接口）。
    var asVehicleCommand: VehicleCommand? {
        switch self {
        case .lock:         return .lock
        case .unlock:       return .unlock
        case .windowUp:     return .windowUp
        case .windowDown:   return .windowDown
        case .panic:        return .find
        case .openCloseTrunk, .requestPairedDevices,
             .enablePassiveEntry, .disablePassiveEntry, .pairing:
            return nil
        }
    }
}
