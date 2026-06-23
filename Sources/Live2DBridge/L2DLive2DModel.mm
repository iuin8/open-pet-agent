#import "Live2DBridge.h"
#import "L2DUserModel.hpp"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

// Cubism C++ 头(gitignored Vendor,headerSearchPath 指向)。
#include <CubismFramework.hpp>
#include <Model/CubismModel.hpp>
#include <Math/CubismMatrix44.hpp>
#include <Math/CubismModelMatrix.hpp>
#include <Rendering/CubismRenderer.hpp>
#include <Rendering/Metal/CubismRenderer_Metal.hpp>
#include <Rendering/Metal/CubismDeviceInfo_Metal.hpp>

// 工作块 D D-2.2b:把 Cubism Native Framework 的 Metal renderer 绑成可逐帧绘进 CAMetalLayer 的
// ObjC 类。加载/绘制序列**精确取证官方 Metal sample**(LAppModel + LAppLive2DManager 的
// SelectTarget_None 路径)。
// D-3a:模型本体改用 `L2DUserModel`(继承 CubismUserModel,封装 motion/呼吸/眨眼/物理/pose),
// 每帧 `_model->Update(dt)` 替代裸 `GetModel()->Update()` —— 模型从静态姿态变为「活的」。
// 本 .mm 走 MRC(-fno-objc-arc,与 framework Metal renderer 一致)—— 手动 retain/release。

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::Rendering;

@implementation L2DLive2DModel {
    L2DUserModel* _model;
    id<MTLDevice> _device;
    float _canvasWidthPixel;
    float _canvasHeightPixel;
    // Cubism renderer 的 `_textures` 是 csmMap 裸指针(MRC 下赋值不 retain) → renderer 不持
    // 纹理所有权。我们持一个 retain 的数组让纹理活到本对象销毁,dealloc 释放;否则
    // `newTextureWithContentsOfURL` 的 +1 永不回收(切换 Live2D 形象时逐次泄漏)。
    NSMutableArray<id<MTLTexture>>* _boundTextures;
}

- (float)canvasWidthPixel { return _canvasWidthPixel; }
- (float)canvasHeightPixel { return _canvasHeightPixel; }

- (instancetype)initWithModel3Path:(NSString *)model3Path device:(id<MTLDevice>)device {
    self = [super init];
    if (self == nil) { return nil; }
    if (device == nil || ![L2DBridge startUpFramework]) { [self release]; return nil; }
    _device = [device retain];

  // Cubism 全局态非线程安全 → 与 L2DBridge 共用同锁串行化(@synchronized 可重入)。
  @synchronized ([L2DBridge class]) {
    // 一次性把 device 交给 Cubism Metal renderer(全局)。重复调用安全。
    CubismRenderer_Metal::SetConstantSettings(device);

    NSString* dir = [[model3Path stringByDeletingLastPathComponent] stringByAppendingString:@"/"];
    NSString* fileName = [model3Path lastPathComponent];

    // ① 全部模型侧资产(moc + motion + 物理 + pose + 眨眼 + 呼吸 + userdata)。
    _model = new L2DUserModel();
    if (!_model->LoadAssets([dir UTF8String], [fileName UTF8String]) || _model->GetModel() == NULL) {
        [self release]; return nil;
    }

    _canvasWidthPixel = _model->GetModel()->GetCanvasWidthPixel();
    _canvasHeightPixel = _model->GetModel()->GetCanvasHeightPixel();

    // ② renderer(mask buffer 尺寸用 canvas 像素近似)
    _model->CreateRenderer(static_cast<csmUint32>(_canvasWidthPixel),
                           static_cast<csmUint32>(_canvasHeightPixel));
    CubismRenderer_Metal* renderer = _model->GetRenderer<CubismRenderer_Metal>();
    if (renderer == NULL) { [self release]; return nil; }

    // ③ 纹理 PNG → MTLTexture → BindTexture(文件名由 L2DUserModel 持有的 setting 提供)
    MTKTextureLoader* loader = [[[MTKTextureLoader alloc] initWithDevice:device] autorelease];
    NSDictionary* opts = @{ MTKTextureLoaderOptionSRGB: @NO };
    const csmInt32 texCount = _model->GetTextureCount();
    _boundTextures = [[NSMutableArray alloc] initWithCapacity:texCount];
    for (csmInt32 i = 0; i < texCount; i++) {
        const csmChar* tf = _model->GetTextureFileName(i);
        if (tf == NULL || tf[0] == '\0') { continue; }
        NSString* tp = [dir stringByAppendingString:[NSString stringWithUTF8String:tf]];
        NSError* err = nil;
        id<MTLTexture> tex = [loader newTextureWithContentsOfURL:[NSURL fileURLWithPath:tp]
                                                         options:opts error:&err];
        if (tex != nil) {
            renderer->BindTexture(static_cast<csmUint32>(i), tex);  // 存裸指针,不 retain
            [_boundTextures addObject:tex];                          // 我们持所有权直到 dealloc
            [tex release];                                           // 交还 newTexture 的 +1 给数组
        }
    }
    renderer->IsPremultipliedAlpha(false);
  }  // @synchronized
    return self;
}

- (void)drawInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                   drawable:(id<CAMetalDrawable>)drawable
               depthTexture:(id<MTLTexture>)depthTexture
                      width:(double)width
                     height:(double)height
                  deltaTime:(double)deltaTime {
    if (_model == NULL || _model->GetModel() == NULL || drawable == nil || width <= 0 || height <= 0) { return; }

  @synchronized ([L2DBridge class]) {   // Cubism 全局态串行化(见 initWithModel3Path 注释)
    // D-3a:driven update —— motion/呼吸/眨眼/物理/pose 全在这里推进(每显示帧一次)。
    _model->Update(static_cast<csmFloat32>(deltaTime));
    [self renderCoreInCommandBuffer:commandBuffer
                      targetTexture:drawable.texture
                       depthTexture:depthTexture
                              width:width
                             height:height];
  }  // @synchronized
}

// 工作块 D D-4a —— 把当前已更新姿态再渲一遍进离屏 target(**不再 Update**),供读回 alpha 轮廓。
- (void)renderSilhouetteInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          targetTexture:(id<MTLTexture>)targetTexture
                           depthTexture:(id<MTLTexture>)depthTexture
                                  width:(double)width
                                 height:(double)height {
    if (_model == NULL || _model->GetModel() == NULL || targetTexture == nil || width <= 0 || height <= 0) { return; }
  @synchronized ([L2DBridge class]) {
    [self renderCoreInCommandBuffer:commandBuffer
                      targetTexture:targetTexture
                       depthTexture:depthTexture
                              width:width
                             height:height];
  }  // @synchronized
}

// 缩略图:离屏渲一帧「摆好姿势」的模型(Update 一次让默认顶点就位 + DrawModel)→ 任意 targetTexture。
// 与 draw 同序,但目标是离屏纹理而非 drawable;上层读回 color 即模型静态预览图(设置 picker 缩略图)。
- (void)renderThumbnailInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                         targetTexture:(id<MTLTexture>)targetTexture
                          depthTexture:(id<MTLTexture>)depthTexture
                                 width:(double)width
                                height:(double)height {
    if (_model == NULL || _model->GetModel() == NULL || targetTexture == nil || width <= 0 || height <= 0) { return; }
  @synchronized ([L2DBridge class]) {
    _model->Update(0.016);   // 推一帧摆好姿势(默认顶点未 Update 会空渲)
    [self renderCoreInCommandBuffer:commandBuffer
                      targetTexture:targetTexture
                       depthTexture:depthTexture
                              width:width
                             height:height];
  }  // @synchronized
}

// 渲染核心(BeginFrameProcess → DrawModel,**不含 Update**)。display 帧与 silhouette 离屏共用。
// 调用方负责 `@synchronized([L2DBridge class])` 包裹与 `_model` 非空校验。projection 把模型按
// canvas/target 比例缩放居中(取证 LAppLive2DManager::onUpdate)—— display 与 silhouette 用同
// 纵横比 target 时,两遍轮廓像素对齐。
- (void)renderCoreInCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    targetTexture:(id<MTLTexture>)targetTexture
                     depthTexture:(id<MTLTexture>)depthTexture
                            width:(double)width
                           height:(double)height {
    CubismRenderer_Metal* renderer = _model->GetRenderer<CubismRenderer_Metal>();
    if (renderer == NULL) { return; }

    // 每帧 offscreen 管理(mask 裁剪缓冲)。
    CubismDeviceInfo_Metal* deviceInfo = CubismDeviceInfo_Metal::GetDeviceInfo(_device);
    deviceInfo->GetOffscreenManager()->BeginFrameProcess();

    MTLRenderPassDescriptor* rpd = [[[MTLRenderPassDescriptor alloc] init] autorelease];
    rpd.colorAttachments[0].texture = targetTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;       // 透明清屏(桌宠窗口无背景)
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    if (depthTexture != nil) {
        rpd.depthAttachment.texture = depthTexture;
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
        rpd.depthAttachment.clearDepth = 1.0;
    }

    renderer->StartFrame(commandBuffer, rpd);
    MTLViewport viewport = { 0.0, 0.0, width, height, 0.0, 1.0 };
    renderer->SetRenderViewport(viewport);

    const float aspectRatio = static_cast<float>(width) / static_cast<float>(height);
    const float displayRatio = static_cast<float>(height) / static_cast<float>(width);
    const float canvasRatio = _model->GetModel()->GetCanvasHeight() / _model->GetModel()->GetCanvasWidth();
    CubismMatrix44 projection;
    if (canvasRatio < displayRatio) {
        _model->GetModelMatrix()->SetWidth(2.0f);
        projection.Scale(1.0f, aspectRatio);
    } else {
        _model->GetModelMatrix()->SetHeight(2.0f);
        projection.Scale(1.0f / aspectRatio, 1.0f);
    }

    projection.MultiplyByMatrix(_model->GetModelMatrix());
    renderer->SetMvpMatrix(&projection);
    renderer->DrawModel();
}

// MARK: - D-3b 情绪态 / 速度驱动

- (NSArray<NSString *> *)motionGroupNames {
    NSMutableArray<NSString *>* names = [NSMutableArray array];
  @synchronized ([L2DBridge class]) {
    if (_model != NULL) {
        const csmInt32 count = _model->GetMotionGroupCount();
        for (csmInt32 i = 0; i < count; i++) {
            const csmChar* n = _model->GetMotionGroupName(i);
            if (n != NULL && n[0] != '\0') { [names addObject:[NSString stringWithUTF8String:n]]; }
        }
    }
  }
    return names;
}

- (NSArray<NSString *> *)expressionNames {
    NSMutableArray<NSString *>* names = [NSMutableArray array];
  @synchronized ([L2DBridge class]) {
    if (_model != NULL) {
        const csmInt32 count = _model->GetExpressionCount();
        for (csmInt32 i = 0; i < count; i++) {
            const csmChar* n = _model->GetExpressionName(i);
            if (n != NULL && n[0] != '\0') { [names addObject:[NSString stringWithUTF8String:n]]; }
        }
    }
  }
    return names;
}

- (void)startRandomMotionInGroup:(NSString *)group priority:(NSInteger)priority {
    if (group.length == 0) { return; }
  @synchronized ([L2DBridge class]) {
    if (_model != NULL) {
        _model->StartRandomMotion([group UTF8String], static_cast<csmInt32>(priority));
    }
  }
}

- (void)setExpression:(NSString *)expressionId {
    if (expressionId.length == 0) { return; }
  @synchronized ([L2DBridge class]) {
    if (_model != NULL) { _model->SetExpression([expressionId UTF8String]); }
  }
}

- (void)setLookTargetX:(float)x y:(float)y {
  @synchronized ([L2DBridge class]) {
    if (_model != NULL) { _model->SetDragTarget(x, y); }
  }
}

- (void)dealloc {
    if (_model != NULL) { delete _model; _model = NULL; }   // 先毁 renderer(持纹理裸指针)
    [_boundTextures release]; _boundTextures = nil;          // 再释放纹理(此时无人引用)
    [_device release];
    [super dealloc];
}

@end
