import AppIntents
import Foundation

// MARK: - 车辆动作

/// 可在 Siri / 快捷指令 / 操作按钮里选择的车辆动作。
///
/// 每个 case 直接对应一个蓝牙命令码（见 `IBCommandType`），
/// 不额外引入一套「语义层」——命令码本身就是原 App 的语义。
enum VehicleAction: String, AppEnum {
    case unlock
    case lock
    case trunk
    case find

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "车辆动作")
    }

    static var caseDisplayRepresentations: [VehicleAction: DisplayRepresentation] {
        [
            .unlock: DisplayRepresentation(title: "解锁", subtitle: "控制码 0x02"),
            .lock: DisplayRepresentation(title: "闭锁", subtitle: "控制码 0x01"),
            .trunk: DisplayRepresentation(title: "开/关后备箱", subtitle: "控制码 0x03，车端按当前状态切换"),
            .find: DisplayRepresentation(title: "寻车", subtitle: "控制码 0x06，鸣笛闪灯"),
        ]
    }

    /// 对应的蓝牙控制码
    var command: IBCommandType {
        switch self {
        case .unlock: return .unlock
        case .lock:   return .lock
        case .trunk:  return .openCloseTrunk
        case .find:   return .panic
        }
    }

    /// 成功时对用户说的话
    var doneText: String {
        switch self {
        case .unlock: return "已解锁"
        case .lock:   return "已闭锁"
        // 车端是 toggle，无法从回执判断实际是开还是关，所以不编造方向
        case .trunk:  return "后备箱指令已执行"
        case .find:   return "已开始寻车"
        }
    }
}

// MARK: - 控车 Intent

/// 控车意图 —— Siri、快捷指令、操作按钮共用。
///
/// `supportedModes = .background`：**不打开 App**，在后台完成
/// 「扫描 → 连接 → 订阅 → 鉴权 `01/02/03` → 执行 → 等 `04`」。
/// 这依赖 Info.plist 里已有的 `UIBackgroundModes: bluetooth-central`。
struct VehicleControlIntent: AppIntent {
    static var title: LocalizedStringResource { "控制车辆" }

    static var description: IntentDescription {
        IntentDescription(
            "解锁、闭锁、开/关后备箱、寻车。需要手机在车辆附近（BLE 直连，不走网络）。",
            categoryName: "车控"
        )
    }

    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "动作")
    var action: VehicleAction

    init() {}

    init(action: VehicleAction) {
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await AppModel.shared.runIntentCommand(action.command)
        if ok {
            return .result(dialog: IntentDialog(stringLiteral: action.doneText))
        }
        return .result(dialog: IntentDialog(
            stringLiteral: "操作失败。请确认手机蓝牙已开启、且在车辆附近。"))
    }
}

// MARK: - 无参动作 Intent（快捷指令 / 控制中心首选）

/// 每个动作一个**无参数**的独立 Intent。
///
/// ## 为什么不能只留带 `action` 参数的那个
///
/// 控制中心里能加的是「快捷指令」（系统自带的那个控件），
/// 而快捷指令 App 的动作列表是**按 Intent 类型**列的：
/// 带参数的 Intent 只会显示一条「控制车辆」，用户每建一个快捷指令
/// 都要再进二级菜单配一次参数。
///
/// 拆成无参条目后，「解锁车辆」本身就是一条独立动作 ——
/// 建快捷指令只要两步（搜到 → 保存），加到控制中心也就一次到位。
///
/// 这四个同时是 Siri 短语的落点：比让系统在带参 Intent 里追问「哪个动作」更顺。

struct UnlockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { "解锁车辆" }
    static var description: IntentDescription {
        IntentDescription("发送解锁指令（控制码 0x02）。", categoryName: "车控")
    }
    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await AppModel.shared.runIntentCommand(.unlock)
        return .result(dialog: IntentDialog(stringLiteral: ok
            ? VehicleAction.unlock.doneText
            : "操作失败。请确认手机蓝牙已开启、且在车辆附近。"))
    }
}

struct LockVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { "闭锁车辆" }
    static var description: IntentDescription {
        IntentDescription("发送闭锁指令（控制码 0x01）。", categoryName: "车控")
    }
    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await AppModel.shared.runIntentCommand(.lock)
        return .result(dialog: IntentDialog(stringLiteral: ok
            ? VehicleAction.lock.doneText
            : "操作失败。请确认手机蓝牙已开启、且在车辆附近。"))
    }
}

struct TrunkVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { "开/关后备箱" }
    static var description: IntentDescription {
        IntentDescription(
            "发送后备箱指令（控制码 0x03）。车端按当前状态切换开或关，同一条命令是 toggle。",
            categoryName: "车控"
        )
    }
    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await AppModel.shared.runIntentCommand(.openCloseTrunk)
        return .result(dialog: IntentDialog(stringLiteral: ok
            ? VehicleAction.trunk.doneText
            : "操作失败。请确认手机蓝牙已开启、且在车辆附近。"))
    }
}

struct FindVehicleIntent: AppIntent {
    static var title: LocalizedStringResource { "寻车" }
    static var description: IntentDescription {
        IntentDescription("鸣笛闪灯（控制码 0x06）。", categoryName: "车控")
    }
    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ok = await AppModel.shared.runIntentCommand(.panic)
        return .result(dialog: IntentDialog(stringLiteral: ok
            ? VehicleAction.find.doneText
            : "操作失败。请确认手机蓝牙已开启、且在车辆附近。"))
    }
}

// MARK: - 状态查询 Intent

/// 查车辆状态 —— **不连车**，只读最近一次广播解密结果。
///
/// 车机广播间隔实测 10 秒到 17 分钟，所以返回值必须带「多久之前」，
/// 否则用户会把几分钟前的「已锁」当成现在的状态。
struct VehicleStatusIntent: AppIntent {
    static var title: LocalizedStringResource { "查询车辆状态" }

    static var description: IntentDescription {
        IntentDescription("读取最近一次车机广播解出的锁车/车门/电源状态。不连接车辆，速度很快。",
                          categoryName: "车控")
    }

    /// iOS 26 起 `openAppWhenRun` 已废弃，改用 `supportedModes`。
    ///
    /// **`.background` = 绝对不切到 App**：系统在后台启动 App 进程执行
    /// `perform()`，UI 不出现（蓝牙操作必须在 App 进程里跑，
    /// 这里只是「启动进程」而不是「打开界面」）。
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let status = AppModel.shared.measured.status else {
            return .result(dialog: IntentDialog(
                stringLiteral: "还没收到过车辆状态。请打开 App 并靠近车辆。"))
        }

        var text = status.summary
        if let at = AppModel.shared.measured.statusUpdatedAt {
            let seconds = Int(Date().timeIntervalSince(at))
            let age: String
            if seconds < 60 {
                age = "\(seconds) 秒前"
            } else if seconds < 3600 {
                age = "\(seconds / 60) 分钟前"
            } else {
                age = "\(seconds / 3600) 小时前"
            }
            text += "（\(age)收到）"
            if seconds > 120 {
                text += "，可能已不是当前状态"
            }
        }
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Siri 短语

/// 注册「免配置」的 Siri 短语。
///
/// 不注册的话用户必须去「快捷指令」App 里手动建一个快捷指令，
/// 体验差很多。注册后直接说「嘿 Siri，解锁车」就能用。
///
/// ⚠️ 每个短语**必须**包含 `\(.applicationName)`，这是系统的硬性要求，
/// 否则整组短语会被静默丢弃。
struct GKUIBleKeyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // 绑到**无参** Intent 上：Siri 命中后直接执行，
        // 不会先在「控制车辆」里追问「哪个动作」。
        AppShortcut(
            intent: UnlockVehicleIntent(),
            phrases: [
                "用\(.applicationName)解锁车",
                "\(.applicationName)解锁",
                "\(.applicationName)帮我解锁",
            ],
            shortTitle: "解锁",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: LockVehicleIntent(),
            phrases: [
                "用\(.applicationName)锁车",
                "\(.applicationName)锁车",
                "\(.applicationName)帮我锁车",
            ],
            shortTitle: "闭锁",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: TrunkVehicleIntent(),
            phrases: [
                "用\(.applicationName)打开后备箱",
                "\(.applicationName)后备箱",
            ],
            shortTitle: "开后备箱",
            systemImageName: "car.side.rear.open"
        )
        AppShortcut(
            intent: FindVehicleIntent(),
            phrases: [
                "用\(.applicationName)寻车",
                "\(.applicationName)找车",
            ],
            shortTitle: "寻车",
            systemImageName: "light.beacon.max.fill"
        )
        AppShortcut(
            intent: VehicleStatusIntent(),
            phrases: [
                "用\(.applicationName)查车状态",
                "\(.applicationName)车锁了吗",
            ],
            shortTitle: "车辆状态",
            systemImageName: "car.fill"
        )
    }
}
