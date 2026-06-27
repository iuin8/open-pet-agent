import AppKit
import Context
import Foundation
import QuartzCore
import Rendering
import RuntimeBridge
import Shell
import Shimeji
import simd

// MARK: - Runtime frame loop

extension MinimalAppDelegate {

    /// 「交互冻结」判定:开关 on 且**有贴着 pet 的卡片/菜单开着**(对话卡片 / 右键上下文菜单)或
    /// 鼠标悬停在 pet 上。on 时帧循环把自主运动(漫步+跟随)当本帧关闭 → pet 停原地。
    /// **原则:只冻结「会跟着 pet 走的东西」开着的情况**(免 pet 漫步把它拖走);大设置窗口居中、
    /// 不跟随 pet,故**不**冻结。
    /// **黏附面冻结**:贴着 pet 且随 pet 移动的 UI(对话卡片 / 列容器 / 右键菜单)开着 →
    /// 冻结 pet 免它跑动把这些 UI 拖走。**不含**鼠标悬停。抛射回弹只受此约束(甩出的球该飞,
    /// 哪怕光标恰好在它身上),而漫步/跟随受完整 `shouldFreezePetMotion`(含悬停)约束。
    func shouldFreezeForStickySurface() -> Bool {
        guard isFreezeWhenInteractingEnabled else { return false }
        // 对话卡片可见(侧贴 pet,随 pet 移动重定位)。
        if chatCardWindowController?.window?.isVisible == true { return true }
        // 列容器可见(贴主卡、随主卡移动)→ 冻结 pet 防漫步把主卡/容器拖走。
        if columnContainerWindowController.isVisible { return true }
        // 右键上下文菜单开着(原生 NSMenu 不跟随窗口,但帧循环照 tick → pet 会漫步把菜单甩身后)。
        if (shellController?.windowSet.petWindow as? PetShellWindow)?.isContextMenuOpen == true { return true }
        return false
    }

    /// 据用户空闲时长向当前形象派 `.signatureIdle`(久闲招牌动作,每次久闲一次)/ `.greet`(久闲后回来)。
    /// 经 `dispatchSignature` 按 `supportedSignatures` 过滤 —— 不支持的形象自动 no-op(如 Orb 不演 signatureIdle)。
    func updateGreetIdleSignals(_ shell: DesktopShellController) {
        let idle = idleSecondsProvider()
        if idle >= Self.signatureIdleThreshold {
            if !petSignatureIdleFired {
                shell.dispatchSignature(.signatureIdle)
                petSignatureIdleFired = true
            }
            petWasActiveForGreet = false
        } else if idle < Self.greetReturnThreshold {
            if !petWasActiveForGreet {
                shell.dispatchSignature(.greet)   // 久闲后回来 → 打招呼
            }
            petWasActiveForGreet = true
            petSignatureIdleFired = false
        }
    }

    func shouldFreezePetMotion() -> Bool {
        if shouldFreezeForStickySurface() { return true }
        // 鼠标悬停在 pet 窗口上(想点/拖 pet 时它别躲)。仅约束漫步/跟随,不约束抛射回弹。
        if isFreezeWhenInteractingEnabled,
           let petWindow = shellController?.windowSet.petWindow,
           petWindow.frame.contains(NSEvent.mouseLocation) { return true }
        return false
    }

    /// Advances one physics frame. `private` on the live path; exposed as
    /// `internal` so `@testable` test targets can drive the frame loop directly.
    func advanceRuntimeFrame() async {
        let perfStart = Self.logFramePerf ? CACurrentMediaTime() : 0
        defer {
            if Self.logFramePerf {
                let elapsedMs = (CACurrentMediaTime() - perfStart) * 1000.0
                framePerfCounter &+= 1
                framePerfAccumulatedMs += elapsedMs
                if framePerfCounter % 30 == 0 {
                    let avg = framePerfAccumulatedMs / Double(framePerfCounter)
                    fputs("[FramePerf] avg=\(String(format: "%.2f", avg))ms over \(framePerfCounter) frames\n", stderr)
                    framePerfAccumulatedMs = 0
                    framePerfCounter = 0
                }
            }
        }
        guard let shellController else {
            SnowDiagnostics.log("frameSkipped reason=noShellController")
            return
        }

        guard isRuntimeFrameInFlight == false else {
            SnowDiagnostics.log("frameSkipped reason=inFlight snow=\(isSnowEnabled)")
            if isSnowEnabled {
                shellController.advanceSnowPlaceholderFrame()
            }
            return
        }

        isRuntimeFrameInFlight = true
        defer { isRuntimeFrameInFlight = false }

        // A.3.2 — Drive idle-fallback timer so timed-out states revert to .idle.
        chatBehaviorStateMachine?.tickIdleFallback(now: CACurrentMediaTime())

        // 生命感 signature:据空闲时长派 .signatureIdle(久闲)/ .greet(久闲后回来)。
        updateGreetIdleSignals(shellController)

        let previousRenderState = currentRenderState
        let capturedInteractionVersion = shellInteractionVersion
        do {
            await waitForRuntimeFrame()
            let now = currentTime()
            let rawDeltaTime = max(0, now - (lastFrameTime ?? now))
            let deltaTime = min(rawDeltaTime, maxDeltaTime)
            lastFrameTime = now
            // falling-sand 雪在 GPU 上自管粒子；Rust runtime 只算 pet pose +
            // contact_count，不需要回传 particle buffer（省一次 FFI marshalling）。
            let wantsParticles = false
            let tickResult = try await rootSystem.runtimeTicker.tick(
                previousRenderState: previousRenderState,
                deltaTime: deltaTime,
                wantsParticles: wantsParticles
            )
            let nextRenderState = tickResult.renderState
            guard capturedInteractionVersion == shellInteractionVersion else {
                return
            }

            // 工作块 A —— 运动仲裁层(决策 D2)。orchestrator 算出的 cursor-follow
            // 位置作「候选」喂给 PetMotionController,由它按模式(physics 透传 /
            // roaming 漫步 / perched 栖息)仲裁出最终位置 + 运动态。只在跟随启用时
            // 驱动位置:不跟随则沿用候选 + 窗口不动(与历史行为一致)。
            // A1 阶段仲裁恒为 .physics(透传),故位置与改造前逐帧相同,零回归;
            // 新增的仅是 applyPetMotion(phase) 把运动态转发给形象(Orb no-op)。
            // previousPosition = 上帧权威位置(currentRenderState 此刻尚未被本帧覆写,
            // 含拖拽 / 不跟随期间的真实落点)→ 传给控制器作 phase + 连续性基准,
            // 控制器因此无需自存位置,免 staleness。
            let previousPosition = Point(
                x: currentRenderState.petPositionX,
                y: currentRenderState.petPositionY
            )
            let candidate = Point(
                x: nextRenderState.petPositionX,
                y: nextRenderState.petPositionY
            )
            var resolvedX = nextRenderState.petPositionX
            var resolvedY = nextRenderState.petPositionY
            // 跟随 或 漫游 任一开 → 运动仲裁层驱动位置(控制器内按两个 flag 分流:
            // 追光标 / 连续漫游 / 空闲漫游 / 原地)。都关 → 窗口不动(历史行为)。
            // **拖拽优先**:用户正拖 pet 时漫游让位(grab 优先,对齐 HermesPet/Shimeji)——
            // 否则每帧 syncPetPosition 把拖到的位置盖回漫游目标 → "拖不动"。拖拽中保留
            // 落点(previousPosition = .petDrag 写入的拖拽点),不算 motion、不 sync(手指独占窗口);
            // 松手 isPetBeingDragged 回 false,次帧从落点继续漫游(steppedRoam 重力先落地)。
            let isDragging = shellController.isPetBeingDragged
            // 交互冻结:卡片可见 / 设置面板打开 / 鼠标悬停 pet 上 → 本帧把自主运动当关闭,pet 停原地
            //（免「拿着卡片的 pet 乱跑」/ 想点 pet 时它躲）。复用「跟随漫游都关 → 窗口不动」路径。
            let shouldFreeze = shouldFreezePetMotion()
            // 漫游按形象原生能力闸:弹力球(Orb)等纯物理形象 supportsAutonomousRoaming=false →
            // roamingActive 恒 false → 控制器只走 .physics(透传 cursor-follow),不漫步不爬墙。
            // 会走会爬的形象(Slime)opt-in true → 漫游开关照常生效。
            let petCanRoam = shellController.petRenderer?.supportsAutonomousRoaming ?? false
            let roamingActive = isRoamingEnabled && petCanRoam
            let spatialBehaviorEnabled = (isFollowingEnabled || roamingActive) && !shouldFreeze
            // Task 6:按形象 PetDriveModel 分发运动 —— 取代 `as? ShimejiPetRenderer` 二元 cast。
            // autonomousEngine(Shimeji)引擎自驱 / activityStateIndicator(petdex)·selfAnimating(Live2D)
            // 位置固定 / proceduralMotion(Orb·Slime)PetMotionController 仲裁。
            switch shellController.petRenderer?.driveModel ?? .proceduralMotion {
            case .autonomousEngine:
                // P4-B-5:引擎自管 anchor + 行为图,PetMotionController 整段让位。交互冻结跳过 tick
                //(停当前帧/位置),拖拽时仍驱动(引擎处理 Dragged + 窗口跟手),否则冻结期 hover 命中会让 pet 拖不动。
                if let shimeji = shellController.petRenderer as? ShimejiPetRenderer,
                   !shouldFreeze || isDragging {
                    driveShimejiPet(shimeji, snapshot: tickResult.snapshot, nextRenderState: nextRenderState)
                }
            case .activityStateIndicator, .selfAnimating:
                // 位置固定:不跑 PetMotionController、不漫步/不跟随。pet 停在上帧位置(用户仍可经
                // drag adapter 拖动,落点写回 previousPosition)。姿态由形象自驱(petdex=活动态切帧 /
                // Live2D=Cubism)。只让 renderState 跟上世界位置(供雪 occluder/sweep)。
                currentRenderState = RenderState(
                    petPositionX: previousPosition.x,
                    petPositionY: previousPosition.y,
                    petRotation: nextRenderState.petRotation,
                    particleCount: nextRenderState.particleCount,
                    particles: nextRenderState.particles,
                    contactCount: nextRenderState.contactCount,
                    isSnowEnabled: currentRenderState.isSnowEnabled
                )
            case .proceduralMotion:
            // 松手边沿:弹力球(supportsThrowPhysics)带甩出初速 → 进入 .ballistic 抛射回弹(重力+窗口/屏幕边回弹)。
            // 只受黏附面冻结约束(卡片/菜单开着才不抛),**不受悬停冻结**:刚松手时光标常在球上,该飞还得飞。
            let stickyFreeze = shouldFreezeForStickySurface()
            // 松手边沿:取走甩出初速。**每帧都 consume**(免滞留):黏附面冻结期间(卡片开)直接丢弃,
            // 不延后 → 免卡片关后触发几秒前那次甩;否则 beginThrow 进入抛射。
            if !isDragging,
               shellController.petRenderer?.supportsThrowPhysics == true,
               let throwV = shellController.consumeThrowVelocity() {
                if !stickyFreeze {
                    petMotionController.beginThrow(velocity: Point(x: Double(throwV.dx), y: Double(throwV.dy)))
                }
            }
            // 抛射中即使跟随/漫游都关、光标悬停也要驱动位置 + 移窗(飞行/回弹只受黏附面冻结约束,落定才交回);
            // 漫步/跟随仍受完整 shouldFreeze(含悬停)约束。
            let runController = !isDragging && (petMotionController.isBallistic
                ? !stickyFreeze
                : (!shouldFreeze && spatialBehaviorEnabled))
            if runController {
                // screenBounds = 当前屏 visibleFrame(排除 Dock/菜单栏),与 pet 位置
                // /光标同系(NSScreen 全局底原点)。漫步地面 = bounds.minY → pet 走在
                // 可见地面上,不沉到 Dock 下。TODO(多屏): currentScreenFrame 默认取主屏,
                // pet 漫游到副屏的边界跟随留待 multi-monitor 阶段。
                let visible = currentScreenFrame()
                let petFrame = shellController.windowSet.petWindow.frame
                let motionInput = PetMotionInput(
                    deltaTime: deltaTime,
                    cursorPosition: tickResult.snapshot.cursorPosition,
                    windows: CollisionRect.collection(from: tickResult.snapshot).map(\.bounds),
                    screenBounds: Rect(
                        origin: Point(x: Double(visible.minX), y: Double(visible.minY)),
                        width: Double(visible.width),
                        height: Double(visible.height)
                    ),
                    idleSeconds: idleSecondsProvider(),
                    followingEnabled: isFollowingEnabled,
                    roamingEnabled: roamingActive,
                    liveliness: shellController.roamLiveliness,   // item2:情绪态 → 漫步活跃度
                    petWidth: Double(petFrame.width),
                    petHeight: Double(petFrame.height)
                )
                let resolution = petMotionController.resolved(
                    previousPosition: previousPosition,
                    physicsCandidate: candidate,
                    input: motionInput
                )
                petMotionController = resolution.controller
                resolvedX = resolution.frame.position.x
                resolvedY = resolution.frame.position.y
                shellController.applyPetMotion(resolution.frame.phase)
            } else if isDragging || shouldFreeze {
                // 拖拽中 或 交互冻结:停在原地。清掉漫步/爬墙过渡态(否则松手/解冻 snap 回拖前所站窗口 perch),
                // 并保留当前落点(拖拽=currentRenderState 由 .petDrag 写入 / 冻结=上帧权威位置),不让 candidate/漫游覆盖。
                // **例外:抛射飞行中遇黏附面冻结(卡片开)→ 不销毁飞行态**,保留 .ballistic + 速度,
                // 冻结解除后从原地续飞/续落(免冻死半空);用户抓起(isDragging)仍打断接管。
                if isDragging || !petMotionController.isBallistic {
                    petMotionController.clearForExternalControl()
                }
                resolvedX = previousPosition.x
                resolvedY = previousPosition.y
            }

            currentRenderState = RenderState(
                petPositionX: resolvedX,
                petPositionY: resolvedY,
                petRotation: nextRenderState.petRotation,
                particleCount: nextRenderState.particleCount,
                particles: nextRenderState.particles,
                contactCount: nextRenderState.contactCount,
                isSnowEnabled: currentRenderState.isSnowEnabled
            )
            if runController {
                shellController.syncPetPosition(x: resolvedX, y: resolvedY)
                // A.5.1 step 4 (runtime side): derive a physics velocity from
                // the frame-to-frame pose delta and feed it to the orb so it
                // squashes during bounce / free-fall / wall-collision, not
                // just user drag. Gated internally against active drags.
                shellController.applyRuntimePetVelocity(
                    position: NSPoint(x: resolvedX, y: resolvedY),
                    now: now
                )
            }
            }   // switch driveModel
            // Phase 2 多宠同屏:主宠驱动后,顺带 tick 每只装饰物理伙伴(各自引擎 + 窗口,
            // 无 chat/雪;env 与主宠同款)。空集时 no-op。
            driveDecorativePets(snapshot: tickResult.snapshot)
            // 工作块 B3 —— pet 淋湿:每帧朝目标(下雨=1/晴=0)lerp(dt*3 ≈ 1s 平滑,
            // 与 FS wetness sheen 同节奏),转发给 sprite 形象叠蓝色水渍。不受 following
            // 限制(pet 不跟随也会被雨淋)。
            let wetTarget: Float = isRainEnabled ? 1.0 : 0.0
            petWetness += (wetTarget - petWetness) * min(1.0, Float(deltaTime) * 3.0)
            shellController.applyPetWetness(petWetness)
            // falling-sand 雪：每帧按天气写 spawn/温度 + 窗口遮挡矩形 + 触发重绘
            // （encodeFrame 在 useFallingSandMode 下走 FS driver.tick）。
            // weatherEffectsEnabled = false（菜单「停止天气系统」）→ 整段跳过：
            // 不 spawn、不 step、不重绘、不占 GPU。网格在 toggle 时已 clearFallingSand。
            if weatherEffectsEnabled {
                var fsRects: [SIMD4<Float>] = []
                if let gridSize = shellController.fallingSandGridSize {
                    let size = shellController.overlayBoundsForSnow
                    let worldSize = SIMD2<Float>(Float(max(size.width, 1)), Float(max(size.height, 1)))
                    let rects = CollisionRect.collection(from: tickResult.snapshot)
                    fsRects = fallingSandRects(
                        rects: rects, worldSize: worldSize,
                        gridWidth: gridSize.width, gridHeight: gridSize.height)
                }
                // 工作块 B1 —— pet 第二 occluder(雪堆 pet 身上)。只在下雪时启用(无雪无需
                // 占用 + 省每帧 alpha 提取)。pet 世界位置 = currentRenderState(仲裁后最终落点,
                // 与窗口遮挡矩形同系:屏幕全局底原点)→ 占位左下角 cell 原点。pet 每帧移动/换帧
                // → engine 每帧重栅格化,雪随之响应(物理正确)。Orb 形象 mask 返回 nil → 自动关。
                // 排在 tickFallingSand 之前:两者都只更新 driver pending 字段(occluder/rects)+
                // setNeedsDisplay 仅标脏,draw() 推迟到 runloop → 两个 pending 同帧落位,无延迟。
                let cell = Double(Self.fallingSandCellSize)
                let petCellX = Int((currentRenderState.petPositionX / cell).rounded(.down))
                let petCellY = Int((currentRenderState.petPositionY / cell).rounded(.down))
                shellController.applyPetOccluder(
                    enabled: isSnowEnabled,
                    cellSize: Self.fallingSandCellSize,
                    originCellX: petCellX,
                    originCellY: petCellY
                )
                // 工作块 B2 —— pet 扬雪:帧间 Δx/dt 算横速度(cellSize=1 → px=cell),pet 走动时
                // 身边飞行雪沿运动方向喷散。静止/dt=0 → velX=0,kernel 阈值(15 cell/s)滤掉不扬。
                let petVelX = deltaTime > 0
                    ? Float((currentRenderState.petPositionX - previousPosition.x) / deltaTime) : 0
                shellController.applyPetSnowSweep(
                    enabled: isSnowEnabled,
                    cellSize: Self.fallingSandCellSize,
                    originCellX: petCellX,
                    originCellY: petCellY,
                    velX: petVelX
                )
                shellController.tickFallingSand(
                    spawnSnow: isSnowEnabled,
                    spawnRain: isRainEnabled,
                    ambient: fallingSandAmbientTemperature,
                    rects: fsRects
                )
            }
            shellController.syncCompanionBehavior(currentRenderState.companionBehavior)
        } catch {
            runtimeFrameError = error
            SnowDiagnostics.log("frameError \(error.localizedDescription)")
        }
        // 自纠正帧率:静止(无运动驱动)→ 降到 visibleIdleFrameLoopHz 省窗口枚举/orchestrator;
        // 任一驱动一活下个 tick 即升回 30Hz(仅频率变化时 reschedule)。
        updateFrameRate()
    }

    /// P4-B-5:驱动 Shimeji 原始帧引擎一拍 —— 建 top-origin 环境 → tick → 摆窗 → 同步世界位置。
    /// 引擎自管 anchor,故位置每帧由它产出;PetMotionController 不参与(本帧已让位)。
    private func driveShimejiPet(
        _ shimeji: ShimejiPetRenderer,
        snapshot: DesktopSnapshot,
        nextRenderState: RenderState
    ) {
        var env = makeShimejiEnvironment(snapshot: snapshot)
        // 多宠互动:主宠也参与(找广播 affordance 的装饰宠跑过去 Hug);tick 后落地它产出的配对。
        let allPets = allShimejiPets()
        env.scanTarget = scanTarget(forID: Self.primaryPetID, anchor: shimeji.anchor, among: allPets)
        defer { applyOutgoingPairing(from: shimeji, among: allPets) }
        var worldX = currentRenderState.petPositionX
        var worldY = currentRenderState.petPositionY
        if let frame = shimeji.advance(environment: env) {
            shellController?.moveShimejiPetWindow(toFrame: frame)
            // 窗口 origin(bottom-origin 世界)= pet 左下;供雪 occluder/sweep 的世界位置。
            worldX = Double(frame.origin.x)
            worldY = Double(frame.origin.y)
        }
        currentRenderState = RenderState(
            petPositionX: worldX,
            petPositionY: worldY,
            petRotation: nextRenderState.petRotation,
            particleCount: nextRenderState.particleCount,
            particles: nextRenderState.particles,
            contactCount: nextRenderState.contactCount,
            isSnowEnabled: currentRenderState.isSnowEnabled
        )
    }

    /// 把 collision rects（world px, 底原点 y-up）转成 FS cell 坐标的遮挡矩形
    /// (x, y, w, h)。引擎把这些矩形栅格化成逐 cell 2D 遮挡 mask：cell 在任意矩形内
    /// → 雪不可进（堆在窗口顶），悬浮窗下方开阔地照常落雪。无需 z-order（在任意矩形内
    /// 即遮挡）。上限 64（引擎截断）。
    fileprivate func fallingSandRects(
        rects: [CollisionRect],
        worldSize: SIMD2<Float>,
        gridWidth: Int,
        gridHeight: Int
    ) -> [SIMD4<Float>] {
        let cellW = worldSize.x / Float(max(gridWidth, 1))
        let cellH = worldSize.y / Float(max(gridHeight, 1))
        return rects.prefix(64).map { rect in
            SIMD4<Float>(
                Float(rect.bounds.origin.x) / cellW,
                Float(rect.bounds.origin.y) / cellH,
                Float(rect.bounds.width) / cellW,
                Float(rect.bounds.height) / cellH
            )
        }
    }
}
