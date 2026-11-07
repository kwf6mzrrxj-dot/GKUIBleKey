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
