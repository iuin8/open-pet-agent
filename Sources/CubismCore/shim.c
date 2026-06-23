/* SwiftPM C target 需 ≥1 个源文件;真实现全在 Vendor 的 libLive2DCubismCore.a。
 * 此 shim 仅触发 C target 编译 + 暴露 CubismCore 模块(见 include/CubismCore.h)。 */
#include "CubismCore.h"
