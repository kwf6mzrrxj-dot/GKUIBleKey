# 车辆位置

## 一、数据从哪来

云端 `/remote-control/vehicle/status/{VIN}` 响应里的：

```
data.vehicleStatus.basicVehicleStatus.position
```

| 字段 | 实际类型 | 含义 |
|---|---|---|
| `latitude` | **String** | 微度（度 × 3,600,000） |
| `longitude` | **String** | 同上 |
| `altitude` | String | 海拔，米 |
| `posCanBeTrusted` | Bool / String | 车端自评这条位置可不可信 |
| `marsCoordinates` | Bool / String | `false` = 不是火星坐标 = WGS-84 |

两个容易踩的点：

1. **类型是字符串**。`"latitude": "112896144"`，`as? Double` 会失败。
   实测里第一次就撞上 `TypeError: unsupported operand type(s) for /: 'str' and 'int'`。
2. **单位是微度**。`112896144 / 3_600_000 = 31.36004`。
   忘了除会得到"一亿度"的纬度；除错量级（1e6 / 1e7）会落到海里。

蓝牙广播**没有**位置字段 —— 只在云端车况里，所以纯蓝牙模式下整张位置卡不出现。

## 二、坐标系：WGS-84，必须转 GCJ-02

### 判定依据（反汇编，不是猜）

从原 App `XiaoKa.app` 找到业务类与调用点：

```
CarStatusPositionModel
  _altitude / _latitude / _longitude / _marsCoordinates / _posCanBeTrusted   ← 全是 NSString
```

```
100d06d18:  ldr  x1, [x8, #0x198]   ; selector: setExternalLocation:isAMapCoordinate:
100d06d1c:  mov  w3, #0x0           ; isAMapCoordinate = NO，硬编码
100d06d20:  b    0x101b15c84       ; -[x0 setExternalLocation:isAMapCoordinate:]
```

原 App 把车辆坐标喂给高德 SDK 时，第二个参数**写死为 NO** ——
明确声明"这不是高德坐标"，由 SDK 内部完成 WGS-84 → GCJ-02。

`marsCoordinates: false` 是第二个独立佐证。

### 实测确认（2026-11-07）

反汇编只能证明"原 App 认为它是 WGS-84"，证明不了"这套转换参数在本地图上恰好对得上"。
两者都成立才算闭环，所以做了一次实地核对：

| 步骤 | 结果 |
|---|---|
| 车端原始 | `31.3601578, 121.5281489` |
| 本实现转换后 | `31.3581088, 121.5324924` |
| 粘进高德 App 搜索框 | **落点与车辆实际停放位置一致** ✓ |

> 当时的干扰项：Apple 反查给出「严家港路」、OSM 给出「港城路」，两条不同的路，
> 看起来像坐标错了。实际都只是**免费反查服务在中国没有门牌级数据**导致的粗糙结果，
> 470 米的差距正好是火星坐标偏移量 —— 那是 2013 年的历史遗留，不是 bug。

### 为什么必须自己转

Apple 地图 / 高德在中国的底图是 GCJ-02。
**直接把这个坐标丢给 `MKMapView` 会偏 400–500 米** —— 找车时人会走到隔壁小区。

实测量级（上海）：

| | 坐标 |
|---|---|
| 车端原始（WGS-84） | 31.3601578, 121.5281489 |
| 转 GCJ-02 后 | 31.3581088, 121.5324924 |
| 偏移 | **470 米**（东 412 / 南 227） |

实现见 `Sources/Support/CoordinateTransform.swift`，用 `SelfTest` 里的
「车辆位置 · WGS-84 → GCJ-02」用例守住（期望值由独立 Python 实现算出）。

## 三、"实时"要打折

`updateTime` 是**车端采集**这份位置的时刻，不是"现在"。

实测：下午 14:41 拉到的位置，`updateTime` 是 **12:50** —— 110 分钟前。
车停稳后车机休眠，位置就不再更新。

所以界面必须显示「X 分钟前 / X 小时前」，不能把两小时前的点当实时位置。
想拿更新的位置，得先唤醒车机（发一条命令），它才会重新上报。

## 四、可不可信

`posCanBeTrusted` 是车端自己的判断。地库、隧道里常为 `false`，
或者 `updateTime` 停在很久以前。

界面处理：
- 卡片上标「可能不准」（橙色小标签）
- 全屏地图底部给一句完整说明

**对着一个错误的位置找车，比没有位置更糟** —— 所以宁可把不确定标出来。

## 五、已知边界

1. **只在云端有**。纯蓝牙模式看不到位置。
2. **不会自动刷新**。位置跟着车况走，车况靠下拉刷新或定时拉取。
3. **反地理编码依赖网络**，失败时只显示"位置已记录"，坐标仍然有效。
4. **没有逆转换**。如果将来要支持拖动选点，需要补 GCJ-02 → WGS-84。

## 六、地址命名：高德优先，MapKit 兜底（2026-11-07）

### 为什么不能用 MapKit 一家

MapKit 的反地理编码只回到**道路级**：「上海市浦东新区严家港路」。
而原 App（`XiaoKa.app`）链的是**高德定位 SDK**，回调结构就写在二进制里：

```
AMapLocationReGeocode:{formattedAddress:%@; country:%@; province:%@;
  city:%@; district:%@; street:%@; number:%@; POIName:%@; AOIName:%@;}
```

`AOIName`（AOI 面）是「XX小区」的来源，`number` 是门牌。
MapKit 没有 AOI 概念 —— 所以"小区 + 楼栋"这件事 MapKit 做不到。

### 实现

`Sources/Net/AMapGeocoder.swift` 调高德 Web 服务：

```
GET https://restapi.amap.com/v3/geocode/regeo
    ?key=…&location=经度,纬度&extensions=all&radius=200
```

三个容易错的点：

1. **`location` 是「经度,纬度」**，和几乎所有其他坐标写法相反。
   写反了高德会返回 `status=1` 但 `regeocode` 为空 —— 不报错，只是没数据。
2. **传 GCJ-02**（`VehicleCoordinate.mapCoordinate`），不要传 `coordsys=gps`。
   高德这个接口默认按 GCJ-02 解释，和给 MapKit 的是同一套坐标；
   让它自己转等于对同一个点转两次，又偏 400 米。
3. **`extensions=all`** 才有 `aois` / `pois` / `building`，`base` 只给 `formatted_address`。

### 实测返回（2026-11-07，车辆实际位置）

```json
formatted_address: "上海市浦东新区高桥镇浦凌佳苑7号楼"
aois: ["浦凌佳苑"]
building.name: []                 ← 空
streetNumber: { number: "328号", street: "康悦路", distance: "171.156" }
```

四条字段各有坑，处理方式：

| 字段 | 问题 | 处理 |
|---|---|---|
| `formatted_address` | 含完整行政区，做标题太长 | 做副标题 |
| `aois[0].name` | 「浦凌佳苑」缺楼栋 | 做标题主体 |
| `building.name` | 住宅区实测是空数组 | 不用 |
| `streetNumber.number` | **171 米外**隔壁路的门牌 | **不用**，拼上去就是假地址 |

**楼栋从 `formatted_address` 里切**：命中小区时它会直接带上楼栋
（`…浦凌佳苑7号楼`），取「AOI 名之后那一段」拼回 AOI，
得到「浦凌佳苑7号楼」—— 和高德 App 的写法一致。

### key 的存放

本仓库是**公开**的，key 写进源码等于公开（个人额度 5000 次/天，被刷完当天就用不了）。
所以按项目里 `builtin-keys.txt` 的同一套做法：

| 顺序 | 来源 | 说明 |
|---|---|---|
| 1 | `UserDefaults["amap.webKey"]` | 换 key 不用重新打包 |
| 2 | Bundle 内 `amap-key.txt` | 本地文件，**已在 `.gitignore`** |
| 3 | 无 | 返回 nil → 回退 MapKit |

模板见 `Resources/amap-key.example.txt`。key 类型必须是**「Web服务」**，
用 iOS / Android 平台的 key 会返回 `USERKEY_PLAT_NOMATCH`（infocode 10009）。

### 失败一律回退

高德是网络服务，key 失效、断网、额度用尽都会失败。
`resolveAddress()` 在这种情况下退回 MapKit 的道路级结果 ——
**卡片不会白屏**，只是精度降一级。

### 缓存

按坐标 4 位小数（≈11 米）缓存：同一个车位重复打开必命中，
车开出十几米才失效 —— 那个尺度上地址本来也该变了。
缓存的两个理由：车控页和状态页各有一张卡，同一坐标会发两次请求；
切页 / 卡片重建还会再来。
