import SwiftUI
import MapKit
import CoreLocation

/// 车辆位置卡片 —— 放在「状态」页。
///
/// ## 为什么不在车控页
/// 车控页已经有 10 个按钮 + 能源条，再加一张地图会把它挤成一屏半。
/// 位置属于「看」而不是「操作」，和状态页的定位一致。
///
/// ## 数据前提
/// 只有云端车况带位置（蓝牙广播没有），所以只用蓝牙时这张卡不出现。
/// 拿不到坐标时整卡不显示，不留占位。
struct VehicleLocationCard: View {

    let coordinate: VehicleCoordinate
    /// 可选：点「导航」时带上车辆名，系统地图会显示成"导航到 爱车"
    var title: String = "车辆"

    @State private var address: String?
    @State private var showFullMap = false

    /// 地图用 GCJ-02。
    ///
    /// 车端给的是 WGS-84，直接丢给 MapKit 会偏 400–500 米 ——
    /// 转换的必要性与依据见 `CoordinateTransform` 的注释。
    private var mapCoordinate: CLLocationCoordinate2D {
        let c = coordinate.mapCoordinate
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    var body: some View {
        VStack(spacing: 0) {
            mapPreview
            infoRow
        }
        .contentCard()
        .contentShape(Rectangle())
        .onTapGesture { showFullMap = true }
        .task(id: coordinate.reportedAt) { await resolveAddress() }
        .sheet(isPresented: $showFullMap) {
            VehicleLocationDetail(coordinate: coordinate,
                                  address: address,
                                  title: title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("车辆位置 \(address ?? "未知")，\(ageText)")
        .accessibilityHint("点按查看大地图")
    }

    // MARK: - 地图缩略

    private var mapPreview: some View {
        Map(initialPosition: .region(
            MKCoordinateRegion(center: mapCoordinate,
                               span: MKCoordinateSpan(latitudeDelta: 0.006,
                                                      longitudeDelta: 0.006)))
        ) {
            Annotation("", coordinate: mapCoordinate) {
                ZStack {
                    Circle().fill(Glass.Tone.bluetooth).frame(width: 26, height: 26)
                    Image(systemName: "car.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        // 缩略图不接受手势：整卡点击要能穿透，否则用户拖地图会把卡片点不起来
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .frame(height: 116)
        .clipShape(RoundedRectangle(cornerRadius: Glass.controlRadius, style: .continuous))
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
                    Text(address ?? "正在解析地址…")
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
                Text(ageText)
                    .font(Glass.Typo.micro)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Glass.cardPadding)
        .padding(.vertical, 12)
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

    private func resolveAddress() async {
        guard address == nil, coordinate.reportedAt != .distantPast else { return }

        // 传**原始 WGS-84**：逆向地理编码期望的就是它，内部按中国区规则处理
        let location = CLLocation(latitude: coordinate.latitude,
                                  longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        request.preferredLocale = Locale(identifier: "zh_CN")
        guard let items = try? await request.mapItems, let first = items.first else { return }

        // iOS 26 的地址表示：优先单行完整地址（"康悦路 328 号"这种）
        if let full = first.addressRepresentations?
            .fullAddress(includingRegion: false, singleLine: true),
           !full.isEmpty {
            address = full
        } else if let name = first.name, !name.isEmpty {
            address = name
        }
    }
}

// MARK: - 全屏地图

/// 点开后的全屏地图。只做两件事：看清楚在哪、能不能导航过去。
private struct VehicleLocationDetail: View {
    let coordinate: VehicleCoordinate
    let address: String?
    let title: String

    @Environment(\.dismiss) private var dismiss

    private var mapCoordinate: CLLocationCoordinate2D {
        let c = coordinate.mapCoordinate
        return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(initialPosition: .region(
                    MKCoordinateRegion(center: mapCoordinate,
                                       span: MKCoordinateSpan(latitudeDelta: 0.004,
                                                              longitudeDelta: 0.004)))
                ) {
                    Annotation("", coordinate: mapCoordinate) {
                        ZStack {
                            Circle().fill(Glass.Tone.bluetooth).frame(width: 34, height: 34)
                            Image(systemName: "car.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .ignoresSafeArea(edges: .bottom)

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

            if !coordinate.trusted {
                Label("车端标记这条位置不可信（地库、隧道里常见），仅供参考",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(Glass.Typo.micro)
                    .foregroundStyle(Glass.Tone.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openInMaps()
            } label: {
                Label("导航到这里", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).tactile(Haptics.commit)
        }
        .padding(Glass.cardPadding)
        .contentCard()
        .padding(.horizontal, Glass.pageMargin)
        .padding(.bottom, 12)
    }

    /// 交给系统地图。不自己实现导航 —— 那是另一个 App 的活。
    ///
    /// 用 URL 而不是 `MKMapItem.openInMaps`：后者在 iOS 26 还要先构造
    /// `MKMapItem(placemark:)`，而 `MKPlacemark` 已废弃。URL 这条路不依赖
    /// 任何一个会变的构造器，行为也更可预期。
    private func openInMaps() {
        var comps = URLComponents(string: "https://maps.apple.com/")
        comps?.queryItems = [
            URLQueryItem(name: "daddr", value: String(format: "%.7f,%.7f",
                                                      mapCoordinate.latitude,
                                                      mapCoordinate.longitude)),
            URLQueryItem(name: "dirflg", value: "d"),   // 驾车
            URLQueryItem(name: "q", value: title)       // 目标点的显示名
        ]
        if let url = comps?.url {
            UIApplication.shared.open(url)
        }
    }
}
