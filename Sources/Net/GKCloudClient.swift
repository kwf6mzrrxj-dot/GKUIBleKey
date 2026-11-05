import Foundation

/// 云端通道的凭据。
///
/// 存哪：手机号 / VIN / userId / clientId 这些**非机密**放 UserDefaults，
/// 密码 MD5 和 token 放 Keychain。密码只存 MD5（服务端就收这个），等于密文。
struct GKCloudCredentials: Codable, Sendable {
    var phone: String = ""
    var passMD5: String = ""
    var vin: String = ""
    var userId: String = ""
    var clientId: String = ""

    /// 是否完整到**能自己登录**（手机端用这个判断配置是否做好）
    var isComplete: Bool {
        !phone.isEmpty && !passMD5.isEmpty && !vin.isEmpty
    }

    /// 是否「足以发出一次带鉴权的请求」。
    ///
    /// ## 为什么要和 `isComplete` 分开（2026-11-04 第二轮审查 S3）
    ///
    /// 手表端拿不到密码 MD5 —— 那是可离线撞库的资产，同步过去等于把它复制到
    /// 一块「抬腕即解锁」的设备上。手表靠手机同步来的 token 工作。
    ///
    /// 但 `isComplete` 要求密码非空，于是手表会永远认为"未配置"，
    /// 连查状态都被拦。所以拆成两个判据：
    ///
    /// - `isComplete`：能自己登录（手机）
    /// - `canMakeAuthedRequests`：有车 + 有身份，token 有效就能干活（手表）
    ///
    /// token 彻底失效时手表做不了主（没有密码可重登），
    /// 只能提示用户回手机重新登录 —— 这是有意的设计，不是缺陷。
    var canMakeAuthedRequests: Bool {
        !vin.isEmpty && !userId.isEmpty
    }
}

enum GKCloudError: LocalizedError {
    case notConfigured
    case unsupportedOnNetwork(String)
    case http(Int)
    case business(code: String, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "网络通道未配置（需要手机号、密码和车架号）"
        case .unsupportedOnNetwork(let what):
            return "\(what)暂不支持云端指令"
        case .http(let code):
            return "云端返回 HTTP \(code)"
        case .business(let code, let message):
            return "云端错误 \(code)：\(message)"
        case .badResponse(let detail):
            return "云端响应异常：\(detail)"
        }
    }
}

/// GKUI 云端 API 客户端。
///
/// ## 为什么是 actor
/// token 刷新、请求排队都要串行。并发调两个车控时如果各自去刷 token，
/// 后一个会把前一个刚拿到的 token 顶掉，然后两边都失败。
actor GKCloudClient {

    static let shared = GKCloudClient()

    private let userHost = "user-api.xchanger.cn"
    private let deviceHost = "device-api.xchanger.cn"

    private var token: String?
    private var refreshToken: String?
    private var tokenExpiry: Date = .distantPast
    private var credentials = GKCloudCredentials()
    /// 设备指纹：一台设备固定一个，不能每次请求都变（会触发风控）
    private let deviceId: String
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "gzip"]
        session = URLSession(configuration: cfg)
        deviceId = GKCloudStore.deviceId()
        credentials = GKCloudStore.load()
        // ★ 2026-11-04：token 现在会持久化。以前只活在内存里 ——
        //   每次冷启动都要重新登录一次（多一次往返，也更容易触发风控）。
        if let saved = GKCloudStore.loadToken() {
            token = saved.access
            refreshToken = saved.refresh
            tokenExpiry = saved.expiry
        }
    }

    // MARK: - 配置

    var isConfigured: Bool { credentials.isComplete }

    func updateCredentials(_ new: GKCloudCredentials) {
        credentials = new
        GKCloudStore.save(new)
        token = nil
        refreshToken = nil
        tokenExpiry = .distantPast
    }

    func snapshotOfCredentials() -> GKCloudCredentials { credentials }

    // MARK: - 请求构造

    private func makeRequest(
        host: String,
        method: String,
        path: String,
        queryItems: [(String, String)],
        body: String?,
        needAuth: Bool
    ) throws -> URLRequest {
        let query = GKCloudSignature.queryString(queryItems)
        let date = GKCloudSignature.httpDate()
        let nonce = GKCloudSignature.nonce()
        let payload = body ?? ""

        let signature = GKCloudSignature.sign(
            nonce: nonce, query: query, body: payload,
            date: date, method: method, path: path)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = host
        comps.path = path
        comps.percentEncodedQuery = query.isEmpty ? nil : query

        // 之前是 `comps.url!`：VIN 或 userId 一旦含非法字符，这里直接崩。
        guard let url = comps.url else {
            throw GKCloudError.badResponse("URL 拼装失败：host=\(host) path=\(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method

        // 与 App 抓包一致的完整头。签名只覆盖上面 9 段，这些额外头不参与，
        // 但缺了可能触发风控，所以照实带上。
        req.setValue(date, forHTTPHeaderField: "date")
        req.setValue(GKCloudSignature.accept, forHTTPHeaderField: "accept")
        req.setValue(GKCloudSignature.signatureVersion, forHTTPHeaderField: "x-api-signature-version")
        req.setValue(nonce, forHTTPHeaderField: "x-api-signature-nonce")
        req.setValue(GKCloudSignature.appID, forHTTPHeaderField: "x-app-id")
        req.setValue(signature, forHTTPHeaderField: "x-signature")
        req.setValue("production", forHTTPHeaderField: "x-env-type")
        req.setValue("GEELY", forHTTPHeaderField: "x-operator-code")
        req.setValue("NON-CMA", forHTTPHeaderField: "platform")
        req.setValue("mobile", forHTTPHeaderField: "x-device-type")
        req.setValue("iPhone", forHTTPHeaderField: "x-device-model")
        req.setValue("Apple", forHTTPHeaderField: "x-device-brand")
        req.setValue("Apple", forHTTPHeaderField: "x-device-manufacture")
        req.setValue(deviceId, forHTTPHeaderField: "x-device-identifier")
        req.setValue("iOS", forHTTPHeaderField: "x-agent-type")
        req.setValue("zh-Hans-CN;q=1", forHTTPHeaderField: "accept-language")

        // 不能用 UIDevice.current：iOS 17+ 的 SDK 把它标了 @MainActor，
        // 在 actor 里同步访问会编译不过。ProcessInfo 没有隔离。
        let os = ProcessInfo.processInfo.operatingSystemVersionString
            .replacingOccurrences(of: "Version ", with: "")
            .components(separatedBy: " ").first ?? "16.0"
        req.setValue(os, forHTTPHeaderField: "x-agent-version")
        req.setValue("XiaoKa/1.5.11 (iPhone; iOS \(os); Scale/3.00)",
                     forHTTPHeaderField: "user-agent")

        if !credentials.clientId.isEmpty {
            req.setValue(credentials.clientId, forHTTPHeaderField: "x-client-id")
        }
        if needAuth, let t = token {
            req.setValue(t, forHTTPHeaderField: "authorization")
        }
        if !payload.isEmpty {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = Data(payload.utf8)
        }
        return req
    }

    @discardableResult
    private func perform(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GKCloudError.badResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GKCloudError.http(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GKCloudError.badResponse(String(decoding: data.prefix(120), as: UTF8.self))
        }
        if let code = json["code"], String(describing: code) != "1000" {
            throw GKCloudError.business(
                code: String(describing: code),
                message: (json["message"] as? String) ?? "")
        }
        return json
    }

    /// 带「token 失效自动重登」的请求。
    ///
    /// `ensureToken()` 只看本地记的过期时间，服务端提前吊销（换设备、异地登录、
    /// 后台风控）时本地完全不知情 —— 请求会直接 401，用户看到
    /// 「云端返回 HTTP 401」，然后必须手动进设置页重配一次。
    /// 这里捕获 401 → 丢 token → 重登一次 → 重试。
    private func sendAuthed(
        _ build: () throws -> URLRequest
    ) async throws -> [String: Any] {
        do {
            return try await perform(try build())
        } catch let GKCloudError.http(code) where code == 401 {
            invalidateToken()
            try await ensureToken()
            return try await perform(try build())
        }
    }

    // MARK: - 登录 / token

    func ensureToken() async throws {
        if let t = token, Date() < tokenExpiry, !t.isEmpty { return }

        if let rt = refreshToken, !rt.isEmpty {
            do {
                let json = try await perform(try makeRequest(
                    host: userHost, method: "GET",
                    path: "/auth/account/session/refresh",
                    queryItems: [("refreshToken", rt)],
                    body: nil, needAuth: false))
                if let data = json["data"] as? [String: Any],
                   let access = data["accessToken"] as? String {
                    applyTokenResponse(data, access: access)
                    return
                }
            } catch {
                // 刷新失败就落到重新登录，不在这里抛
            }
        }
        try await login()
    }

    private func applyTokenResponse(_ data: [String: Any], access: String) {
        token = access
        if let r = data["refreshToken"] as? String { refreshToken = r }

        // userId 显式取字符串或整数（2026-11-04 第二轮审查 M7）。
        // 原来是 `String(describing: uid)`：服务端返回 JSON null 时会得到
        // 字面量 "<null>"，写进 credentials 之后，所有请求都带着这个假 ID ——
        // 而且看起来一切正常。取不到就保持原值，不猜。
        if let uid = data["userId"] as? String, !uid.isEmpty {
            credentials.userId = uid
        } else if let uid = data["userId"] as? Int {
            credentials.userId = String(uid)
        } else if let uid = data["userId"] as? Int64 {
            credentials.userId = String(uid)
        }

        if let cid = data["clientId"] as? String { credentials.clientId = cid }

        let expiresIn = (data["expiresIn"] as? Double) ?? 2592000
        // 提前续期，但别把自己推进过去（2026-11-04 第二轮审查 M8）。
        //
        // 原来固定减 3600 秒：`expiresIn < 3600` 时 tokenExpiry 直接落在过去，
        // 于是每次请求都重新登录 —— 表现为"偶发很慢 / 反复登录"，很难归因。
        // 现在取 min(1 小时, 10%)，且至少留 60 秒有效期。
        let lead = min(3600, max(60, expiresIn * 0.1))
        tokenExpiry = Date().addingTimeInterval(max(0, expiresIn - lead))

        GKCloudStore.save(credentials)
        GKCloudStore.saveToken(access: access, refresh: refreshToken, expiry: tokenExpiry)
    }

    func login() async throws {
        guard credentials.isComplete else { throw GKCloudError.notConfigured }

        // 用序列化器构造而不是字符串插值（2026-11-04 第二轮审查 M6）：
        // 原来的 `{"username":"\(phone)",...}` 一旦输入里出现 `"` 或 `\`，
        // 拼出来的就是非法 JSON —— 现在输入恰好是数字，但这是"靠输入恰好安全"。
        let bodyData = try JSONSerialization.data(
            withJSONObject: ["username": credentials.phone,
                             "password": credentials.passMD5],
            options: [.sortedKeys])
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw GKCloudError.badResponse("登录体编码失败")
        }

        let json = try await perform(try makeRequest(
            host: userHost, method: "POST",
            path: "/auth/account/session/secure",
            queryItems: [], body: body, needAuth: false))
        guard let data = json["data"] as? [String: Any],
              let access = data["accessToken"] as? String else {
            throw GKCloudError.badResponse("登录响应缺少 accessToken")
        }
        applyTokenResponse(data, access: access)
    }

    /// 丢弃本地 token，下次调用重新登录。凭据错误时用户改完密码要调它。
    func invalidateToken() {
        token = nil
        refreshToken = nil
        tokenExpiry = .distantPast
        GKCloudStore.clearToken()
    }

    /// 当前 token 的可序列化快照 —— 手机把它同步给手表用。
    struct TokenSnapshot: Sendable {
        var access: String?
        var refresh: String?
        var expiry: Date?
    }

    func tokenSnapshot() -> TokenSnapshot {
        TokenSnapshot(access: token,
                      refresh: refreshToken,
                      expiry: token == nil ? nil : tokenExpiry)
    }

    /// 从手机同步来的 token 直接装上，省掉手表自己登录一次。
    ///
    /// 手表上没有密码输入界面，账号来源就是手机；token 一起带过来，
    /// 抬腕就能查状态。token 过期后手表会自己用 refreshToken 续，
    /// 续不上再回落用同步来的 MD5 密码重登。
    func importToken(_ snapshot: TokenSnapshot) {
        token = snapshot.access
        refreshToken = snapshot.refresh
        tokenExpiry = snapshot.expiry ?? .distantPast
        if let access = snapshot.access, !access.isEmpty {
            GKCloudStore.saveToken(access: access,
                                   refresh: snapshot.refresh,
                                   expiry: tokenExpiry)
        }
    }

    /// 彻底清除凭据（设置页「清除配置」）。
    ///
    /// 光把内存置空不够 —— 下次冷启动 `GKCloudStore.load()` 又把凭据读回来了。
    func clearAllCredentials() {
        credentials = GKCloudCredentials()
        GKCloudStore.clear()
        lastFields = []
        token = nil
        refreshToken = nil
        tokenExpiry = .distantPast
    }

    // MARK: - 车况

    /// 最近一次拉到的全量字段（状态页逐条展示用）
    private(set) var lastFields: [StatusField] = []

    func fetchStatus() async throws -> VehicleSnapshot {
        // 同 `send`：手表端没有密码，只靠 token
        guard credentials.canMakeAuthedRequests else { throw GKCloudError.notConfigured }
        try await ensureToken()

        let json = try await sendAuthed {
            try self.makeRequest(
                host: self.deviceHost, method: "GET",
                path: "/remote-control/vehicle/status/\(self.credentials.vin)",
                queryItems: [
                    ("latest", "Local"),
                    ("target", "all"),
                    ("userId", self.credentials.userId)
                ],
                body: nil, needAuth: true)
        }

        guard let data = json["data"] as? [String: Any],
              let vs = data["vehicleStatus"] as? [String: Any] else {
            throw GKCloudError.badResponse("缺少 vehicleStatus")
        }

        // 全量摊平 —— 「状态」页要把拿到的每个字段都列出来，
        // 硬编码字段名会随着服务端加字段而漏
        lastFields = StatusFlattener.flatten(vs)
        let additional = vs["additionalVehicleStatus"] as? [String: Any]
        let safety = additional?["drivingSafetyStatus"] as? [String: Any]
        let basic = vs["basicVehicleStatus"] as? [String: Any]

        func on(_ value: Any?) -> Bool? {
            guard let value else { return nil }
            let s = String(describing: value)
            return s == "1" || s == "true"
        }

        // 四门：云端给的是「开=1」，统一转成「关=true」，和蓝牙侧一致。
        //
        // ★ 2026-11-04 修复：这里原来用的是 `compactMap`。
        //   四个字段里只要有一个缺失，数组就从 4 变 3，而下游
        //   （`VehicleTopView` / `CarModelView`）是**按下标**取门的 ——
        //   `doorClosed[2]` 本意「左后」，实际拿到「右后」的值，
        //   于是「左后门开着」会被显示成「右前门开着」。
        //   现在保留 4 个位置：任何一个缺失就整组判为「未知」，不猜。
        let doorKeys = ["doorOpenStatusDriver", "doorOpenStatusPassenger",
                        "doorOpenStatusDriverRear", "doorOpenStatusPassengerRear"]
        let doorRaw: [Bool?] = doorKeys.map { on(safety?[$0]) }
        let doorClosedAll: [Bool]? = doorRaw.allSatisfy { $0 != nil }
            ? doorRaw.map { !($0 ?? false) }
            : nil

        // 车窗：云端有 winPos*（0-100），任一 > 0 即视为开
        let winPositions = [
            (additional?["climateStatus"] as? [String: Any])?["winPosDriver"],
            (additional?["climateStatus"] as? [String: Any])?["winPosPassenger"],
            (additional?["climateStatus"] as? [String: Any])?["winPosDriverRear"],
            (additional?["climateStatus"] as? [String: Any])?["winPosPassengerRear"]
        ].compactMap { v -> Double? in
            guard let v else { return nil }
            return Double(String(describing: v))
        }
        let sunroofOpen = (additional?["climateStatus"] as? [String: Any])
            .flatMap { c -> Bool? in
                guard let p = c["sunroofPos"] else { return nil }
                return (Double(String(describing: p)) ?? 0) > 0
            }

        // 车窗：四个位置都上报了才敢说「全关」。
        // 只有部分字段时报「全关」是在替车撒谎，宁可显示「—」。
        let anyWindowOpen = winPositions.contains { $0 > 0 }
        let windowsKnown = anyWindowOpen || winPositions.count >= 4

        return VehicleSnapshot(
            isLocked: on(safety?["doorLockStatusDriver"]),
            isTrunkClosed: on(safety?["trunkOpenStatus"]).map { !$0 },
            isDoorsClosed: doorClosedAll.map { $0.allSatisfy { $0 } },
            isEngineRunning: (basic?["engineStatus"] as? String).map { $0 == "engine_on" },
            doorClosed: doorClosedAll,
            isWindowsKnown: windowsKnown,
            isWindowsClosed: windowsKnown ? !anyWindowOpen : nil,
            isSunroofOpen: sunroofOpen,
            updatedAt: Date()
        )
    }

    /// 云端「远程空调」是否开着（`climateStatus.preClimateActive`）。
    ///
    /// 手表端没有 `AppModel.cloudFields`，只能从客户端自己缓存的 `lastFields` 里取。
    func airConditionerOn() -> Bool? {
        guard let field = lastFields.first(where: {
            $0.id == "additionalVehicleStatus.climateStatus.preClimateActive"
        }) else { return nil }
        switch field.value {
        case "1", "是", "true":  return true
        case "0", "否", "false": return false
        default: return nil
        }
    }

    // MARK: - 车控

    func send(_ command: VehicleCommand) async throws {
        // 用 `canMakeAuthedRequests` 而不是 `isComplete`：手表端没有密码，
        // 只有手机同步来的 token（见 `GKCloudCredentials.canMakeAuthedRequests`）。
        guard credentials.canMakeAuthedRequests else { throw GKCloudError.notConfigured }
        guard command.isSupportedOnNetwork else {
            throw GKCloudError.unsupportedOnNetwork(command.label)
        }
        try await ensureToken()

        // ★ body 在闭包内构造，每次尝试重新取时间戳（2026-11-04 第二轮审查 M11）。
        //
        // 原来只在外面算一次 `timestamp` 并拼成 `body`。而 `sendAuthed` 遇到 401
        // 会重试一次 —— 那次重试的签名用新的 date/nonce，body 里的 timestamp
        // 却还是上一次的。如果服务端校验两者的偏差窗口，重试必然被拒，
        // 表现成"第一次过期、第二次还是失败"，看起来像是 token 没救回来。
        var attempt = 0
        do {
            let json = try await sendAuthed {
                attempt += 1
                let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
                let plan = try self.plan(for: command, timestamp: timestamp)
                let body = try self.encodeBody(plan: plan, timestamp: timestamp)

                // 指令留痕：真机测试时直接看日志就能核对发出去的内容，
                // 不需要另外架代理抓包。字段与抓包 JSON 同名，方便逐字比对。
                // 不打印 token / 签名 —— 那是可直接复用的凭据。
                FileLogger.shared.info(
                    "云端指令(第\(attempt)次) → serviceId=\(plan.serviceId) "
                    + "command=\(plan.command) params=\(plan.parameters) "
                    + "scheduled=\(plan.scheduledTime ?? "null")",
                    module: "CLOUD")

                return try self.makeRequest(
                    host: self.deviceHost, method: "PUT",
                    path: "/remote-control/vehicle/telematics/\(self.credentials.vin)",
                    queryItems: [], body: body, needAuth: true)
            }
            // 服务端回执：业务码 + 消息（成功时 data 里通常带 taskId）
            let code = json["code"].map { String(describing: $0) } ?? "-"
            let msg = (json["message"] as? String) ?? ""
            FileLogger.shared.info("云端回执 ← code=\(code) message=\(msg)",
                                   module: "CLOUD")
        } catch {
            FileLogger.shared.error("云端指令失败 ← \(error.localizedDescription)",
                                    module: "CLOUD")
            throw error
        }
    }

    /// 把命令计划拼成请求体。
    ///
    /// 单独一个方法，是为了让 `sendAuthed` 的**每次尝试**都能用最新的时间戳
    /// 重新拼一次（见 `send()` 里的说明）。
    private func encodeBody(plan: CommandPlan, timestamp: String) throws -> String {
        var dict: [String: Any] = [
            "latest": false,
            "userId": credentials.userId,
            "command": plan.command,
            "serviceParameters": plan.parameters,
            "serviceId": plan.serviceId,
            "timestamp": timestamp,
            "pin": NSNull(),
            "creator": "tc"
        ]
        if plan.includeScheduling {
            let scheduling: [String: Any] = [
                "scheduledTime": plan.scheduledTime ?? NSNull(),
                "interval": 0,
                "occurs": 0,
                "recurrentOperation": 1,
                "duration": 60
            ]
            dict["operationScheduling"] = scheduling
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let body = String(data: data, encoding: .utf8) else {
            throw GKCloudError.badResponse("控制体序列化失败")
        }
        return body
    }

    // MARK: - 远程空调 / 引擎启停（只能走云端）

    /// 一条「原样照抄」的云端命令。
    ///
    /// 字段命名直接对齐抓包里的 JSON，不做任何重命名 —— 填的时候一眼能对上。
    private struct RawPlan {
        var serviceId: String
        var command: String
        var parameters: [[String: String]]
        /// 门锁必须 nil、车窗要带时间，两种约定不同，所以单独留字段。
        /// 值写 `"$NOW"` 表示「本次请求的毫秒时间戳」。
        var scheduledTime: String?
        /// 官方 App 在「引擎熄火」这条里**整段不带** `operationScheduling`，
        /// 其它命令都带。照抄，别自作主张补上。
        var includeScheduling: Bool = true
    }

    /// 远程空调 / 引擎启停的命令表（**已填，2026-11-04 真机抓包**）。
    ///
    /// ## 参数从哪来
    ///
    /// 车控平台的 `serviceId` 是服务端按 VIN 下发的能力名，客户端二进制里搜不到
    /// （Android dex、iOS 解密包、已有逆向文档都没有 RDL / RDU / RCE 这些字面量）。
    /// 所以这份表是一次真实抓包的结果 —— 越狱机 + Frida hook `NSURLSession`，
    /// 在 GKUI 里依次点「启动 → 熄火 → 开空调 22℃ → 关空调」得到四条原始请求。
    ///
    /// ## 已知的 serviceId
    ///
    /// | serviceId | 动作 |
    /// |---|---|
    /// | `RDL` / `RDU` | 闭锁 / 解锁 |
    /// | `RWS` | 车窗（含 `rws=ventilate` 微开） |
    /// | `RHL` | 寻车 |
    /// | `RCE` | 远程空调（参数 `rce` = 温度） |
    /// | `RES` | 启停引擎（参数 `time.window`） |
    ///
    /// ## 改这里的注意事项
    ///
    /// 参数值支持两个占位符：`$NOW`（本次请求的毫秒时间戳）、`$TEMP`（空调温度）。
    /// 新增命令时必须**先抓包**，不要照别的命令猜 —— 「远程启动发动机」这类动作
    /// 猜错的代价不是报错，而是命中别的服务。
    ///
    private enum RemoteCommandTable {
        // ── 以下四条取自 2026-11-04 真机抓包（越狱机 + Frida hook NSURLSession）──
        //
        // 抓包时的原始请求体（空调那条）：
        //   {"latest":false,"userId":"...","command":"start",
        //    "serviceParameters":[{"key":"rce","value":"22"}],
        //    "operationScheduling":{"scheduledTime":"1793796078203",...},
        //    "serviceId":"RCE","timestamp":"1793796078203","pin":null,"creator":"tc"}

        /// 远程空调 · 开（`rce` = 目标温度）
        static let acOn = RawPlan(
            serviceId: "RCE",
            command: "start",
            parameters: [["key": "rce", "value": "$TEMP"]],
            scheduledTime: "$NOW")

        /// 远程空调 · 关。官方同样带 `rce`（当前温度）与 `scheduledTime`
        static let acOff = RawPlan(
            serviceId: "RCE",
            command: "stop",
            parameters: [["key": "rce", "value": "$TEMP"]],
            scheduledTime: "$NOW")

        /// 远程启动引擎。
        /// ⚠️ `time.window` = "2"（分钟）；`scheduledTime` 为 null —— 和门锁同一套约定
        static let engineStart = RawPlan(
            serviceId: "RES",
            command: "start",
            parameters: [["key": "time.start", "value": "$NOW"],
                         ["key": "time.window", "value": "2"]],
            scheduledTime: nil)

        /// 远程熄火。
        /// ⚠️ 两处与启动不同：`time.window` = "0"，且**整段不带** `operationScheduling`
        static let engineStop = RawPlan(
            serviceId: "RES",
            command: "stop",
            parameters: [["key": "time.start", "value": "$NOW"],
                         ["key": "time.window", "value": "0"]],
            scheduledTime: nil,
            includeScheduling: false)

    }

    private struct CommandPlan {
        var serviceId: String
        var command: String
        var parameters: [[String: String]]
        /// 只有车窗/寻车带时间；门锁必须为 null（见下面注释）
        var scheduledTime: String?
        /// 是否输出 `operationScheduling` 整段（熄火那条不输出）
        var includeScheduling: Bool = true
    }

    /// ⚠️ **不做定时**（2026-11-05 实测修正）。
    ///
    /// 曾经把目标时间塞进 `scheduledTime`，真机结果仍是立即执行。
    /// 抓包取自官方 App"立即执行"的场景，`scheduledTime == 请求时间`，
    /// 无法证明它是计划时刻；顶层 `timestamp` 反而更像生效时间。
    /// 盲猜字段语义的后果是"车在你没预期的时间动作"，所以退回全部立即执行，
    /// 定时改由本机到点下发（见 `ScheduledCommand`）。
    private func plan(for command: VehicleCommand, timestamp: String) throws -> CommandPlan {
        switch command {
        case .lock:
            // ⚠️ 门锁的时间字段位置和车窗**故意不同**：
            // 时间放 serviceParameters 里的 time.start，而 scheduledTime 必须为 null。
            // 搞反了服务端直接拒。
            return CommandPlan(
                serviceId: "RDL", command: "start",
                parameters: [["key": "time.start", "value": timestamp],
                             ["key": "time.window", "value": "2"]],
                scheduledTime: nil)
        case .unlock:
            return CommandPlan(
                serviceId: "RDU", command: "start",
                parameters: [["key": "time.start", "value": timestamp],
                             ["key": "time.window", "value": "2"]],
                scheduledTime: nil)
        case .windowUp:
            // 关窗 = rws=all + stop；开窗 = rws=all + start。同一个参数靠 command 区分。
            return CommandPlan(
                serviceId: "RWS", command: "stop",
                parameters: [["key": "rws", "value": "all"]],
                scheduledTime: timestamp)
        case .windowDown:
            return CommandPlan(
                serviceId: "RWS", command: "start",
                parameters: [["key": "rws", "value": "all"]],
                scheduledTime: timestamp)
        case .windowVent:
            // 微开 = rws=ventilate。蓝牙协议里没有这个档位，只有云端给。
            return CommandPlan(
                serviceId: "RWS", command: "start",
                parameters: [["key": "rws", "value": "ventilate"]],
                scheduledTime: timestamp)
        case .find:
            return CommandPlan(
                serviceId: "RHL", command: "start",
                parameters: [["key": "rhl", "value": "horn-light-flash"]],
                scheduledTime: timestamp)
        case .airConditioner(let on, let temperature):
            return Self.fromTable(
                on ? RemoteCommandTable.acOn : RemoteCommandTable.acOff,
                label: command.label,
                vars: ["$NOW": timestamp, "$TEMP": String(temperature)])
        case .engine(let on):
            return Self.fromTable(
                on ? RemoteCommandTable.engineStart : RemoteCommandTable.engineStop,
                label: command.label,
                vars: ["$NOW": timestamp])
        }
    }

    /// 把表里的原始条目转成可发送的命令计划。
    /// `vars` 用来替换占位符（`$NOW` 时间戳、`$TEMP` 空调温度）。
    ///
    /// 参数不再可选：四条命令都已用真机抓包确认过（2026-11-04），
    /// 不存在"填了一半"的状态。原来的 `RawPlan?` + `guard let` 是给
    /// "还没抓到参数"那段时间准备的，现在保留只会让读者以为还有未配置的分支。
    private static func fromTable(_ raw: RawPlan, label: String,
                                  vars: [String: String]) -> CommandPlan {
        let params = raw.parameters.map { pair -> [String: String] in
            pair.mapValues { vars[$0] ?? $0 }
        }
        let scheduled = raw.scheduledTime.map { vars[$0] ?? $0 }
        return CommandPlan(serviceId: raw.serviceId,
                           command: raw.command,
                           parameters: params,
                           scheduledTime: scheduled,
                           includeScheduling: raw.includeScheduling)
    }
}

/// 轻量持久化。
///
/// ## 分工（2026-11-04 修正）
///
/// | 内容 | 存哪 | 为什么 |
/// |---|---|---|
/// | 手机号 / VIN / userId / clientId / deviceId | UserDefaults | 非机密，丢了只是要重配 |
/// | 密码 MD5 | **Keychain** | 可离线撞库 |
/// | access / refresh token | **Keychain** | 直接就是车控通行证 |
///
/// 之前注释写着"token 放 Keychain"，实际全在 UserDefaults —— 会随 iCloud
/// 备份外流。现在按注释说的做，并带一次**旧数据迁移**：读到 UserDefaults 里
/// 还带着 `passMD5` 的老记录时，写进 Keychain 再把明文抹掉。
enum GKCloudStore {
    private static let credsKey = "gkcloud.credentials"
    private static let deviceKey = "gkcloud.deviceId"

    /// access + refresh + 过期时刻，打包成一段 JSON 存 Keychain
    struct TokenBundle: Codable, Sendable {
        var access: String
        var refresh: String?
        var expiry: Date
    }

    static func load() -> GKCloudCredentials {
        var c = GKCloudCredentials()
        if let data = UserDefaults.standard.data(forKey: credsKey),
           let decoded = try? JSONDecoder().decode(GKCloudCredentials.self, from: data) {
            c = decoded
        }

        // 旧版本：密码 MD5 混在这份 JSON 里 → 迁到 Keychain 并抹掉
        if !c.passMD5.isEmpty {
            GKCloudKeychain.set(c.passMD5, for: .passMD5)
            c.passMD5 = ""
            save(c)
        }
        if let md5 = GKCloudKeychain.string(.passMD5) {
            c.passMD5 = md5
        }
        return c
    }

    static func save(_ c: GKCloudCredentials) {
        if !c.passMD5.isEmpty {
            GKCloudKeychain.set(c.passMD5, for: .passMD5)
        }
        // 写 UserDefaults 的那份永远是「不含机密」的
        var plain = c
        plain.passMD5 = ""
        if let data = try? JSONEncoder().encode(plain) {
            UserDefaults.standard.set(data, forKey: credsKey)
        }
    }

    /// 全清（含 Keychain）
    static func clear() {
        UserDefaults.standard.removeObject(forKey: credsKey)
        GKCloudKeychain.delete(.passMD5)
        GKCloudKeychain.delete(.token)
    }

    // MARK: - token

    static func saveToken(access: String, refresh: String?, expiry: Date) {
        let bundle = TokenBundle(access: access, refresh: refresh, expiry: expiry)
        guard let data = try? JSONEncoder().encode(bundle),
              let text = String(data: data, encoding: .utf8) else { return }
        GKCloudKeychain.set(text, for: .token)
    }

    static func loadToken() -> TokenBundle? {
        guard let text = GKCloudKeychain.string(.token),
              let data = text.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(TokenBundle.self, from: data)
        else { return nil }
        return bundle
    }

    static func clearToken() {
        GKCloudKeychain.delete(.token)
    }

    /// 设备指纹：生成一次就固定，别每次都换 —— 变了会被服务端当新设备
    static func deviceId() -> String {
        if let v = UserDefaults.standard.string(forKey: deviceKey) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: deviceKey)
        return v
    }
}
