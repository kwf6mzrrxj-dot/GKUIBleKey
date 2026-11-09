import SwiftUI
import MapKit
import CoreLocation

/// 车辆位置卡片 —— 放在「状态」页。
///
/// ## 为什么不在车控页
/// 车控页已经有 10 个按钮 + 车图 + 能源读数，再加一张地图会把它挤成一屏半。
/// 位置属于「看」而不是「操作」，和状态页的定位一致。
///
/// ## 数据前提
/// 只有云端车况带位置（蓝牙广播没有），所以只用蓝牙时这张卡不出现。
/// 拿不到坐标时整卡不显示，不留占位。
///
/// ## 2026-11-07：加「我在哪」
/// 之前地图上只有车，用户看到的是一张**没有参照物的图** ——
/// 知道车在"某条路"，但不知道离自己多远、在哪个方向。
/// 现在同时画自己的位置，并在信息行给出直线距离：
/// 「距你 320 米」比「康悦路 328 号」更能回答"我现在要不要走过去"。
struct VehicleLocationCard: View {

    /// 两种尺寸。
    ///
    /// - `.full`：状态页用 —— 大缩略图 + 信息行，是"我在哪 / 车在哪"的详情卡。
    /// - `.compact`：车控页用 —— 横排小图 + 两行字，高度从约 170 压到 76。
    ///
    /// 为什么车控页不直接复用完整卡：车控页已经有车图（178）、能源带、10 个按钮，
    /// 完整卡会把「启动引擎」挤到第二屏 —— 而它是这一页最重的动作。
    /// 紧凑版仍然能点开全屏导航，功能一点没少。
    enum Style {
        case full
        case compact
    }

    let coordinate: VehicleCoordinate
    /// 可选：导航时带上车辆名，地图 App 会显示成"导航到 博越 PRO"
    var title: String = "车辆"
    var style: Style = .full

    // 用共享实例而不是 `@StateObject`：车控页和状态页会同时存在，
    // 各建一个就是两个 GPS 会话（见 `UserLocationProvider.shared` 的说明）。
    @ObservedObject private var me = UserLocationProvider.shared
    @State private var address: String?
    /// 小区 / 楼栋名（高德的 AOI + 楼栋）。比道路名具体，有就优先显示。
    @State private var place: String?
    /// 已经解析过的那份位置的时间戳。
    ///
    /// 用来区分两件事：**同一个点重复进入**（不重复请求，省高德额度）
    /// 和**车换地方了**（必须重新解析，否则会拿新坐标配旧小区名）。
    @State private var resolvedFor: Date?
    @State private var showFullMap = false
    @State private var camera: MapCameraPosition = .automatic

    /// 地图用 GCJ-02。
    ///
    /// 车端给的是 WGS-84，直接丢给 MapKit 会偏 400–500 米 ——
    /// 转换的必要性与依据见 `CoordinateTransform` 的注释。
    /// 手机定位也同样要转，否则两个点会各自偏到不同方向。
    private var mapCoordinate: CLLocationCoordinate2D {
        let c = coordinate.mapCoordinate
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    var body: some View {
        Group {
            switch style {
            case .full:
                VStack(spacing: 0) {
                    mapPreview(height: 118, corner: Glass.controlRadius)
                    infoRow
                }
                .contentCard()
            case .compact:
                compactBody
                    .contentCard(radius: Glass.controlRadius, elevated: false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showFullMap = true }
        .task(id: coordinate.reportedAt) { await resolveAddress() }
        .onAppear { me.start() }
        .onDisappear { me.stop() }
        .onChange(of: me.fix) { _, _ in framePreview() }
        .sheet(isPresented: $showFullMap) {
            VehicleLocationDetail(coordinate: coordinate,
                                  address: address,
                                  title: title,
                                  me: me)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("车辆位置 \(address ?? "未知")，\(distanceText ?? "")，\(ageText)")
        .accessibilityHint("点按查看大地图并导航")
    }

    // MARK: - 地图缩略

    private func mapPreview(height: CGFloat, corner: CGFloat) -> some View {
        Map(position: $camera) {
            // 系统蓝点。没有定位权限时它只是不出现，不会报错。
            UserAnnotation()
            Annotation("", coordinate: mapCoordinate) {
                CarPin(size: height > 90 ? 26 : 20)
            }
        }
        // 缩略图不接受手势：整卡点击要能穿透，否则用户拖地图会把卡片点不起来
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        // ★ 水印处理：**裁掉**，不是压淡（2026-11-07 第二次修）
        //
        // MapKit 强制在左下角画「法律信息」胶囊，关不掉、改不了透明度。
        // 先试过叠渐变遮罩压淡 —— 结果是**越压越显眼**：
        // 水印是白字白描边，压暗背景等于给它加了对比度。
        //
        // 现在改成让地图比容器高 22pt、顶部对齐、裁掉底部 ——
        // 水印整个落到裁剪区外，缩略图只剩路网和车标。
        // 这是布局层面的裁切（和卡片圆角裁掉地图四角是同一件事），
        // 不是"移除署名"：点开全屏地图，署名完整可见。
        .frame(height: height + 22)
        .frame(height: height, alignment: .top)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .onAppear { framePreview() }
    }

    // MARK: - 紧凑版（车控页）

    /// 横排：小地图 + 两行字 + 箭头。
    ///
    /// 信息取舍：完整卡里那些「可能不准」标记、chevron 的说明都还在，
    /// 但**采集时间**必须留 —— 车停稳后坐标不再更新，
    /// 少了这个，"30 米"会被当成现在的位置。
    private var compactBody: some View {
        HStack(spacing: 11) {
            // 100×62：宽一点能看到"车在路网的哪个位置"，而不只是一条街。
            // 高度压在 62 是为了让卡片总高（+20 内边距）不超过 84 ——
            // 再多 10pt，「启动引擎」就会被挤出首屏。
            mapPreview(height: 62, corner: 9)
                .frame(width: 100)

            VStack(alignment: .leading, spacing: 3) {
                Text(place ?? address ?? "正在解析地址…")
                    .font(Glass.Typo.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if let distance = distanceText {
                        Text(distance)
                            .font(Glass.Typo.micro.weight(.semibold))
                            .foregroundStyle(Glass.Tone.bluetooth)
                        Text("·")
                            .font(Glass.Typo.micro)
                            .foregroundStyle(.tertiary)
                    }
                    Text(ageText)
                        .font(Glass.Typo.micro)
                        .foregroundStyle(.secondary)
                    if !coordinate.trusted {
                        Text("可能不准")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Glass.Tone.warning)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Glass.Tone.warning.opacity(0.14), in: Capsule())
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: 2)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    /// 把「车 + 我」一起框进缩略图。
    ///
    /// 只框车的话缩略图回答不了"多远"；只框自己则看不见车。
    /// 两点都在时以中点为心、跨度取两点距离的 1.6 倍 —— 留出的余量
    /// 让两个 pin 都落在画面内侧，不会被边缘切掉一半。
    private func framePreview() {
        let car = mapCoordinate
        guard let fix = me.fix, fix.isUsable else {
            camera = .region(MKCoordinateRegion(
                center: car,
                span: MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)))
            return
        }

        let my = fix.mapCoordinate
        let spanLat = max(abs(car.latitude - my.latitude) * 1.6, 0.004)
        let spanLon = max(abs(car.longitude - my.longitude) * 1.6, 0.004)
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (car.latitude + my.latitude) / 2,
                                           longitude: (car.longitude + my.longitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon))

        if camera.region != nil {
            withAnimation(.easeInOut(duration: 0.35)) { camera = .region(region) }
        } else {
            // 首次：不要动画，否则从 .automatic 飞过来会晃一下
            camera = .region(region)
        }
    }

    // MARK: - 信息行

    private var infoRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "location.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Glass.Tone.bluetooth)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // 小区名比道路名更回答"车停在哪"，有就优先
                    Text(place ?? address ?? "正在解析地址…")
                        .font(Glass.Typo.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if !coordinate.trusted {
                        Text("可能不准")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Glass.Tone.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Glass.Tone.warning.opacity(0.14), in: Capsule())
                    }
                }
                // 有小区名时，完整地址降到第二行 ——
                // 主标题给"哪个小区"，这一行给"哪条路"，两个都需要。
                if place != nil, let address {
                    Text(address)
                        .font(Glass.Typo.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 第三行：距离在前、时间在后。距离是"要不要现在过去"的直接依据，
                // 采集时间是"这个距离可不可信"的限定条件 —— 顺序按这个逻辑排。
                HStack(spacing: 5) {
                    if let distance = distanceText {
                        Text(distance)
                            .font(Glass.Typo.micro.weight(.semibold))
                            .foregroundStyle(Glass.Tone.bluetooth)
                        Text("·").font(Glass.Typo.micro).foregroundStyle(.tertiary)
                    }
                    Text(ageText)
                        .font(Glass.Typo.micro)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Glass.cardPadding)
        .padding(.vertical, 12)
    }

    // MARK: - 距离

    /// 直线距离。
    ///
    /// 用直线而不是步行/驾车距离：算路网距离要发一次路径请求，
    /// 对这个场景（"车在不在附近"）没有必要，而且会让卡片打开时多一次等待。
    /// 文案写「直线」两个字，避免被当成导航里程。
    private var distanceText: String? {
        guard let fix = me.fix, fix.isUsable else { return nil }
        let meters = fix.distance(to: coordinate)
        if meters < 1000 {
            return "直线 \(Int((meters / 10).rounded()) * 10) 米"
        }
        return String(format: "直线 %.1f 公里", meters / 1000)
    }

    // MARK: - 时间

    /// 位置**在车端被采集**的时间，不是"现在"。
    ///
    /// 车停稳后车机休眠，坐标就不再更新 —— 界面上必须写清是多久以前的，
    /// 否则「两小时前的位置」会被当成实时位置，人在错的地方找车。
    private var ageText: String {
        guard coordinate.reportedAt != .distantPast else { return "采集时间未知" }

        let seconds = Date().timeIntervalSince(coordinate.reportedAt)
        if seconds < 0 { return "时间异常" }          // 车机时钟比手机快
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    // MARK: - 反地理编码

    /// 解析地址。**高德优先，MapKit 兜底**。
    ///
    /// 为什么是这个顺序：MapKit 的反查只到道路级，拿不到小区名和楼栋；
    /// 高德有 `AOIName`（小区面）和 `number`（门牌），和原 App 的数据源一致。
    ///
    /// 但高德是网络服务 —— key 失效、额度用尽、信号差都会失败。
    /// 那种情况下必须还能显示"车在哪条路上"，所以 MapKit 这一步不能省。
    private func resolveAddress() async {
        guard coordinate.reportedAt != .distantPast else { return }

        // 同一个点、已经解析过 → 直接复用（卡片重建 / 切页回来都会走到这里）
        if resolvedFor == coordinate.reportedAt, address != nil { return }

        // 车换了地方 → 先清掉旧结果。
        // 不清的话，新坐标会配着旧小区名显示，比"正在解析"更误导。
        if resolvedFor != nil {
            address = nil
            place = nil
        }

        // ① 高德：传已经转好的 GCJ-02（理由见 `AMapGeocoder` 的坐标系说明）
        let gcj = coordinate.mapCoordinate
        if let result = await AMapGeocoder.reverse(gcjLatitude: gcj.latitude,
                                                   gcjLongitude: gcj.longitude) {
            address = result.formatted
            // `title` 在 AOI/POI 都缺失时会等于 formatted，那种情况不算"更具体的地点"
            place = result.title == result.formatted ? nil : result.title
            resolvedFor = coordinate.reportedAt
            return
        }

        // ② 兜底：MapKit 反查（道路级）
        // 传**原始 WGS-84**：逆向地理编码期望的就是它，内部按中国区规则处理
        let location = CLLocation(latitude: coordinate.latitude,
                                  longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        request.preferredLocale = Locale(identifier: "zh_CN")
        guard let items = try? await request.mapItems, let first = items.first else { return }

        if let full = first.addressRepresentations?
            .fullAddress(includingRegion: false, singleLine: true),
           !full.isEmpty {
            address = AddressNormalizer.gaodeStyle(full)
        } else if let name = first.name, !name.isEmpty {
            address = name
        }

        // ⚠️ 这里**故意不设** `resolvedFor`。
        //
        // 设了就等于把"降级结果"登记成"已解析"：之后每次 `.task` 一进来，
        // `resolvedFor == coordinate.reportedAt && address != nil` 直接 return，
        // 高德**再也不会被重试**。
        //
        // 真机表现就是"时好时坏"：某一次打开时网络慢（或高德 4 秒超时），
        // 回退成道路名之后就一直锁死在道路名，直到车换位置或 App 重启。
        // 用户看到的就是"昨天还能显示小区，今天又不行了"。
        //
        // 不设的话：下次卡片重建 / 下拉刷新（reportedAt 变化）会自动再试高德，
        // 而 MapKit 的地址先留着垫底，不会出现空白。
    }
}

// MARK: - 地址写法

/// 把 MapKit 的地址文本规范成**高德地图的写法**。
///
/// MapKit 给的是「中国上海市浦东新区严家港路」，高德是「上海市浦东新区严家港路」。
/// 差的不是两个字，是两套地址体系：
///
/// | | Apple | 高德 |
/// |---|---|---|
/// | 国名 | 带（服务全球） | 不写 |
/// | 直辖市 | 「上海市上海市」 | 只写一次 |
/// | 层级 | 省市 + 市辖区 + 区 | 市 + 区直接连道路 |
///
/// > 原 App 的地址来自高德 SDK 的 `formattedAddress`，形如
/// > 「上海市浦东新区高东镇严家港路」—— **不含国名**、直辖市只写一次。
/// > 这里做的是把 MapKit 的同类字段对齐到那个写法，不引入新内容。
///
/// ## 为什么只做字符串规范化，不重新拼装
/// 自己拼需要省 / 市 / 区 / 街道 / 门牌五个字段，而免费反查在多数路段
/// **只给到道路级**（这条路上没有门牌数据）。缺字段时拼出来的地址
/// 比原文更糟 —— 会出现「上海市浦东新区」这种半截地址。
/// 所以这里只做「删该删的」，不动顺序、不补内容。
enum AddressNormalizer {

    private static let municipalities = ["北京市", "上海市", "天津市", "重庆市"]

    static func gaodeStyle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        // ① 国名 —— 高德从不显示
        for prefix in ["中华人民共和国", "中国"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }

        // ② 直辖市重复：Apple 常给「上海市上海市」
        for city in municipalities {
            let duplicated = city + city
            while s.contains(duplicated) {
                s = s.replacingOccurrences(of: duplicated, with: city)
            }
            // ③「上海市市辖区浦东新区」→「上海市浦东新区」
            s = s.replacingOccurrences(of: city + "市辖区", with: city)
        }

        // ④ 通用：任何相邻重复的「XX市XX市」合并成一段。
        //    省直辖县级市（湖北省仙桃市仙桃市）会踩到这个。
        s = collapseRepeatedCity(s)

        return s.isEmpty ? raw : s
    }

    /// 合并相邻重复的市名。`湖北省仙桃市仙桃市` → `湖北省仙桃市`。
    ///
    /// 按「市」切段再逐段比对，而不是做正则替换 ——
    /// 正则要枚举「任意两个相同的中文段」，写出来比这个长十倍还容易误伤。
    private static func collapseRepeatedCity(_ input: String) -> String {
        var segments: [String] = []
        var current = ""
        for ch in input {
            current.append(ch)
            if ch == "市" {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty { segments.append(current) }

        var merged: [String] = []
        for segment in segments {
            if merged.last == segment { continue }
            merged.append(segment)
        }
        return merged.joined()
    }
}

// MARK: - 车辆 pin

/// 地图上的车辆标记。两处共用（缩略图 / 全屏），尺寸不同。
private struct CarPin: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(Glass.Tone.bluetooth)
            Image(systemName: "car.fill")
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
        .glassElevation(.card)
    }
}

// MARK: - 全屏地图

/// 点开后的全屏地图。只做三件事：看清楚在哪、我在哪、从哪导航过去。
private struct VehicleLocationDetail: View {
    let coordinate: VehicleCoordinate
    let address: String?
    let title: String
    @ObservedObject var me: UserLocationProvider

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    /// 「这个 App 打不开」这类临时说明。4 秒后自动消失（见 `navigationEntries`）。
    @State private var hint: String?

    private var mapCoordinate: CLLocationCoordinate2D {
        let c = coordinate.mapCoordinate
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    private var myCoordinate: CLLocationCoordinate2D? {
        guard let fix = me.fix, fix.isUsable else { return nil }
        let c = fix.mapCoordinate
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                map
                bottomBar
            }
            .navigationTitle("车辆位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.tactile()
                }
            }
        }
        .onAppear {
            me.start()
            frame()
        }
        // ⚠️ 必须配对。`UserLocationProvider` 是按引用计数管 GPS 的：
        // 只 start 不 stop，每打开一次全屏地图计数就 +1，永不归零 ——
        // 结果是定位一直开着，且卡片关闭后也停不下来。
        .onDisappear { me.stop() }
        .onChange(of: me.fix) { _, _ in frame() }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            Annotation("", coordinate: mapCoordinate) {
                CarPin(size: 34)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // 自己的位置按钮 + 指南针：用户拖远了能一键回到自己身边，
        // 这是"我和车的相对位置"这张图唯一需要的控件。
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .ignoresSafeArea(edges: .bottom)
    }

    /// 首次以中点为心；之后用户拖动过就不再抢回镜头。
    private func frame() {
        guard case .automatic = camera else { return }
        let car = mapCoordinate
        guard let my = myCoordinate else {
            camera = .region(MKCoordinateRegion(
                center: car,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)))
            return
        }
        let spanLat = max(abs(car.latitude - my.latitude) * 1.8, 0.004)
        let spanLon = max(abs(car.longitude - my.longitude) * 1.8, 0.004)
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (car.latitude + my.latitude) / 2,
                                           longitude: (car.longitude + my.longitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)))
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Glass.Tone.bluetooth)
                Text(address ?? "位置已记录")
                    .font(Glass.Typo.body.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            // 距离与采集时间：一个回答"多远"，一个回答"这个位置有多旧"
            HStack(spacing: 6) {
                if let distance = distanceText {
                    // 图标用 `ruler` 不用 `figure.walk`：这是**直线**距离，
                    // 画一个人形会让人以为是步行里程（两者能差好几倍）。
                    Label(distance, systemImage: "ruler")
                        .font(Glass.Typo.micro.weight(.semibold))
                        .foregroundStyle(Glass.Tone.bluetooth)
                } else if me.failure != nil {
                    Label(me.failure ?? "", systemImage: "location.slash")
                        .font(Glass.Typo.micro)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(ageText)
                    .font(Glass.Typo.micro)
                    .foregroundStyle(.secondary)
            }

            if !coordinate.trusted {
                Label("车端标记这条位置不可信（地库、隧道里常见），仅供参考",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Glass.Typo.micro)
                    .foregroundStyle(Glass.Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            navigationEntries
        }
        .padding(Glass.cardPadding)
        .contentCard()
        .padding(.horizontal, Glass.pageMargin)
        .padding(.bottom, 12)
    }

    /// 导航入口。
    ///
    /// 主按钮固定走系统地图 —— 它是唯一**一定会打开**的入口（https 链接，
    /// 不依赖装任何 App），放主位置能保证第一次点就不会失败。
    ///
    /// 下面三个第三方是并列的备选。这里**没有**用 `canOpenURL` 预判装没装：
    /// iOS 27 已把它标为 deprecated，官方建议「直接尝试打开、处理失败即可」。
    /// 于是改成点下去试一次，失败了留在本页说明原因 ——
    /// 比"猜错安装状态把入口藏起来"更可靠，也不会把用户误带到别的 App 里。
    private var navigationEntries: some View {
        VStack(spacing: 8) {
            Button {
                open(.apple)
            } label: {
                Label("导航到这里", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).tactile(Haptics.commit)

            HStack(spacing: 8) {
                ForEach(NavigationApp.thirdParty) { app in
                    Button {
                        open(app)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: app.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(app.tint)
                            Text(app.shortName)
                                .font(.system(size: 10, weight: .medium))
                                // 不能用 `.secondary`：玻璃按钮会把背后的地图
                                // 亮度压下来，10pt 的次要色在深色地图上等于隐形
                                // （真机截图确认）。
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 42)
                    }
                    .buttonStyle(.glass).tactile()
                }
            }

            if let hint {
                Label(hint, systemImage: "info.circle")
                    .font(Glass.Typo.micro)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 提示自动消失：它是"这次没打开"的临时说明，不是需要长期停留的状态
        .task(id: hint) {
            guard hint != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            hint = nil
        }
    }

    private var distanceText: String? {
        guard let fix = me.fix, fix.isUsable else { return nil }
        let meters = fix.distance(to: coordinate)
        if meters < 1000 { return "直线 \(Int((meters / 10).rounded()) * 10) 米" }
        return String(format: "直线 %.1f 公里", meters / 1000)
    }

    private var ageText: String {
        guard coordinate.reportedAt != .distantPast else { return "采集时间未知" }
        let seconds = Date().timeIntervalSince(coordinate.reportedAt)
        if seconds < 0 { return "时间异常" }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "刚刚更新" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前" }
        return "\(hours / 24) 天前"
    }

    private func open(_ app: NavigationApp) {
        guard let url = app.url(to: mapCoordinate, name: title) else { return }
        // 用带 completion 的版本而不是 `canOpenURL` 预判：
        // iOS 27 里后者已 deprecated，且它只探测 scheme 注册，
        // 探测通过也不代表能起导航（很多版本的 App 会忽略未知参数）。
        // 打开失败（success == false 表示没有 App 接手这个 scheme）才提示。
        UIApplication.shared.open(url, options: [:]) { success in
            hint = success ? nil : "打不开\(app.name)，这个 App 可能还没安装"
        }
    }
}

// MARK: - 第三方导航

/// 能接「到某点导航」的 App。
///
/// ## 坐标
/// 三家国内地图的 URL Scheme 都收 **GCJ-02**（高德 `dev=0`、
/// 百度 `coord_type=gcj02`、腾讯默认火星坐标），所以传的是
/// `coordinate.mapCoordinate`，**不是**原始 WGS-84 —— 混用会偏 500 米。
///
/// ## 为什么用 URL 而不是各家 SDK
/// 只为了一次「跳到别的 App 导航」去集成三个 SDK（每个几十 MB + 各自的
/// key 申请）完全不划算，而且它们都要求在主工程里注册 AppKey。
/// URL Scheme 零依赖，只需要拼对参数。
enum NavigationApp: String, CaseIterable, Identifiable {
    case amap
    case baidu
    case tencent
    case apple

    var id: String { rawValue }

    /// 三个第三方入口，界面上的第二排就是它。
    static var thirdParty: [NavigationApp] {
        allCases.filter { $0 != .apple }
    }

    /// 完整名字，只用在提示文案里（"打不开高德地图"）
    var name: String {
        switch self {
        case .amap:    return "高德地图"
        case .baidu:   return "百度地图"
        case .tencent: return "腾讯地图"
        case .apple:   return "系统地图"
        }
    }

    var shortName: String {
        switch self {
        case .amap:    return "高德"
        case .baidu:   return "百度"
        case .tencent: return "腾讯"
        case .apple:   return "地图"
        }
    }

    var symbol: String {
        switch self {
        case .amap:    return "location.north.fill"
        case .baidu:   return "location.north.circle.fill"
        case .tencent: return "location.circle.fill"
        case .apple:   return "map.fill"
        }
    }

    /// 品牌色只用在图标上，不做大面积填充 ——
    /// 三个品牌色铺开会让这张卡变成"应用启动器"，而它首先是一张位置卡。
    ///
    /// 这里取的是**提亮过的**品牌色，不是各家官方主色：这几个图标只有 13pt，
    /// 又叠在玻璃按钮上（玻璃会把它背后的地图亮度压下来），
    /// 用官方原色在深色地图上几乎看不见 —— 真机截图验证过一次。
    var tint: Color {
        switch self {
        case .amap:    return Color(red: 0.16, green: 0.56, blue: 1.00)
        case .baidu:   return Color(red: 0.38, green: 0.50, blue: 1.00)
        case .tencent: return Color(red: 0.20, green: 0.80, blue: 0.54)
        case .apple:   return .primary
        }
    }

    func url(to coordinate: CLLocationCoordinate2D, name: String) -> URL? {
        let lat = String(format: "%.7f", coordinate.latitude)
        let lon = String(format: "%.7f", coordinate.longitude)

        switch self {
        case .apple:
            var comps = URLComponents(string: "https://maps.apple.com/")
            comps?.queryItems = [
                URLQueryItem(name: "daddr", value: "\(lat),\(lon)"),
                URLQueryItem(name: "dirflg", value: "d"),   // 驾车
                URLQueryItem(name: "q", value: name)        // 目标点的显示名
            ]
            return comps?.url

        case .amap:
            // dev=0 表示传入的是 GCJ-02（1 则是 WGS-84），别写反。
            // t=0 驾车 / 1 公交 / 2 步行
            var comps = URLComponents(string: "iosamap://path")
            comps?.queryItems = [
                URLQueryItem(name: "sourceApplication", value: "GKUIBleKey"),
                URLQueryItem(name: "dlat", value: lat),
                URLQueryItem(name: "dlon", value: lon),
                URLQueryItem(name: "dname", value: name),
                URLQueryItem(name: "dev", value: "0"),
                URLQueryItem(name: "t", value: "0")
            ]
            return comps?.url

        case .baidu:
            // destination 的格式是 `latlng:纬度,经度|name:名称`，
            // 顺序是**纬度在前**，和常见写法相反。coord_type 指定输入坐标系。
            var comps = URLComponents(string: "baidumap://map/direction")
            comps?.queryItems = [
                URLQueryItem(name: "destination", value: "latlng:\(lat),\(lon)|name:\(name)"),
                URLQueryItem(name: "coord_type", value: "gcj02"),
                URLQueryItem(name: "mode", value: "driving"),
                URLQueryItem(name: "src", value: "com.mmxisme.gkuiblekey")
            ]
            return comps?.url

        case .tencent:
            // 腾讯的 referer 在 URL Scheme 里只做来源标识，不校验 key。
            var comps = URLComponents(string: "qqmap://map/routeplan")
            comps?.queryItems = [
                URLQueryItem(name: "type", value: "drive"),
                URLQueryItem(name: "to", value: name),
                URLQueryItem(name: "tocoord", value: "\(lat),\(lon)"),
                URLQueryItem(name: "referer", value: "gkuiblekey")
            ]
            return comps?.url
        }
    }
}
