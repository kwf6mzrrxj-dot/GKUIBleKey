import Foundation

/// **WGS-84 → GCJ-02**（俗称"火星坐标"）转换。
///
/// ## 为什么必须转
/// 车端上报的是 **WGS-84** 原始 GPS 坐标（见下），而 Apple 地图 / 高德在中国的
/// 底图是 **GCJ-02**。直接把 WGS-84 交给 `MKMapView` 会**偏 400–500 米** ——
/// 找车时会走到隔壁小区。
///
/// ## 判断依据（不是猜的）
/// 从原 App（`XiaoKa.app`）的反汇编里找到：
///
/// ```
/// 100d06d18:  ldr  x1, [x8, #0x198]   ; selector: setExternalLocation:isAMapCoordinate:
/// 100d06d1c:  mov  w3, #0x0           ; isAMapCoordinate = NO，硬编码
/// 100d06d20:  b    ...                ; -[x0 setExternalLocation:isAMapCoordinate:]
/// ```
///
/// 原 App 调高德 SDK 时**明确声明"这不是高德坐标"**，由 SDK 内部完成转换。
/// 云端字段 `marsCoordinates: false` 是第二个独立佐证。
/// 反过来，如果它是 GCJ-02，原 App 会传 `YES` 让 SDK 跳过转换。
///
/// ## 已实测确认（2026-11-07）
/// 拿真实坐标 `31.3601578, 121.5281489` 转换得到 `31.3581088, 121.5324924`，
/// 把后者粘进**高德 App** 搜索框，落点与车辆实际停放位置一致。
///
/// 这一步不能省：反汇编只能证明"原 App 认为它是 WGS-84"，
/// 证明不了"这套转换参数在本地图上恰好对得上"。两者都成立才算闭环。
/// （若哪天落点整体偏移，先怀疑底图供应商换了基准，而不是这段算法。）
///
/// ## 精度
/// 该算法是公开的逆向结果，与各家 SDK 的偏差通常在 1–2 米内 —— 找车足够。
/// 它**不是**测绘级算法，不要用来做地理围栏的精确边界。
enum CoordinateTransform {

    /// 克拉索夫斯基椭球长半轴
    private static let a = 6378245.0
    /// 第一偏心率平方
    private static let ee = 0.00669342162296594323

    /// WGS-84 → GCJ-02。境外坐标原样返回（GCJ-02 只在中国大陆生效）。
    static func wgs84ToGCJ02(latitude: Double, longitude: Double) -> (latitude: Double, longitude: Double) {
        guard !isOutOfChina(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }

        var dLat = transformLat(x: longitude - 105.0, y: latitude - 35.0)
        var dLon = transformLon(x: longitude - 105.0, y: latitude - 35.0)

        let radLat = latitude / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)

        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * Double.pi)

        return (latitude + dLat, longitude + dLon)
    }

    /// 粗略的国境判断。落在这个矩形外就不做偏移 ——
    /// 否则在境外会把坐标"平移"到一个不存在的位置。
    static func isOutOfChina(latitude: Double, longitude: Double) -> Bool {
        !(longitude > 73.66 && longitude < 135.05 &&
          latitude > 3.86 && latitude < 53.55)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Double.pi) + 320 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return ret
    }
}
