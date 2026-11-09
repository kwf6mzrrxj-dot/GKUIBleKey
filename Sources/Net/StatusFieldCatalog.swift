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
        .init(path: rangePath,
              title: "续航里程", note: "按当前油量估算还能开多远",
              kind: .number("km")),
        .init(path: fuelLevelPath,
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
        .init(path: batteryVoltagePath,
              title: "电瓶电压", note: "熄火静置时正常约 12.2–12.8 V，低于 12 V 可能亏电",
              kind: .number("V")),
        .init(path: "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.stateOfCharge",
              title: "电瓶电量", note: "蓄电池荷电状态（原始编码，非百分比）",
              kind: .text),
        .init(path: "additionalVehicleStatus.runningStatus.engineCoolantTemperature",
              title: "冷却液温度", note: "原始值按华氏度解读才合理（179 ≈ 82°C）。这条是推断，以实车为准",
              kind: .text)
    ]

    // MARK: - 关键路径（状态页白名单与车控页能源条共用）

    /// 油量（百分比）
    static let fuelLevelPath = "additionalVehicleStatus.runningStatus.fuelLevel"
    /// 续航里程
    static let rangePath = "basicVehicleStatus.distanceToEmpty"
    /// 电瓶电压
    static let batteryVoltagePath =
        "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.voltage"

    // MARK: - 取值

    /// 取原始数值。
    ///
    /// 与 `resolve` 的分工：
    /// - `resolve` 返回**给人看的字符串**（带单位、布尔转中文）
    /// - `number` 返回**给代码算的 Double**（需要自己换算时用，如 百分比 → 升数）
    ///
    /// 拿不到或不是数字时返回 nil —— 调用方据此整格不显示，不写占位。
    static func number(_ path: String, from fields: [StatusField]) -> Double? {
        guard let raw = fields.first(where: { $0.id == path })?.value,
              raw != "—", raw != "(空)" else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

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

    // MARK: - 语义归类（2026-11-07）
    //
    // 原来只有一刀切：白名单里的平铺，其余全塞进「其他原始字段」折叠区。
    // 那是**按代码结构**分组，不是按内容 —— 于是胎压预警、防盗布防这些
    // 最该一眼看到的东西，和白名单里那些看一眼就够的字段待遇完全相反。
    //
    // 现在按语义归到上面那六组里，折叠只留给真正的次要信息。

    /// 白名单之外字段的归属分组。`nil` = 归不进任何一组。
    ///
    /// ⚠️ 判定顺序就是优先级，不要随手调整：
    /// `climateStatus.winPosDriver` 同时含 `win` 和 `climate`，
    /// 它应该进「门窗」（车窗和车门是同一类东西），而不是「空调」。
    static func bucket(for field: StatusField) -> String? {
        let p = field.path.lowercased()

        if p.contains("tyre") || p.contains("tire") { return "胎压" }
        if p.contains("win") || p.contains("sunroof") || p.contains("door")
            || p.contains("trunk") || p.contains("hood") { return "门窗" }
        // `airclean` 而不是 `air`：`airbag`（气囊）里也有 air，
        // 用短词会把安全气囊归到空调。
        if p.contains("climate") || p.contains("seat") || p.contains("heat")
            || p.contains("airclean") { return "空调" }
        if p.contains("safety") || p.contains("brake") || p.contains("alarm")
            || p.contains("security") || p.contains("radar") || p.contains("airbag")
            || p.contains("belt") { return "安全" }
        if p.contains("maintenance") || p.contains("service")
            || p.contains("battery") || p.contains("odometer") { return "保养与电气" }
        if p.contains("running") || p.contains("fuel") || p.contains("engine")
            || p.contains("speed") || p.contains("consumption")
            || p.contains("distance") { return "行驶" }
        // `basicVehicleStatus.position.*` 故意不归类：
        // 位置已经由「车辆位置」地图卡完整表达，原始经纬度在这里既重复
        // 又是**微度**（112896568 这种），摆进正文只会让人以为车出问题了。
        return nil
    }

    /// 某个分组下「白名单之外、但语义属于这里」的字段。
    static func extras(for title: String, from fields: [StatusField]) -> [StatusField] {
        let known = Set(sections.flatMap { $0.specs.map(\.path) })
        return fields.filter { f in
            !known.contains(f.id) && !isFoldable(f) && bucket(for: f) == title
        }
    }

    /// 是否属于「次要、可以折叠」的信息。
    ///
    /// 判定分两层，都很必要：
    ///
    /// **① 结构层** —— 出厂参数、认不出的 key、归不进任何语义组的
    ///
    /// **② 值层** —— 这一层是看了真机截图才补的：有些字段名字翻出来了，
    /// 但**值本身没法给人看**。典型三种：
    /// - 原始布尔位（`true` / `false`）：没有中文语境时等于没说
    /// - 有效性标志（`*Valid` / `*Validity` / `*Flag`）：工程用，不是状态
    /// - 微度坐标（`latitude` = 112896568）：地图卡已经表达了，原值只会吓人
    ///
    /// 把这三类留在正文里，`行驶` 一栏会从 6 项涨到 16 项，其中一半是 `true`。
    static func isFoldable(_ field: StatusField) -> Bool {
        if field.group == "configuration" { return true }

        let meaning = FieldGlossary.meaning(for: field)
        guard meaning.translated else { return true }
        guard bucket(for: field) != nil else { return true }

        let leaf = field.path.split(separator: ".").last.map(String.init)?.lowercased()
            ?? field.path.lowercased()
        if leaf.contains("valid") || leaf.contains("validity")
            || leaf.contains("flag") || leaf.contains("enable") { return true }
        if leaf.contains("latitude") || leaf.contains("longitude") { return true }

        let v = field.value.trimmingCharacters(in: .whitespaces).lowercased()
        if v == "true" || v == "false" { return true }
        // 长串基本是编码、时间戳或权限位图，不是可读的量
        if field.value.count > 24 { return true }

        // 中文名只翻出一个属性词（"状态"/"开度"），没有说清是谁的 ——
        // 这种行放进正文只会让人问"什么东西的状态"。`ventilateStatus` 就是这样。
        if !meaning.resolved {
            let generic: Set<String> = ["状态", "开度", "时间", "余量", "距离",
                                        "次数", "类型", "编码", "位置"]
            if generic.contains(meaning.title) { return true }
        }

        return false
    }

    /// 折叠区的内容：次要但依然要能查到的字段。
    static func foldables(from fields: [StatusField]) -> [StatusField] {
        let known = Set(sections.flatMap { $0.specs.map(\.path) })
        return fields.filter { !known.contains($0.id) && isFoldable($0) }
    }
}
