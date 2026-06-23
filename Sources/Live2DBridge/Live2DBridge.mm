#import "Live2DBridge.h"
#import "L2DUserModel.hpp"

// Cubism Framework C++ 头(在 gitignored Vendor/Cubism/Framework/src,headerSearchPath 指向)。
#include <CubismFramework.hpp>
#include <ICubismAllocator.hpp>
#include <Model/CubismMoc.hpp>
#include <Model/CubismModel.hpp>
#include <cmath>
#include <cstdlib>
#include <vector>

using namespace Live2D::Cubism::Framework;

namespace {

/// 最小 `ICubismAllocator` 实现 —— `CubismFramework::StartUp` 必需。malloc/free +
/// 手写对齐分配(对齐块头部存原始指针供释放)。D-2.2 真渲染仍复用同一 allocator。
class BridgeAllocator : public ICubismAllocator {
public:
    void* Allocate(const csmSizeType size) override { return std::malloc(size); }
    void Deallocate(void* memory) override { std::free(memory); }

    void* AllocateAligned(const csmSizeType size, const csmUint32 alignment) override {
        const size_t offset = alignment - 1 + sizeof(void*);
        void* raw = std::malloc(size + offset);
        if (raw == nullptr) { return nullptr; }
        void** aligned = reinterpret_cast<void**>(
            (reinterpret_cast<size_t>(raw) + offset) & ~static_cast<size_t>(alignment - 1));
        aligned[-1] = raw;   // 紧邻对齐地址前存原始指针
        return aligned;
    }
    void DeallocateAligned(void* alignedMemory) override {
        if (alignedMemory != nullptr) { std::free(reinterpret_cast<void**>(alignedMemory)[-1]); }
    }
};

BridgeAllocator g_allocator;
CubismFramework::Option g_option;

}  // namespace

@implementation L2DModelInfo {
@public
    float _canvasWidthPixel, _canvasHeightPixel, _pixelsPerUnit;
    NSInteger _parameterCount, _partCount;
}
- (float)canvasWidthPixel { return _canvasWidthPixel; }
- (float)canvasHeightPixel { return _canvasHeightPixel; }
- (float)pixelsPerUnit { return _pixelsPerUnit; }
- (NSInteger)parameterCount { return _parameterCount; }
- (NSInteger)partCount { return _partCount; }
@end

@implementation L2DMotionProbe {
@public
    NSInteger _motionGroupCount, _idleMotionCount, _expressionCount;
    BOOL _hasPhysics, _hasPose, _parametersAdvanced;
}
- (NSInteger)motionGroupCount { return _motionGroupCount; }
- (NSInteger)idleMotionCount { return _idleMotionCount; }
- (NSInteger)expressionCount { return _expressionCount; }
- (BOOL)hasPhysics { return _hasPhysics; }
- (BOOL)hasPose { return _hasPose; }
- (BOOL)parametersAdvanced { return _parametersAdvanced; }
@end

@implementation L2DBridge

+ (BOOL)startUpFramework {
    // Cubism 框架全局单例(Id manager 等)**非线程安全**。所有触碰框架全局态的桥入口都用
    // `@synchronized([L2DBridge class])` 同锁串行化 —— app 里渲染全在主线程(本无并发),但
    // Swift Testing 默认并行同进程跑多个用例会竞争 RegisterId 致崩(实测),此锁兜底。
    @synchronized ([L2DBridge class]) {
        // Cubism 两段生命周期:StartUp(装 allocator/log)→ Initialize(建 Id manager 等单例)。
        // 缺 Initialize → CubismModel::Initialize 取 GetIdManager() 得 null → 崩(D-2.1 实测)。
        if (!CubismFramework::IsStarted()) {        // 进程内幂等
            g_option.LogFunction = nullptr;
            g_option.LoggingLevel = CubismFramework::Option::LogLevel_Off;
            if (!CubismFramework::StartUp(&g_allocator, &g_option)) { return NO; }
        }
        if (!CubismFramework::IsInitialized()) {
            CubismFramework::Initialize();
        }
        return CubismFramework::IsInitialized() ? YES : NO;
    }
}

+ (BOOL)isFrameworkStarted {
    return (CubismFramework::IsStarted() && CubismFramework::IsInitialized()) ? YES : NO;
}

+ (L2DModelInfo *)loadMocAtPath:(NSString *)mocPath {
    if (![self startUpFramework]) { return nil; }
    NSData* data = [NSData dataWithContentsOfFile:mocPath];
    if (data == nil || data.length == 0) { return nil; }

    @synchronized ([L2DBridge class]) {   // CreateModel → Id manager,串行化(见 startUpFramework 注释)
        // shouldCheckMocConsistency=true:拒绝损坏 / 版本不符的 moc(返回 null),不崩。
        CubismMoc* moc = CubismMoc::Create(
            reinterpret_cast<const csmByte*>(data.bytes),
            static_cast<csmSizeInt>(data.length), true);
        if (moc == nullptr) { return nil; }

        CubismModel* model = moc->CreateModel();
        if (model == nullptr) { CubismMoc::Delete(moc); return nil; }

        L2DModelInfo* info = [[L2DModelInfo alloc] init];
        info->_canvasWidthPixel = model->GetCanvasWidthPixel();
        info->_canvasHeightPixel = model->GetCanvasHeightPixel();
        info->_pixelsPerUnit = model->GetPixelsPerUnit();
        info->_parameterCount = model->GetParameterCount();
        info->_partCount = model->GetPartCount();

        moc->DeleteModel(model);
        CubismMoc::Delete(moc);
        return [info autorelease];   // MRC(-fno-objc-arc):非 init/new/copy 家族须返回 +0 autoreleased
    }
}

+ (L2DMotionProbe *)probeMotionAtModel3Path:(NSString *)model3Path
                                 frameCount:(NSInteger)frameCount
                                         dt:(double)dt {
    if (![self startUpFramework] || model3Path == nil) { return nil; }

    @synchronized ([L2DBridge class]) {   // Cubism 全局态串行化(见 startUpFramework 注释)
        NSString* dir = [[model3Path stringByDeletingLastPathComponent] stringByAppendingString:@"/"];
        NSString* fileName = [model3Path lastPathComponent];

        L2DUserModel* model = new L2DUserModel();
        if (!model->LoadAssets([dir UTF8String], [fileName UTF8String]) || model->GetModel() == NULL) {
            delete model; return nil;
        }
        Live2D::Cubism::Framework::CubismModel* core = model->GetModel();

        // 跑帧前快照全部参数(此刻为默认姿态)。
        const csmInt32 paramCount = core->GetParameterCount();
        std::vector<float> before(static_cast<size_t>(paramCount));
        for (csmInt32 i = 0; i < paramCount; i++) { before[static_cast<size_t>(i)] = core->GetParameterValue(i); }

        // 触发 idle motion + 跑 N 帧 Update(呼吸/物理/motion 都会推进参数)。
        model->StartRandomMotion(L2DUserModel::IdleGroupName(), L2DMotionPriorityIdle);
        const csmFloat32 step = static_cast<csmFloat32>(dt > 0.0 ? dt : (1.0 / 30.0));
        for (NSInteger f = 0; f < (frameCount > 0 ? frameCount : 1); f++) { model->Update(step); }

        // 任一参数偏离默认 → 管线在动。
        BOOL advanced = NO;
        for (csmInt32 i = 0; i < paramCount; i++) {
            if (std::fabs(core->GetParameterValue(i) - before[static_cast<size_t>(i)]) > 1e-4f) { advanced = YES; break; }
        }

        L2DMotionProbe* probe = [[L2DMotionProbe alloc] init];
        probe->_motionGroupCount = model->GetMotionGroupCount();
        probe->_idleMotionCount = model->GetMotionCount(L2DUserModel::IdleGroupName());
        probe->_expressionCount = model->GetExpressionCount();
        probe->_hasPhysics = model->HasPhysics() ? YES : NO;
        probe->_hasPose = model->HasPose() ? YES : NO;
        probe->_parametersAdvanced = advanced;

        delete model;
        return [probe autorelease];
    }
}

@end
