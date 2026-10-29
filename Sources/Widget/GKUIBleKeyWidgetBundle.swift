import WidgetKit
import SwiftUI

@main
struct GKUIBleKeyWidgetBundle: WidgetBundle {
    var body: some Widget {
        VehicleLiveActivityWidget()
        // 控制中心 / 锁屏控件（iOS 18+）
        LockControlWidget()
        UnlockControlWidget()
        FindControlWidget()
    }
}
