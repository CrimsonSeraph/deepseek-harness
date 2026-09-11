// broken-window.qml — 故意失败夹具：让 qml.exe 在加载阶段就失败
//
// 用途：验证「QML 出错 → 窗口出不来」时工具链不会假装成功。
// 配合 custom/tools/selftest.sh 使用，也可以手工验证：
//
//   shoot.sh --qml broken-window.qml --out-dir <输出目录> 320 568 mobile broken
//   → 期望：退出码 4（QML 进程异常退出），日志里能看到 import 失败的具体原因
//
// 它仍然带有 targetWidth / targetHeight / kind 三个标记，
// 因此会先通过模板校验，走到「启动 qml.exe」这一步才失败。

import QtQuick
import ThisModuleDoesNotExist 1.0   // ← 故意引用不存在的模块

Item {
    property int targetWidth: 320
    property int targetHeight: 568
    property string kind: "mobile"
}
