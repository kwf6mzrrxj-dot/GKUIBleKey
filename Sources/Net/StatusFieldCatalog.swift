import Foundation

/// 状态页要展示的字段清单 —— **只保留对用户有判断价值的**。
///
/// ## 为什么需要白名单
/// `vehicleStatus` 服务端回了七十多个字段，其中至少一半是给车厂调试用的：
/// `radarStatus`、`configuration.*`、一堆积压的 `*Warning` 原始位。
/// 全列出来用户只会看到一屏看不懂的英文。
///
/// 但也不能硬编码死 —— 服务端加字段就看不见了。折中：
/// **白名单负责「展示哪些 + 怎么解释」，未知字段收进「其他」折叠区兜底**。
struct StatusFieldSpec: Identifiable {
    let path: String       // 完整路径，与 StatusField.id 对应
    let title: String      // 中文名
    let note: String       // 这个值意味着什么
    let kind: Kind

    var id: String { path }

    enum Kind {
        /// 带单位的值，如 108361.2 → "108361.2 km"
        case number(String)
        /// 布尔：1/true 显示 on，0/false 显示 off
        case flag(on: String, off: String)
        /// 原样显示（枚举字符串之类）
        case text
    }
}

enum StatusFieldCatalog {

    /// 分组顺序即展示顺序
    static let sections: [(title: String, specs: [StatusFieldSpec])] = [
        ("行驶", driving),
        ("胎压", tyres),
        ("门窗", openings),
        ("空调", climate),
        ("安全", safety),
        ("保养与电气", service)
    ]

    // MARK: - 行驶

    private static let driving: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.maintenanceStatus.odometer",
              title: "总里程", note: "车辆累计行驶里程",
              kind: .number("km")),
        .init(path: "basicVehicleStatus.distanceToEmpty",
              title: "续航里程", note: "按当前油量估算还能开多远",
              kind: .number("km")),
        .init(path: "additionalVehicleStatus.runningStatus.fuelLevel",
              title: "油量", note: "油箱剩余百分比",
              kind: .number("%")),
        .init(path: "additionalVehicleStatus.runningStatus.aveFuelConsumption",
              title: "平均油耗", note: "近期平均，单位 L/100km",
              kind: .number("L/100km")),
        .init(path: "additionalVehicleStatus.runningStatus.avgSpeed",
              title: "平均车速", note: "近期平均，单位 km/h",
              kind: .number("km/h")),
        .init(path: "basicVehicleStatus.engineStatus",
              title: "发动机", note: "engine_on = 正在运转，engine_off = 已熄火",
              kind: .text)
    ]

    // MARK: - 胎压

    private static let tyres: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyreStatusDriver",
              title: "左前胎压", note: "正常范围约 220–260 kPa，低于 200 需检查",
              kind: .number("kPa")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyreStatusPassenger",
              title: "右前胎压", note: "正常范围约 220–260 kPa",
              kind: .number("kPa")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyreStatusDriverRear",
              title: "左后胎压", note: "正常范围约 220–260 kPa",
              kind: .number("kPa")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyreStatusPassengerRear",
              title: "右后胎压", note: "正常范围约 220–260 kPa",
              kind: .number("kPa")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyrePreWarningDriver",
              title: "左前胎压报警", note: "厂端判定的缺气预警",
              kind: .flag(on: "报警", off: "正常")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyrePreWarningPassenger",
              title: "右前胎压报警", note: "厂端判定的缺气预警",
              kind: .flag(on: "报警", off: "正常")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyrePreWarningDriverRear",
              title: "左后胎压报警", note: "厂端判定的缺气预警",
              kind: .flag(on: "报警", off: "正常")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.tyrePreWarningPassengerRear",
              title: "右后胎压报警", note: "厂端判定的缺气预警",
              kind: .flag(on: "报警", off: "正常"))
    ]

    // MARK: - 门窗

    private static let openings: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.doorLockStatusDriver",
              title: "车锁", note: "1 = 四门已落锁。只有驾驶门这一路，其余门跟随中控",
              kind: .flag(on: "已锁", off: "未锁")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.doorOpenStatusDriver",
              title: "左前门", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.doorOpenStatusPassenger",
              title: "右前门", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.doorOpenStatusDriverRear",
              title: "左后门", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.doorOpenStatusPassengerRear",
              title: "右后门", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.trunkOpenStatus",
              title: "后备箱", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.engineHoodOpenStatus",
              title: "引擎盖", note: "1 = 打开",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.winPosDriver",
              title: "左前车窗", note: "开度百分比，0 = 全关",
              kind: .number("%")),
        .init(path: "additionalVehicleStatus.climateStatus.winPosPassenger",
              title: "右前车窗", note: "开度百分比，0 = 全关",
              kind: .number("%")),
        .init(path: "additionalVehicleStatus.climateStatus.winPosDriverRear",
              title: "左后车窗", note: "开度百分比，0 = 全关",
              kind: .number("%")),
        .init(path: "additionalVehicleStatus.climateStatus.winPosPassengerRear",
              title: "右后车窗", note: "开度百分比，0 = 全关",
              kind: .number("%")),
        .init(path: "additionalVehicleStatus.climateStatus.sunroofPos",
              title: "天窗开度", note: "百分比。注意 sunroofOpenStatus 恒为 1，判断开合要看这个",
              kind: .number("%"))
    ]

    // MARK: - 空调

    private static let climate: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.climateStatus.exteriorTemp",
              title: "车外温度", note: "车外环境温度。这套接口**没有**车内温度",
              kind: .number("°C")),
        .init(path: "additionalVehicleStatus.climateStatus.preClimateActive",
              title: "远程空调", note: "1 = 远程空调已开启（预热/预冷）",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.airCleanSts",
              title: "空气净化", note: "1 = 净化功能运行中",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.drvHeatSts",
              title: "主驾座椅加热", note: "1 = 加热中",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.passHeatingSts",
              title: "副驾座椅加热", note: "1 = 加热中",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.rlHeatingSts",
              title: "左后座椅加热", note: "1 = 加热中",
              kind: .flag(on: "开", off: "关")),
        .init(path: "additionalVehicleStatus.climateStatus.rrHeatingSts",
              title: "右后座椅加热", note: "1 = 加热中",
              kind: .flag(on: "开", off: "关"))
    ]

    // MARK: - 安全

    private static let safety: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.electricParkBrakeStatus",
              title: "电子手刹", note: "1 = 已拉起",
              kind: .flag(on: "已拉起", off: "已松开")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.vehicleAlarm",
              title: "防盗", note: "1 = 防盗系统已布防",
              kind: .flag(on: "已布防", off: "未布防")),
        .init(path: "additionalVehicleStatus.drivingSafetyStatus.engineOilPressureWarning",
              title: "机油压力告警", note: "1 = 压力异常，需尽快检查",
              kind: .flag(on: "告警", off: "正常"))
    ]

    // MARK: - 保养与电气

    private static let service: [StatusFieldSpec] = [
        .init(path: "additionalVehicleStatus.maintenanceStatus.distanceToService",
              title: "距下次保养", note: "还剩多少公里需要保养",
              kind: .number("km")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.voltage",
              title: "电瓶电压", note: "熄火静置时正常约 12.2–12.8 V，低于 12 V 可能亏电",
              kind: .number("V")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.stateOfCharge",
              title: "电瓶电量", note: "蓄电池荷电状态（原始编码，非百分比）",
              kind: .text),
        .init(path: "additionalVehicleStatus.runningStatus.engineCoolantTemperature",
              title: "冷却液温度", note: "原始值按华氏度解读才合理（179 ≈ 82°C）。这条是推断，以实车为准",
              kind: .text)
    ]

    // MARK: - 取值

    /// 从摊平后的字段表里取一项并按 `kind` 格式化。
    /// 字段不在响应里时返回 nil —— 界面整行不显示，不写「—」占位。
    static func resolve(_ spec: StatusFieldSpec, from fields: [StatusField]) -> String? {
        guard let raw = fields.first(where: { $0.id == spec.path })?.value,
              raw != "—", raw != "(空)" else { return nil }

        switch spec.kind {
        case .text:
            return raw

        case .number(let unit):
            guard let d = Double(raw) else { return raw + " " + unit }
            // 整数就不显示小数点，108361.2 这种保留一位
            let text = d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d)
            return text + " " + unit

        case .flag(let on, let off):
            let v = raw.lowercased()
            if ["1", "true", "yes"].contains(v) { return on }
            if ["0", "false", "no"].contains(v) { return off }
            return raw
        }
    }

    /// 白名单之外的字段 —— 放折叠区兜底，保证「拿到的都能看到」
    static func leftovers(from fields: [StatusField]) -> [StatusField] {
        let known = Set(sections.flatMap { $0.specs.map(\.path) })
        return fields.filter { !known.contains($0.id) }
    }
}
