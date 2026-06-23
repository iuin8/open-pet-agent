#import <Foundation/Foundation.h>
@protocol MTLDevice;
@protocol MTLCommandBuffer;
@protocol MTLTexture;
@protocol CAMetalDrawable;

// 工作块 D D-2.0:Cubism Native Framework(C++ + ObjC++ Metal renderer)的 ObjC 桥。
//
// 为何走 ObjC 桥而非 Swift/C++ interop:Cubism Framework 是重 C++(Csm 命名空间、模板、
// 裸指针)+ ObjC++ Metal renderer,直接 Swift/C++ interop 脆弱难维护。桥的 .mm 内部 #include
// Cubism C++ 头,**公开头只暴露 Foundation 类型** → Swift 原生 `import Live2DBridge` 即用,
// 无需开 .interoperabilityMode(.Cxx)。蓝本 swift-cubism 的 CubismBridge 模式。
//
// D-2.0 只验证 framework C++/ObjC++ 在 SwiftPM 编译 + 链接 + `CubismFramework::StartUp`
// 可调(de-risk 最大未知量)。模型加载(D-2.1)/ Metal 渲染(D-2.2)后续往本桥加方法。

NS_ASSUME_NONNULL_BEGIN

/// D-2.1:一个 Cubism 模型(.moc3)解析出的只读元信息 —— 证明框架真能解析真实模型数据
/// (画布尺寸 + 参数/部件数),也是 D-2.2 渲染时定 viewport / 参数驱动的基础。
@interface L2DModelInfo : NSObject
/// 画布像素宽 / 高(`GetCanvasWidthPixel` / `GetCanvasHeightPixel`)。
@property (nonatomic, readonly) float canvasWidthPixel;
@property (nonatomic, readonly) float canvasHeightPixel;
/// 每单位像素数(`GetPixelsPerUnit`)。
@property (nonatomic, readonly) float pixelsPerUnit;
/// 可驱动参数数(`GetParameterCount`)。
@property (nonatomic, readonly) NSInteger parameterCount;
/// 部件数(`GetPartCount`)。
@property (nonatomic, readonly) NSInteger partCount;
@end

/// D-3a:无头验证「motion/呼吸/物理引擎真的在驱动模型」—— 不建 renderer/纹理(不需 Metal),
/// 仅加载全部资产 + 跑几帧 `Update(dt)`,断言参数被推进。证明 D-3 motion 管线在真实模型上工作
/// (实际 motion 播放的视觉效果由装好的 app 录屏验收)。
@interface L2DMotionProbe : NSObject
/// model3.json 声明的 motion 组数 / idle 组 motion 条数 / 表情数。
@property (nonatomic, readonly) NSInteger motionGroupCount;
@property (nonatomic, readonly) NSInteger idleMotionCount;
@property (nonatomic, readonly) NSInteger expressionCount;
/// 是否有物理 / pose 资产成功加载。
@property (nonatomic, readonly) BOOL hasPhysics;
@property (nonatomic, readonly) BOOL hasPose;
/// 跑若干帧 `Update(dt)` 后,模型参数是否相对默认值发生变化(呼吸 + idle motion + 物理叠加的
/// 综合证据 —— 证明 Update 管线真在动)。
@property (nonatomic, readonly) BOOL parametersAdvanced;
@end

/// D-2.2b:一个已加载到 Metal 的 Cubism 模型 —— 持有 CubismUserModel + Cubism Metal renderer,
/// 逐帧绘进给定 drawable。Swift 侧 `Live2DPetRenderer` 用它 + CAMetalLayer + CVDisplayLink。
@interface L2DLive2DModel : NSObject

/// 用 `model3.json` 路径 + Metal device 加载模型(moc + 纹理 + renderer + 绑定)。失败返回 nil
/// (文件缺 / moc 损坏 / 渲染管线 metallib 缺等)。
- (nullable instancetype)initWithModel3Path:(NSString *)model3Path
                                     device:(id<MTLDevice>)device;

@property (nonatomic, readonly) float canvasWidthPixel;
@property (nonatomic, readonly) float canvasHeightPixel;

/// 每帧绘制:更新模型姿态 + 画进 `drawable`(透明清屏)。`width`/`height` = drawable 像素尺寸,
/// `depthTexture` 须与之同尺寸(renderer 需深度附件);`deltaTime` 秒(static 姿态可传 0)。
- (void)drawInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   drawable:(id<CAMetalDrawable>)drawable
               depthTexture:(nullable id<MTLTexture>)depthTexture
                      width:(double)width
                     height:(double)height
                  deltaTime:(double)deltaTime;

/// 工作块 D D-4a —— 把**当前已更新姿态**(不再 `Update`,避免与 display 帧叠加成 2× 速度)
/// 渲进任意离屏 `targetTexture`,供上层读回 alpha 轮廓喂 falling-sand pet occluder(雪堆身上)。
/// `width`/`height` = target 像素尺寸(应与 display 同纵横比,使轮廓与屏幕像素对齐);
/// `depthTexture` 须与之同尺寸。须在同帧 `drawInCommandBuffer:`(含 `Update`)**之后**调用。
- (void)renderSilhouetteInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          targetTexture:(id<MTLTexture>)targetTexture
                           depthTexture:(nullable id<MTLTexture>)depthTexture
                                  width:(double)width
                                 height:(double)height;

/// 缩略图:离屏渲一帧摆好姿势的模型(内部 `Update` 一次 + `DrawModel`)→ 任意 `targetTexture`。
/// 与 `draw` 同序但目标是离屏纹理;上层读回 color 即模型静态预览图(设置 picker 缩略图)。
- (void)renderThumbnailInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         targetTexture:(id<MTLTexture>)targetTexture
                          depthTexture:(nullable id<MTLTexture>)depthTexture
                                 width:(double)width
                                height:(double)height;

// MARK: - D-3b 情绪态 / 速度驱动(供 Swift Live2DPetRenderer 映射)

/// model3.json 声明的 motion 组名(供上层 best-effort 选 reaction 组)。
@property (nonatomic, readonly) NSArray<NSString *> *motionGroupNames;
/// 表情名(model3.json Expressions;无则空数组)。
@property (nonatomic, readonly) NSArray<NSString *> *expressionNames;

/// 随机播某 motion 组里一条(打断当前)。`priority`:0 none / 1 idle / 2 normal / 3 force。
/// 组不存在 / 优先级不足 → 忽略。
- (void)startRandomMotionInGroup:(NSString *)group priority:(NSInteger)priority;

/// 应用一个表情;id 不存在则忽略。
- (void)setExpression:(NSString *)expressionId;

/// 设「看向 / 被拖」目标(x/y ∈ -1..1,驱动头/眼/身朝向;`_dragManager` 内部平滑趋近)。
/// 速度归零时传 (0,0) 回正。
- (void)setLookTargetX:(float)x y:(float)y;
@end

/// Cubism Framework 的 ObjC 门面(类名 `L2DBridge` 区别于模块名 `Live2DBridge`,避免
/// Swift 侧模块/类型同名歧义)。
@interface L2DBridge : NSObject

/// 启动 Cubism Framework(`CubismFramework::StartUp` + 内部 allocator)。
/// 进程内幂等:已启动则直接返回 YES。返回 NO = StartUp 失败(Core 未正确链接等)。
+ (BOOL)startUpFramework;

/// `CubismFramework::IsStarted()` —— 框架是否已就绪。
+ (BOOL)isFrameworkStarted;

/// 加载一个 `.moc3` 文件 → 解析模型,返回画布/参数/部件信息;失败(文件读不到 / moc
/// 版本不符 / 一致性校验失败)返回 nil。内部自动确保 framework 已 StartUp。
/// D-2.1 只读元信息(无渲染);D-2.2 会扩成持有模型 + Metal 渲染。
+ (nullable L2DModelInfo *)loadMocAtPath:(NSString *)mocPath;

/// D-3a:无头加载 model3.json 全部资产 + 跑 `frameCount` 帧 `Update(dt)`,返回探针结果。
/// 失败(model3 读不到 / moc 损坏)返回 nil。`dt` 秒(典型 1/30)。
+ (nullable L2DMotionProbe *)probeMotionAtModel3Path:(NSString *)model3Path
                                          frameCount:(NSInteger)frameCount
                                                  dt:(double)dt;

@end

NS_ASSUME_NONNULL_END
