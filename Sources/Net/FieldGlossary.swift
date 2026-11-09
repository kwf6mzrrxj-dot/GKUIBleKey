import Foundation

/// 车辆原始字段的**语义词典**。
///
/// ## 为什么需要它
/// `vehicleStatus` 服务端回了七十多个字段。白名单（`StatusFieldCatalog`）精译了
/// 其中四十个，剩下的全堆在「其他原始字段」折叠区里，显示成
/// `drivingSafetyStatus.eVPSStatus` 这种东西 ——
/// 它不是"数据"，是一串英文。用户看到只会得出两个结论之一：
/// 「这 App 还有没写完的地方」或者「我车是不是有问题」，两种都是错的。
///
/// ## 三层解析
/// 1. **精确词条**：完整路径命中 `exact` → 直接给中文名 + 用途
/// 2. **组合拆解**：按驼峰切词，把词根分成「位置 / 对象 / 属性」三类再拼成中文，
///    用途由**属性类别**决定（告警位、开度、电压…）
/// 3. **兜底**：拼不出时保留原始 key，并明确写「中文名未定义」
///
/// 第 3 层是刻意的：**不懂就说不懂**。给一个猜的译名比不给更危险 ——
/// 用户会把猜的当真的，而"未定义"至少不会误导。
///
/// ## 局限（写在这里省得以后有人当 bug 修）
/// 这套解析基于车厂接口的命名惯例（`tyrePreWarningDriverRear` 这类），
/// 对**符合惯例**的字段准确率高；如果服务端哪天回了拼音或纯数字 key，
/// 它会退到第 3 层。那时候该做的是补 `exact` 词条，不是改拆词规则。
enum FieldGlossary {

    struct Meaning {
        /// 中文名
        let title: String
        /// 这个值意味着什么、能拿它做什么
        let note: String
        /// 中文名是不是真的翻出来的。
        ///
        /// `false` 表示只保留了原始 key —— 这种字段归入折叠区，
        /// 因为一个看不懂的英文 key 放进正文只是噪音。
        let translated: Bool
        /// 是否**完整**翻译（没有未识别的词根）。
        /// 为 false 但 `translated` 为 true 时，界面上仍显示中文名 + 「未译」小标。
        let resolved: Bool
        /// 值的语义形态。界面据此把原始值翻成人话：
        /// `1` → 「已锁」、`1792403199` → 「10-24 19:27」。
        let kind: Kind

        enum Kind {
            case text
            case number
            /// 0/1 布尔位 —— 原始值对用户毫无意义，必须换成中英文
            case flag(on: String, off: String)
            /// Unix 时间戳（10 位秒 / 13 位毫秒）
            case timestamp
        }

        init(title: String, note: String,
             translated: Bool = true, resolved: Bool = true,
             kind: Kind = .text) {
            self.title = title
            self.note = note
            self.translated = translated
            self.resolved = resolved
            self.kind = kind
        }
    }

    // MARK: - 入口

    static func meaning(for field: StatusField) -> Meaning {
        if let exact = exact[field.id] ?? exact[field.path] {
            return exact
        }

        var meaning = composed(field)

        // `configuration.*` 全是出厂参数：单个字段名未必认得，
        // 但"这一类是什么"是确定的 —— 补一句，免得用户以为它该随使用变化。
        if field.group == "configuration" {
            meaning = Meaning(
                title: meaning.title,
                note: appended(meaning.note, "属出厂配置参数，与这台车的硬件绑定，不随使用变化"),
                translated: meaning.translated,
                resolved: meaning.resolved)
        }
        return meaning
    }

    /// 分组名的中文。摊平后 `group` 只有第一层 key。
    static func groupTitle(_ group: String) -> String {
        groupNames[group] ?? group
    }

    // MARK: - 精确词条

    /// 白名单之外、但值得逐条说清楚用途的字段。
    ///
    /// 注意 key 用**完整路径**（含 group 前缀）优先，其次去掉 group 的 `path` ——
    /// 后者是为了同一个词在不同 group 下复用。
    private static let exact: [String: Meaning] = [
        // 基础状态里除白名单外最常见的几项
        "basicVehicleStatus.position.latitude":
            .init(title: "纬度", note: "车辆位置的 WGS-84 纬度。只有云端带位置，蓝牙广播没有", resolved: true),
        "basicVehicleStatus.position.longitude":
            .init(title: "经度", note: "车辆位置的 WGS-84 经度。展示前需转 GCJ-02，见坐标转换说明", resolved: true),
        "basicVehicleStatus.position.altitude":
            .init(title: "海拔", note: "定位点的海拔高度（米），车端不一定给", resolved: true),
        "basicVehicleStatus.position.trusted":
            .init(title: "定位可信", note: "车端自评这条位置能不能信。地库、隧道里通常是 false", resolved: true),
        "basicVehicleStatus.position.updateTime":
            .init(title: "定位采集时间", note: "这条坐标在**车端被采集**的时刻，不是收到它的时刻", resolved: true),

        // 电气：这几个直接关系到"明天能不能打着火"
        "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.voltage":
            .init(title: "电瓶电压", note: "熄火静置正常约 12.2–12.8 V，低于 12 V 可能亏电", resolved: true),
        "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.stateOfCharge":
            .init(title: "电瓶电量", note: "蓄电池荷电状态的原始编码，不是百分比，只能横向比较", resolved: true),
        "additionalVehicleStatus.maintenanceStatus.mainBatteryStatus.stateOfHealth":
            .init(title: "电瓶健康度", note: "原始编码，厂端用它判断电瓶寿命，不代表剩余电量", resolved: true),

        // 行驶
        "additionalVehicleStatus.runningStatus.engineCoolantTemperature":
            .init(title: "冷却液温度", note: "原始值按华氏度解读才合理（179 ≈ 82°C）。这条是推断，以实车为准", resolved: true),
        "additionalVehicleStatus.runningStatus.engineRpm":
            .init(title: "发动机转速", note: "曲轴每分钟转数。熄火为 0，怠速通常 700–900", resolved: true),
        "additionalVehicleStatus.runningStatus.instantFuelConsumption":
            .init(title: "瞬时油耗", note: "当前这一脚的油耗（L/100km），波动大，只看趋势", resolved: true),

        // 保养
        "additionalVehicleStatus.maintenanceStatus.distanceToService":
            .init(title: "距下次保养", note: "还剩多少公里需要保养，接近 0 时该预约了", resolved: true),
        "additionalVehicleStatus.maintenanceStatus.serviceRemind":
            .init(title: "保养提醒", note: "厂端置位的保养提示，1 = 该去保养了", resolved: true),

        // 门锁 / 安防
        "additionalVehicleStatus.drivingSafetyStatus.eVPSStatus":
            .init(title: "电子驻车（EPB）状态",
                  note: "EVPS = Electric Vacuum Pump System，电子真空泵。发动机熄火后靠它维持刹车助力，只读", resolved: true),
        "additionalVehicleStatus.drivingSafetyStatus.vehicleAlarm":
            .init(title: "防盗布防", note: "1 = 防盗系统已布防。锁车后应自动置 1", resolved: true),
        "additionalVehicleStatus.drivingSafetyStatus.engineOilPressureWarning":
            .init(title: "机油压力告警", note: "1 = 压力异常。真车出现这个必须立刻停车检查", resolved: true),

        // 空调
        "additionalVehicleStatus.climateStatus.airCleanSts":
            .init(title: "空气净化", note: "1 = 净化功能运行中。它是滤芯在工作，不是空气质量好", resolved: true),
        "additionalVehicleStatus.climateStatus.preClimateActive":
            .init(title: "远程空调", note: "1 = 远程预热/预冷正在运行。只在着车前有意义", resolved: true),

        // 车窗 / 天窗：位置类
        "additionalVehicleStatus.climateStatus.sunroofOpenStatus":
            .init(title: "天窗开关位",
                  note: "这个字段在本车型上**恒为 1**，不能用来判断天窗开合 —— 请看「天窗开度」", resolved: true)
    ]

    private static let groupNames: [String: String] = [
        "basicVehicleStatus": "基础状态",
        "additionalVehicleStatus": "附加状态",
        "configuration": "车辆配置",
        "vehicleStatus": "车辆状态"
    ]

    // MARK: - 组合拆解

    /// 词根规则。
    ///
    /// `role` 决定它在中文名里的位置：修饰词（平均/剩余）→ 位置词 → 对象词 → 属性词。
    /// 中文语序是「平均 + 燃油 + 消耗」，不是英文的「ave + fuel + consumption」。
    private struct Rule {
        let token: String
        let text: String
        let role: Role

        enum Role { case modifier, place, object, attribute }
    }

    /// 不产生中文、也不该被标成"未识别"的填充词。
    ///
    /// 它们只说明"这是车辆的数据"，删掉不影响理解 ——
    /// 但如果留在 `blind` 里，整条都会被标成「未译」，等于白翻了。
    private static let filler: Set<String> = [
        "vehicle", "info", "data", "value", "flag", "num", "number",
        "index", "seq", "item", "list", "detail", "details",
        // `safety` 与 `drivingSafetyStatus` 同名，放在 leaf 里只会拼出
        // 「主驾安全安全带状态」这种重复词 —— 它描述的层级已经在分组名里了。
        "safety", "to", "empty"
    ]

    /// ⚠️ 顺序有意义：长 token 在前，避免 `rear` 先吃掉 `driverRear`。
    private static let rules: [Rule] = [
        // —— 组合词（两段合成一个概念，优先级最高） ——
        .init(token: "enginehood", text: "引擎盖", role: .object),
        .init(token: "enginespeed", text: "发动机转速", role: .object),
        .init(token: "coolanttemp", text: "冷却液温度", role: .object),
        .init(token: "airclean", text: "空气净化", role: .object),
        .init(token: "drivingrange", text: "续航", role: .object),

        // —— 修饰（放在最前） ——
        .init(token: "average", text: "平均", role: .modifier),
        .init(token: "ave", text: "平均", role: .modifier),
        .init(token: "avg", text: "平均", role: .modifier),
        .init(token: "remaining", text: "剩余", role: .modifier),
        .init(token: "total", text: "总", role: .modifier),
        .init(token: "max", text: "最大", role: .modifier),
        .init(token: "min", text: "最小", role: .modifier),
        .init(token: "instant", text: "瞬时", role: .modifier),

        // —— 位置 ——
        .init(token: "driverrear", text: "左后", role: .place),
        .init(token: "passengerrear", text: "右后", role: .place),
        .init(token: "fl", text: "左前", role: .place),
        .init(token: "fr", text: "右前", role: .place),
        .init(token: "rl", text: "左后", role: .place),
        .init(token: "rr", text: "右后", role: .place),
        .init(token: "driver", text: "主驾", role: .place),
        .init(token: "passenger", text: "副驾", role: .place),
        .init(token: "front", text: "前", role: .place),
        .init(token: "rear", text: "后", role: .place),
        .init(token: "left", text: "左", role: .place),
        .init(token: "right", text: "右", role: .place),

        // —— 对象 ——
        .init(token: "door", text: "车门", role: .object),
        .init(token: "win", text: "车窗", role: .object),
        .init(token: "window", text: "车窗", role: .object),
        .init(token: "trunk", text: "后备箱", role: .object),
        .init(token: "hood", text: "引擎盖", role: .object),
        .init(token: "sunroof", text: "天窗", role: .object),
        .init(token: "engine", text: "发动机", role: .object),
        .init(token: "motor", text: "电机", role: .object),
        .init(token: "battery", text: "电池", role: .object),
        .init(token: "fuel", text: "燃油", role: .object),
        .init(token: "tyre", text: "轮胎", role: .object),
        .init(token: "tire", text: "轮胎", role: .object),
        .init(token: "brake", text: "制动", role: .object),
        .init(token: "park", text: "驻车", role: .object),
        .init(token: "seat", text: "座椅", role: .object),
        .init(token: "light", text: "车灯", role: .object),
        .init(token: "radar", text: "雷达", role: .object),
        .init(token: "camera", text: "摄像头", role: .object),
        .init(token: "airbag", text: "安全气囊", role: .object),
        .init(token: "belt", text: "安全带", role: .object),
        .init(token: "climate", text: "空调", role: .object),
        .init(token: "air", text: "空气", role: .object),
        .init(token: "charge", text: "充电", role: .object),
        .init(token: "charging", text: "充电", role: .object),
        .init(token: "gear", text: "挡位", role: .object),
        .init(token: "odometer", text: "里程", role: .object),
        .init(token: "maintenance", text: "保养", role: .object),
        .init(token: "service", text: "保养", role: .object),
        .init(token: "alarm", text: "报警", role: .object),
        .init(token: "security", text: "安防", role: .object),
        .init(token: "immobilizer", text: "防盗", role: .object),
        .init(token: "gps", text: "定位", role: .object),
        .init(token: "network", text: "网络", role: .object),
        .init(token: "signal", text: "信号", role: .object),
        .init(token: "speed", text: "车速", role: .object),
        .init(token: "lock", text: "锁", role: .object),
        .init(token: "safety", text: "安全", role: .object),
        .init(token: "consumption", text: "消耗", role: .object),
        .init(token: "model", text: "车型", role: .object),
        .init(token: "series", text: "车系", role: .object),
        .init(token: "color", text: "颜色", role: .object),
        .init(token: "plate", text: "车牌", role: .object),
        .init(token: "smoke", text: "烟雾", role: .object),
        .init(token: "electric", text: "电动", role: .object),

        // —— 属性 ——
        .init(token: "prewarning", text: "预警", role: .attribute),
        .init(token: "warning", text: "告警", role: .attribute),
        .init(token: "warn", text: "告警", role: .attribute),
        .init(token: "status", text: "状态", role: .attribute),
        .init(token: "sts", text: "状态", role: .attribute),
        .init(token: "state", text: "状态", role: .attribute),
        .init(token: "position", text: "位置", role: .attribute),
        .init(token: "pos", text: "开度", role: .attribute),
        .init(token: "level", text: "余量", role: .attribute),
        .init(token: "temperature", text: "温度", role: .attribute),
        .init(token: "temp", text: "温度", role: .attribute),
        .init(token: "pressure", text: "压力", role: .attribute),
        .init(token: "voltage", text: "电压", role: .attribute),
        .init(token: "current", text: "电流", role: .attribute),
        .init(token: "soc", text: "电量", role: .attribute),
        .init(token: "distance", text: "距离", role: .attribute),
        .init(token: "time", text: "时间", role: .attribute),
        .init(token: "date", text: "日期", role: .attribute),
        .init(token: "mode", text: "模式", role: .attribute),
        .init(token: "active", text: "激活", role: .attribute),
        .init(token: "open", text: "开", role: .attribute),
        .init(token: "opened", text: "开", role: .attribute),
        .init(token: "close", text: "关", role: .attribute),
        .init(token: "closed", text: "关", role: .attribute),
        .init(token: "locked", text: "锁", role: .attribute),
        .init(token: "count", text: "次数", role: .attribute),
        .init(token: "type", text: "类型", role: .attribute),
        .init(token: "code", text: "编码", role: .attribute),
        .init(token: "name", text: "名称", role: .attribute),
        .init(token: "id", text: "编号", role: .attribute)
    ]

    /// 词条索引。
    ///
    /// ⚠️ 不能用 `Dictionary(uniqueKeysWithValues:)` —— 它遇到重复 key 会
    /// **运行时直接 crash**，而这个词表是手写的、几百行，改的时候多打一行
    /// `belt` 就整页崩（本轮开发中真的踩到过一次）。
    /// 这里改成"先到先得"，重复项静默忽略；上线前由 `SelfTest` 兜住重复检查。
    private static let ruleIndex: [String: Rule] = {
        var map: [String: Rule] = [:]
        for rule in rules where map[rule.token] == nil {
            map[rule.token] = rule
        }
        return map
    }()

    /// 词表里重复的 token（供 `SelfTest` 兜底）。
    ///
    /// 重复项在运行时会被"先到先得"静默忽略 —— 后写的那条永远不生效，
    /// 而写的人会以为自己改对了。词表是手写的几百行，这种错很容易犯。
    static var duplicateTokens: [String] {
        var seen: Set<String> = []
        var duplicates: [String] = []
        for rule in rules where !seen.insert(rule.token).inserted {
            duplicates.append(rule.token)
        }
        return duplicates
    }

    private static func composed(_ field: StatusField) -> Meaning {
        // 只看最后一段：`maintenanceStatus.tyreStatusDriver` → `tyreStatusDriver`
        let leaf = field.path.split(separator: ".").last.map(String.init) ?? field.path
        let tokens = splitCamel(leaf)

        var modifier: [String] = []
        var place: [String] = []
        var object: [String] = []
        var attribute: [String] = []
        var matched = 0

        // 两段组合优先：`driver` + `rear` 必须合成「左后」，
        // 拆开读会变成「主驾后」，意思完全不同。`pre` + `warning` 同理。
        var i = 0
        var blind: [String] = []          // 完全匹配不上的段，原样保留
        while i < tokens.count {
            let lower = tokens[i].lowercased()

            // 填充词直接跳过，不进 blind —— 否则 `vehicleSpeed` 会因为
            // 那个 `vehicle` 被整条标成「未译」，可它明明就是"车速"。
            if filler.contains(lower) { i += 1; continue }

            if i + 1 < tokens.count,
               let combined = ruleIndex[(tokens[i] + tokens[i + 1]).lowercased()] {
                append(combined, modifier: &modifier, place: &place,
                       object: &object, attribute: &attribute)
                matched += 1
                i += 2
                continue
            }
            if let rule = ruleIndex[lower] {
                append(rule, modifier: &modifier, place: &place,
                       object: &object, attribute: &attribute)
                matched += 1
            } else {
                blind.append(tokens[i])
            }
            i += 1
        }

        // 一段都没命中 → 不给猜的中文名
        guard matched > 0 else {
            // 说明写短：这句话在折叠区里会重复几十遍，长了就是噪音。
            // 关键信息只有一条 —— 这个名字 App 不认识。
            return .init(title: leaf,
                         note: "厂端原始字段，App 未定义中文名",
                         translated: false,
                         resolved: false)
        }

        // 中文语序：修饰 → 位置 → 对象 → 属性
        let title = modifier.joined() + place.joined() + object.joined() + polish(attribute)
        let note = noteFor(attribute: attribute, object: object, blind: blind)

        return .init(title: title,
                     note: note,
                     translated: true,
                     resolved: blind.isEmpty,
                     kind: kindFor(attribute: attribute, object: object))
    }

    /// 值的形态由**属性词**决定 —— 和 `noteFor` 用同一批线索，保证
    /// 「说明里说它是布尔，界面上就真的显示已锁/未锁」。
    private static func kindFor(attribute: [String], object: [String]) -> Meaning.Kind {
        let attr = attribute.joined()

        if attr.contains("告警") || attr.contains("预警") {
            return .flag(on: "告警", off: "正常")
        }
        if attr.contains("锁") {
            return .flag(on: "已锁", off: "未锁")
        }
        if attr.contains("开关状态") || attr == "开" || attr == "关" {
            return .flag(on: "开", off: "关")
        }
        if attr.contains("状态") {
            // 状态位多半是 0/1；如果实际给的是枚举字符串，
            // 转换逻辑会原样返回，不会硬套。
            return .flag(on: "是", off: "否")
        }
        if attr.contains("时间") || attr.contains("日期") {
            return .timestamp
        }
        if attr.contains("开度") || attr.contains("电压") || attr.contains("温度")
            || attr.contains("压力") || attr.contains("余量") || attr.contains("电量")
            || attr.contains("距离") || attr.contains("次数") || attr.contains("激活") {
            return .number
        }
        if attr.isEmpty, object.isEmpty { return .text }
        return .text
    }

    private static func append(_ rule: Rule, modifier: inout [String], place: inout [String],
                               object: inout [String], attribute: inout [String]) {
        switch rule.role {
        case .modifier:  modifier.append(rule.text)
        case .place:     place.append(rule.text)
        case .object:    object.append(rule.text)
        case .attribute: attribute.append(rule.text)
        }
    }

    /// 属性词的中文修饰。
    ///
    /// 两件事：
    /// 1. **「开」/「关」+「状态」合成「开关状态」** —— 否则会出现「左前门开状态」
    ///    这种半英半中的读法。
    /// 2. **相邻去重** —— `safetyBeltStatus` 里两个 `Status` 会拼成
    ///    「安全带状态状态」。
    private static func polish(_ attributes: [String]) -> String {
        var out: [String] = []
        var i = 0
        while i < attributes.count {
            let cur = attributes[i]
            if (cur == "开" || cur == "关"),
               i + 1 < attributes.count, attributes[i + 1] == "状态" {
                out.append("开关状态")
                i += 2
                continue
            }
            if out.last != cur { out.append(cur) }
            i += 1
        }
        return out.joined()
    }

    /// 用途由**属性类别**决定 —— 同一类值的读法是一样的，
    /// 不需要为七十个字段各写一句。
    ///
    /// 唯一要单独处理的是**纯名词字段**（只有对象、没有属性，如 `odometer`）：
    /// 那时「状态位，只读」这种话是错的，得按对象说清它到底是什么。
    private static func noteFor(attribute: [String], object: [String], blind: [String]) -> String {
        let attr = attribute.joined()
        let obj = object.joined()
        let base: String

        if attr.contains("告警") || attr.contains("预警") {
            base = "厂端置位的告警位，1 = 触发。只读，用来提前发现问题"
        } else if attr.contains("开度") {
            base = "开度百分比，0 = 全关，100 = 全开"
        } else if attr.contains("电压") {
            base = "电压（V）"
        } else if attr.contains("温度") {
            base = "温度，单位按厂端定义（多数为摄氏度）"
        } else if attr.contains("压力") {
            base = "压力值，单位按厂端定义"
        } else if attr.contains("余量") {
            base = "剩余量，通常为百分比"
        } else if attr.contains("电量") {
            base = "荷电状态（SOC），原始编码或百分比，视厂端定义"
        } else if attr.contains("距离") {
            base = "距离（km），具体基准看字段名"
        } else if attr.contains("状态") {
            base = "状态位，取值 0/1 或枚举。只读"
        } else if attr.contains("时间") || attr.contains("日期") {
            base = "车端记录的时间戳，不是手机当前时间"
        } else if attr.contains("锁") {
            base = "锁止状态。只读"
        } else if attr.isEmpty || attr == "名称" || attr == "编号" || attr == "类型" {
            // 「只有名词」的字段：给"这是什么"而不是"这是什么状态"
            if obj.contains("里程") {
                base = "累计里程（km），只会增加"
            } else if obj.contains("消耗") {
                base = "燃油消耗读数，单位 L/100km"
            } else if obj.contains("车型") || obj.contains("车系")
                        || obj.contains("颜色") || obj.contains("车牌") {
                base = "车辆静态信息，不随使用变化"
            } else if obj.contains("车速") {
                base = "车速（km/h）"
            } else {
                base = "厂端读数，只读"
            }
        } else {
            base = "厂端原始字段，只读"
        }

        var out = base
        if !obj.isEmpty { out = appended(out, "属于「\(obj)」") }
        // 拆不出来的那几段附在后面 —— 与其藏起来，不如让用户知道
        // "这个名字里有一段 App 不认识"，将来补词条也有线索。
        if !blind.isEmpty {
            out += "（未识别部分：\(blind.joined(separator: " "))）"
        }
        return out
    }

    /// 在说明末尾接一句，自动处理句号 —— 上一句已经以「。」结尾时不再重复。
    static func appended(_ base: String, _ extra: String) -> String {
        guard !base.isEmpty else { return extra }
        return base.hasSuffix("。") ? base + extra : base + "。" + extra
    }

    /// 驼峰 / 下划线 / 空格切词。`tyrePreWarningDriverRear`
    /// → `["tyre", "Pre", "Warning", "Driver", "Rear"]`
    private static func splitCamel(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { out.append(current); current = "" }
        }

        for ch in raw {
            if ch == "_" || ch == "-" || ch == " " || ch == "." {
                flush()
                continue
            }
            if ch.isUppercase {
                // 连续大写（如 `EVPS`）不拆：它们是缩写，拆开反而看不懂
                let lastIsUpper = current.last?.isUppercase ?? false
                if !current.isEmpty && !lastIsUpper { flush() }
            }
            current.append(ch)
        }
        flush()
        return out
    }
}
