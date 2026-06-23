#pragma once

// 工作块 D D-3a:让 Live2D 模型「活起来」的核心 —— 继承 `CubismUserModel` 的精简子类。
//
// 为何必须继承:Cubism 的 motion / 呼吸 / 眨眼 / 物理 / pose / 表情管理器(`_motionManager`
// `_breath` `_eyeBlink` `_physics` `_pose` `_expressionManager` `_dragManager`)在
// `CubismUserModel` 里全是 **protected** —— 组合方式(持有一个 CubismUserModel*)根本碰不到。
// 官方 sample 的 `LAppModel` 同样靠继承访问。本类是 LAppModel 的精简版:**只管模型侧资产 +
// 每帧参数推进**,纹理 / renderer / Metal 绘制仍由 ObjC `L2DLive2DModel` 负责(那部分需要
// MTLDevice)。加载 / Update 序列精确取证官方 sample `LAppModel::LoadAssets` / `LAppModel::Update`
// (SDK 5-r.5)。
//
// 纯 C++(无 ObjC)→ 编为 .cpp;桥的 .mm 内 #include 本头持有实例。

#include <CubismFramework.hpp>
#include <ICubismModelSetting.hpp>
#include <Model/CubismUserModel.hpp>
#include <Type/csmString.hpp>
#include <Type/csmMap.hpp>
#include <Type/csmVector.hpp>

/// motion 优先级(取证官方 sample LAppDefine):数字越大越能抢占。
/// 与 Swift 侧 `Live2DMotionPriority` 镜像保持一致。
enum L2DMotionPriority {
    L2DMotionPriorityNone = 0,
    L2DMotionPriorityIdle = 1,
    L2DMotionPriorityNormal = 2,
    L2DMotionPriorityForce = 3,
};

/// 继承 CubismUserModel 的桌宠模型 —— 封装「加载全部资产 + 每帧驱动 motion/effect/physics」。
class L2DUserModel : public Live2D::Cubism::Framework::CubismUserModel {
public:
    L2DUserModel();
    virtual ~L2DUserModel();

    /// 加载 model3.json 引用的全部**模型侧**资产:moc + 表情 + 物理 + pose + 用户数据 +
    /// 眨眼 / 呼吸 effect + 预载所有 motion 组 + modelMatrix。纹理 / renderer 由调用方另做。
    /// `dir` 须以 `/` 结尾。失败返回 false。
    bool LoadAssets(const Live2D::Cubism::Framework::csmChar* dir,
                    const Live2D::Cubism::Framework::csmChar* model3FileName);

    /// 每帧推进:idle 自动循环 + motion + 表情 + 眨眼 + 呼吸 + 物理 + pose,末尾 `model->Update()`。
    /// `deltaTimeSeconds` 秒。取证 LAppModel::Update。
    void Update(Live2D::Cubism::Framework::csmFloat32 deltaTimeSeconds);

    /// 播放指定组的指定序号 motion。`priority` 决定能否抢占当前。返回队列句柄(失败 InvalidHandle)。
    Live2D::Cubism::Framework::CubismMotionQueueEntryHandle
    StartMotion(const Live2D::Cubism::Framework::csmChar* group,
                Live2D::Cubism::Framework::csmInt32 index,
                Live2D::Cubism::Framework::csmInt32 priority);

    /// 随机播组内一条(round-robin,免 RNG,可测)。组不存在 / 空 → InvalidHandle。
    Live2D::Cubism::Framework::CubismMotionQueueEntryHandle
    StartRandomMotion(const Live2D::Cubism::Framework::csmChar* group,
                      Live2D::Cubism::Framework::csmInt32 priority);

    /// 应用一个表情(model3.json 的 Expressions 之一)。id 不存在则忽略。
    void SetExpression(const Live2D::Cubism::Framework::csmChar* expressionId);

    /// 设置「看向 / 被拖」目标点(-1..1,驱动 ParamAngle/ParamBodyAngle/ParamEyeBall)。
    void SetDragTarget(Live2D::Cubism::Framework::csmFloat32 x,
                       Live2D::Cubism::Framework::csmFloat32 y);

    /// model3.json 的 motion 组名(供上层做情绪映射 best-effort 选择)。
    Live2D::Cubism::Framework::csmInt32 GetMotionGroupCount();
    const Live2D::Cubism::Framework::csmChar* GetMotionGroupName(Live2D::Cubism::Framework::csmInt32 index);
    Live2D::Cubism::Framework::csmInt32 GetMotionCount(const Live2D::Cubism::Framework::csmChar* group);

    /// 表情 id 列表(供上层映射)。
    Live2D::Cubism::Framework::csmInt32 GetExpressionCount();
    const Live2D::Cubism::Framework::csmChar* GetExpressionName(Live2D::Cubism::Framework::csmInt32 index);

    /// 纹理(供 ObjC `L2DLive2DModel` 调 renderer->BindTexture)。
    Live2D::Cubism::Framework::csmInt32 GetTextureCount();
    const Live2D::Cubism::Framework::csmChar* GetTextureFileName(Live2D::Cubism::Framework::csmInt32 index);

    /// 是否成功加载了物理 / pose 资产(供无头探针验证)。
    bool HasPhysics() const;
    bool HasPose() const;

    /// 默认 idle 组名("Idle",Cubism 约定)。Update 在 motion 播完时自动重启它。
    static const Live2D::Cubism::Framework::csmChar* IdleGroupName();

private:
    void SetupModelMatrix();
    void PreloadMotionGroup(const Live2D::Cubism::Framework::csmChar* group);

    Live2D::Cubism::Framework::ICubismModelSetting* _modelSetting;
    Live2D::Cubism::Framework::csmString _modelDir;
    Live2D::Cubism::Framework::csmFloat32 _userTimeSeconds;

    /// 预载的 motion,键 "group_index"。autoDelete=false,本类析构时统一删。
    Live2D::Cubism::Framework::csmMap<Live2D::Cubism::Framework::csmString,
                                      Live2D::Cubism::Framework::ACubismMotion*> _motions;
    /// 预载的表情,键 = 表情 id。
    Live2D::Cubism::Framework::csmMap<Live2D::Cubism::Framework::csmString,
                                      Live2D::Cubism::Framework::ACubismMotion*> _expressions;
    /// motion 随机选的 round-robin 游标(每组一个),键 = 组名。
    Live2D::Cubism::Framework::csmMap<Live2D::Cubism::Framework::csmString,
                                      Live2D::Cubism::Framework::csmInt32> _motionCursor;

    Live2D::Cubism::Framework::csmVector<Live2D::Cubism::Framework::CubismIdHandle> _eyeBlinkIds;
    Live2D::Cubism::Framework::csmVector<Live2D::Cubism::Framework::CubismIdHandle> _lipSyncIds;

    // 看向 / 拖拽参数 id(缓存,避免每帧查表)。
    const Live2D::Cubism::Framework::CubismId* _idParamAngleX;
    const Live2D::Cubism::Framework::CubismId* _idParamAngleY;
    const Live2D::Cubism::Framework::CubismId* _idParamAngleZ;
    const Live2D::Cubism::Framework::CubismId* _idParamBodyAngleX;
    const Live2D::Cubism::Framework::CubismId* _idParamEyeBallX;
    const Live2D::Cubism::Framework::CubismId* _idParamEyeBallY;
};
