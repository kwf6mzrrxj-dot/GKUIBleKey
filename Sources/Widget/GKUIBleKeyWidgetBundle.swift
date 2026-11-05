import WidgetKit
import SwiftUI

@main
struct GKUIBleKeyWidgetBundle: WidgetBundle {
    var body: some Widget {
        VehicleLiveActivityWidget()
        // 桌面小组件（小 / 中）：点按直接控车，不需要打开 App
        VehicleStatusWidget()
        // 控制中心 / 锁屏控件（iOS 18+）
        LockControlWidget()
        UnlockControlWidget()
        FindControlWidget()
    }
}
