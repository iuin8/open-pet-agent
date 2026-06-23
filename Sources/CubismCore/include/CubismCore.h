/* 工作块 D:把 gitignored Vendor 里的 Cubism Core C API(专有二进制)暴露成 SwiftPM
 * 模块 `CubismCore`。本文件(我们的 shim)入库,真头/库在 Vendor/Cubism/(gitignored,
 * 由 scripts/setup-cubism.sh 装)。headerSearchPath 指到 Vendor 头,linkerSettings 链
 * 静态库。Swift 侧 `import CubismCore` 即得 csmGetVersion 等 C API。 */
#include "Live2DCubismCore.h"
