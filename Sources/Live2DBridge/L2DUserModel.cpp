#include "L2DUserModel.hpp"

#include <CubismModelSettingJson.hpp>
#include <Model/CubismModel.hpp>
#include <Motion/CubismMotion.hpp>
#include <Motion/CubismMotionManager.hpp>
#include <Motion/CubismExpressionMotion.hpp>
#include <Motion/CubismExpressionMotionManager.hpp>
#include <Effect/CubismEyeBlink.hpp>
#include <Effect/CubismBreath.hpp>
#include <Effect/CubismPose.hpp>
#include <Physics/CubismPhysics.hpp>
#include <Math/CubismModelMatrix.hpp>
#include <Math/CubismTargetPoint.hpp>
#include <Id/CubismIdManager.hpp>
#include <CubismDefaultParameterId.hpp>

#include <fstream>
#include <vector>
#include <cstdio>

using namespace Live2D::Cubism::Framework;
using namespace Live2D::Cubism::Framework::DefaultParameterId;

// 工作块 D D-3a:L2DUserModel 实现。加载 / Update 序列精确取证官方 sample
// LAppModel::LoadAssets / SetupModel / Update(SDK 5-r.5),仅去掉:GL 纹理(ObjC 负责)、
// 音频 lip sync(桌宠无音频)、debug 渲染。

namespace {

/// 读整个文件到字节缓冲。失败返回 false。Cubism 各 Create/Load 接口会自行 copy 所需内容,
/// 故调用后即可释放本缓冲。
bool LoadFileBytes(const csmChar* path, std::vector<csmByte>& out) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) { return false; }
    std::streamsize size = f.tellg();
    if (size <= 0) { return false; }
    f.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    return static_cast<bool>(f.read(reinterpret_cast<char*>(out.data()), size));
}

/// 拼 "group_index" 作为 motion 缓存键。
csmString MotionKey(const csmChar* group, csmInt32 index) {
    csmString key(group);
    key += "_";
    // csmString 无 int 拼接,手动转。
    char buf[16];
    std::snprintf(buf, sizeof(buf), "%d", index);
    key += buf;
    return key;
}

bool IsEmptyName(const csmChar* s) {
    return s == NULL || s[0] == '\0';
}

}  // namespace

const csmChar* L2DUserModel::IdleGroupName() { return "Idle"; }

bool L2DUserModel::HasPhysics() const { return _physics != NULL; }
bool L2DUserModel::HasPose() const { return _pose != NULL; }

L2DUserModel::L2DUserModel()
    : CubismUserModel()
    , _modelSetting(NULL)
    , _userTimeSeconds(0.0f)
    , _idParamAngleX(NULL)
    , _idParamAngleY(NULL)
    , _idParamAngleZ(NULL)
    , _idParamBodyAngleX(NULL)
    , _idParamEyeBallX(NULL)
    , _idParamEyeBallY(NULL) {
}

L2DUserModel::~L2DUserModel() {
    for (csmMap<csmString, ACubismMotion*>::const_iterator it = _motions.Begin(); it != _motions.End(); ++it) {
        ACubismMotion::Delete(it->Second);
    }
    for (csmMap<csmString, ACubismMotion*>::const_iterator it = _expressions.Begin(); it != _expressions.End(); ++it) {
        ACubismMotion::Delete(it->Second);
    }
    if (_modelSetting != NULL) { CSM_DELETE(_modelSetting); _modelSetting = NULL; }
}

bool L2DUserModel::LoadAssets(const csmChar* dir, const csmChar* model3FileName) {
    if (IsEmptyName(dir) || IsEmptyName(model3FileName)) { return false; }
    _modelDir = csmString(dir);

    // ① model3.json → setting
    csmString settingPath = _modelDir;
    settingPath += model3FileName;
    std::vector<csmByte> settingBytes;
    if (!LoadFileBytes(settingPath.GetRawString(), settingBytes)) { return false; }
    _modelSetting = CSM_NEW CubismModelSettingJson(settingBytes.data(),
                                                   static_cast<csmSizeInt>(settingBytes.size()));

    // ② moc
    const csmChar* mocFile = _modelSetting->GetModelFileName();
    if (IsEmptyName(mocFile)) { return false; }
    csmString mocPath = _modelDir;
    mocPath += mocFile;
    std::vector<csmByte> mocBytes;
    if (!LoadFileBytes(mocPath.GetRawString(), mocBytes)) { return false; }
    LoadModel(mocBytes.data(), static_cast<csmSizeInt>(mocBytes.size()), true);
    if (_model == NULL) { return false; }

    // ③ 眨眼 / lipSync 参数 id(供 motion SetEffectIds + eyeBlink effect)
    {
        const csmInt32 eyeCount = _modelSetting->GetEyeBlinkParameterCount();
        for (csmInt32 i = 0; i < eyeCount; ++i) {
            _eyeBlinkIds.PushBack(_modelSetting->GetEyeBlinkParameterId(i));
        }
        const csmInt32 lipCount = _modelSetting->GetLipSyncParameterCount();
        for (csmInt32 i = 0; i < lipCount; ++i) {
            _lipSyncIds.PushBack(_modelSetting->GetLipSyncParameterId(i));
        }
    }

    // ④ 表情
    {
        const csmInt32 count = _modelSetting->GetExpressionCount();
        for (csmInt32 i = 0; i < count; ++i) {
            const csmChar* name = _modelSetting->GetExpressionName(i);
            const csmChar* file = _modelSetting->GetExpressionFileName(i);
            if (IsEmptyName(name) || IsEmptyName(file)) { continue; }
            csmString path = _modelDir;
            path += file;
            std::vector<csmByte> bytes;
            if (!LoadFileBytes(path.GetRawString(), bytes)) { continue; }
            ACubismMotion* expr = CubismExpressionMotion::Create(
                bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            if (expr == NULL) { continue; }
            csmString key(name);
            if (_expressions.IsExist(key)) { ACubismMotion::Delete(_expressions[key]); }
            _expressions[key] = expr;
        }
    }

    // ⑤ 物理
    {
        const csmChar* file = _modelSetting->GetPhysicsFileName();
        if (!IsEmptyName(file)) {
            csmString path = _modelDir;
            path += file;
            std::vector<csmByte> bytes;
            if (LoadFileBytes(path.GetRawString(), bytes)) {
                LoadPhysics(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            }
        }
    }

    // ⑥ pose
    {
        const csmChar* file = _modelSetting->GetPoseFileName();
        if (!IsEmptyName(file)) {
            csmString path = _modelDir;
            path += file;
            std::vector<csmByte> bytes;
            if (LoadFileBytes(path.GetRawString(), bytes)) {
                LoadPose(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            }
        }
    }

    // ⑦ 眨眼 effect
    if (_modelSetting->GetEyeBlinkParameterCount() > 0) {
        _eyeBlink = CubismEyeBlink::Create(_modelSetting);
    }

    // ⑧ 呼吸 effect(取证 LAppModel::SetupModel 的 breath 参数表)
    {
        _breath = CubismBreath::Create();
        csmVector<CubismBreath::BreathParameterData> breathParameters;
        CubismIdManager* ids = CubismFramework::GetIdManager();
        breathParameters.PushBack(CubismBreath::BreathParameterData(ids->GetId(ParamAngleX), 0.0f, 15.0f, 6.5345f, 0.5f));
        breathParameters.PushBack(CubismBreath::BreathParameterData(ids->GetId(ParamAngleY), 0.0f, 8.0f, 3.5345f, 0.5f));
        breathParameters.PushBack(CubismBreath::BreathParameterData(ids->GetId(ParamAngleZ), 0.0f, 10.0f, 5.5345f, 0.5f));
        breathParameters.PushBack(CubismBreath::BreathParameterData(ids->GetId(ParamBodyAngleX), 0.0f, 4.0f, 15.5345f, 0.5f));
        breathParameters.PushBack(CubismBreath::BreathParameterData(ids->GetId(ParamBreath), 0.5f, 0.5f, 3.2345f, 1.0f));
        _breath->SetParameters(breathParameters);
    }

    // ⑨ 用户数据(motion event)
    {
        const csmChar* file = _modelSetting->GetUserDataFile();
        if (!IsEmptyName(file)) {
            csmString path = _modelDir;
            path += file;
            std::vector<csmByte> bytes;
            if (LoadFileBytes(path.GetRawString(), bytes)) {
                LoadUserData(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
            }
        }
    }

    // ⑩ 预载所有 motion 组
    {
        const csmInt32 groupCount = _modelSetting->GetMotionGroupCount();
        for (csmInt32 i = 0; i < groupCount; ++i) {
            PreloadMotionGroup(_modelSetting->GetMotionGroupName(i));
        }
    }

    // ⑪ 看向 / 拖拽参数 id 缓存
    {
        CubismIdManager* ids = CubismFramework::GetIdManager();
        _idParamAngleX = ids->GetId(ParamAngleX);
        _idParamAngleY = ids->GetId(ParamAngleY);
        _idParamAngleZ = ids->GetId(ParamAngleZ);
        _idParamBodyAngleX = ids->GetId(ParamBodyAngleX);
        _idParamEyeBallX = ids->GetId(ParamEyeBallX);
        _idParamEyeBallY = ids->GetId(ParamEyeBallY);
    }

    _motionManager->StopAllMotions();
    return true;
}

void L2DUserModel::PreloadMotionGroup(const csmChar* group) {
    if (IsEmptyName(group)) { return; }
    const csmInt32 count = _modelSetting->GetMotionCount(group);
    for (csmInt32 i = 0; i < count; ++i) {
        const csmChar* file = _modelSetting->GetMotionFileName(group, i);
        if (IsEmptyName(file)) { continue; }
        csmString path = _modelDir;
        path += file;
        std::vector<csmByte> bytes;
        if (!LoadFileBytes(path.GetRawString(), bytes)) { continue; }
        CubismMotion* motion = CubismMotion::Create(bytes.data(), static_cast<csmSizeInt>(bytes.size()));
        if (motion == NULL) { continue; }

        // model3.json 可覆盖 motion3.json 内的淡入淡出。
        const csmFloat32 fadeIn = _modelSetting->GetMotionFadeInTimeValue(group, i);
        if (fadeIn >= 0.0f) { motion->SetFadeInTime(fadeIn); }
        const csmFloat32 fadeOut = _modelSetting->GetMotionFadeOutTimeValue(group, i);
        if (fadeOut >= 0.0f) { motion->SetFadeOutTime(fadeOut); }
        motion->SetEffectIds(_eyeBlinkIds, _lipSyncIds);

        csmString key = MotionKey(group, i);
        if (_motions.IsExist(key)) { ACubismMotion::Delete(_motions[key]); }
        _motions[key] = motion;
    }
}

void L2DUserModel::Update(csmFloat32 deltaTimeSeconds) {
    if (_model == NULL) { return; }
    _userTimeSeconds += deltaTimeSeconds;

    _dragManager->Update(deltaTimeSeconds);
    const csmFloat32 dragX = _dragManager->GetX();
    const csmFloat32 dragY = _dragManager->GetY();

    _model->LoadParameters();   // 上帧末保存的状态(供 motion 淡入混合)

    csmBool motionUpdated = false;
    if (_motionManager->IsFinished()) {
        StartRandomMotion(IdleGroupName(), L2DMotionPriorityIdle);   // idle 自动循环
    } else {
        motionUpdated = _motionManager->UpdateMotion(_model, deltaTimeSeconds);
    }
    _model->SaveParameters();

    // 表情(叠加)
    if (_expressionManager != NULL) {
        _expressionManager->UpdateMotion(_model, deltaTimeSeconds);
    }

    // 眨眼(motion 未覆盖眼睛参数时才自动眨)
    if (!motionUpdated && _eyeBlink != NULL) {
        _eyeBlink->UpdateParameters(_model, deltaTimeSeconds);
    }

    // 呼吸
    if (_breath != NULL) {
        _breath->UpdateParameters(_model, deltaTimeSeconds);
    }

    // 看向 / 被拖(叠加在 motion 之上)
    if (_idParamAngleX) { _model->AddParameterValue(_idParamAngleX, dragX * 30.0f); }
    if (_idParamAngleY) { _model->AddParameterValue(_idParamAngleY, dragY * 30.0f); }
    if (_idParamAngleZ) { _model->AddParameterValue(_idParamAngleZ, dragX * dragY * -30.0f); }
    if (_idParamBodyAngleX) { _model->AddParameterValue(_idParamBodyAngleX, dragX * 10.0f); }
    if (_idParamEyeBallX) { _model->AddParameterValue(_idParamEyeBallX, dragX); }
    if (_idParamEyeBallY) { _model->AddParameterValue(_idParamEyeBallY, dragY); }

    // 物理(头发 / 衣摆惯性)
    if (_physics != NULL) {
        _physics->Evaluate(_model, deltaTimeSeconds);
    }

    // pose(部件透明度切换)
    if (_pose != NULL) {
        _pose->UpdateParameters(_model, deltaTimeSeconds);
    }

    _model->Update();
}

CubismMotionQueueEntryHandle L2DUserModel::StartMotion(const csmChar* group, csmInt32 index, csmInt32 priority) {
    if (IsEmptyName(group) || _modelSetting == NULL) { return InvalidMotionQueueEntryHandleValue; }
    if (index < 0 || index >= _modelSetting->GetMotionCount(group)) { return InvalidMotionQueueEntryHandleValue; }

    if (priority == L2DMotionPriorityForce) {
        _motionManager->SetReservePriority(priority);
    } else if (!_motionManager->ReserveMotion(priority)) {
        return InvalidMotionQueueEntryHandleValue;   // 优先级不足,不打断当前
    }

    csmString key = MotionKey(group, index);
    if (!_motions.IsExist(key)) { return InvalidMotionQueueEntryHandleValue; }
    return _motionManager->StartMotionPriority(_motions[key], false, priority);
}

CubismMotionQueueEntryHandle L2DUserModel::StartRandomMotion(const csmChar* group, csmInt32 priority) {
    if (IsEmptyName(group) || _modelSetting == NULL) { return InvalidMotionQueueEntryHandleValue; }
    const csmInt32 count = _modelSetting->GetMotionCount(group);
    if (count <= 0) { return InvalidMotionQueueEntryHandleValue; }

    // round-robin 游标(免 RNG,行为可测;仍达成「不总是同一条」的变化感)。
    csmString key(group);
    csmInt32 cursor = _motionCursor.IsExist(key) ? _motionCursor[key] : 0;
    csmInt32 no = cursor % count;
    _motionCursor[key] = (cursor + 1) % count;
    return StartMotion(group, no, priority);
}

void L2DUserModel::SetExpression(const csmChar* expressionId) {
    if (IsEmptyName(expressionId) || _expressionManager == NULL) { return; }
    csmString key(expressionId);
    if (!_expressions.IsExist(key)) { return; }
    _expressionManager->StartMotion(_expressions[key], false);
}

void L2DUserModel::SetDragTarget(csmFloat32 x, csmFloat32 y) {
    _dragManager->Set(x, y);
}

csmInt32 L2DUserModel::GetMotionGroupCount() {
    return _modelSetting != NULL ? _modelSetting->GetMotionGroupCount() : 0;
}

const csmChar* L2DUserModel::GetMotionGroupName(csmInt32 index) {
    if (_modelSetting == NULL || index < 0 || index >= _modelSetting->GetMotionGroupCount()) { return NULL; }
    return _modelSetting->GetMotionGroupName(index);
}

csmInt32 L2DUserModel::GetMotionCount(const csmChar* group) {
    if (_modelSetting == NULL || IsEmptyName(group)) { return 0; }
    return _modelSetting->GetMotionCount(group);
}

csmInt32 L2DUserModel::GetExpressionCount() {
    return _modelSetting != NULL ? _modelSetting->GetExpressionCount() : 0;
}

const csmChar* L2DUserModel::GetExpressionName(csmInt32 index) {
    if (_modelSetting == NULL || index < 0 || index >= _modelSetting->GetExpressionCount()) { return NULL; }
    return _modelSetting->GetExpressionName(index);
}

csmInt32 L2DUserModel::GetTextureCount() {
    return _modelSetting != NULL ? _modelSetting->GetTextureCount() : 0;
}

const csmChar* L2DUserModel::GetTextureFileName(csmInt32 index) {
    if (_modelSetting == NULL || index < 0 || index >= _modelSetting->GetTextureCount()) { return NULL; }
    return _modelSetting->GetTextureFileName(index);
}
