#!/usr/bin/env python3
"""App 维度干净录制 —— 只合成本 app 的窗口,背后终端/桌面全部排除。

动机:验证进场动画(侧宽卡 spring / halo / 任何 SwiftUI 过渡)时,常规全屏/单窗截图有两个坑:
  1. 全屏截图把终端、桌面也录进去,脏 + 慢(Retina 全屏 PNG 编码 ~200ms/帧 → 5fps);
  2. 透明 NSPanel(侧宽卡、overlay)按单窗 ID 截会「穿透」,抓到的是背后窗口而非卡片。
正解:`CGWindowListCreateImageFromArray(CGRectNull, [windowIDs], …)` 只合成指定窗口,
背后不入画 → 干净 + 只编码卡片大小 → 快(~15fps,合成 2 个卡片窗) + 这种 PNG Claude Read 读得了。

依赖:`/usr/bin/python3`(macOS 自带 PyObjC,有 Quartz)。需「屏幕录制」TCC 权限给调用方进程。

用法(侧宽卡 spring+halo 为例,配合 PETAGENT_DEBUG_SIDECARD=1 启动):
  pkill -f "MacOS/PetAgent"; sleep 1
  PETAGENT_DEBUG_SIDECARD=1 /Applications/PetAgent.app/Contents/MacOS/PetAgent &
  /usr/bin/python3 scripts/record-app-windows.py --frames 70 --out /tmp/frames \
      --wait 500-540 --match 500-540 --match 340-380
  # 然后(fps.txt 是真实帧率,喂 ffmpeg 让回放真实速度;-2 而非 -1 防奇数高度 yuv420p 失败):
  ffmpeg -y -framerate "$(cat /tmp/frames/fps.txt)" -i /tmp/frames/f%03d.png \
      -vf "scale=760:-2,format=yuv420p" -pix_fmt yuv420p ~/Desktop/anim.mp4
"""
import argparse, os, sys, time
import Quartz, Quartz.CoreGraphics as CG
from Cocoa import NSURL
import CoreFoundation as CF


def parse_range(s):
    lo, hi = s.split("-")
    return int(lo), int(hi)


def list_windows(owner):
    wins = CG.CGWindowListCopyWindowInfo(CG.kCGWindowListOptionOnScreenOnly, CG.kCGNullWindowID)
    return [w for w in wins if owner in w.get("kCGWindowOwnerName", "")]


def width_in(w, ranges):
    width = int(w["kCGWindowBounds"]["Width"])
    return any(lo <= width <= hi for lo, hi in ranges)


def matching_ids(owner, matches):
    """匹配尺寸过滤(--match 宽度区间;不给则取全部 owner 窗口)的窗口 ID。"""
    wins = list_windows(owner)
    if matches:
        wins = [w for w in wins if width_in(w, matches)]
    return [w["kCGWindowNumber"] for w in wins]


def grab(win_array, path):
    # CGRectNull → 自动取所列窗口 union bbox;只合成 win_array 里的窗口 → 背后不入画。
    img = CG.CGWindowListCreateImageFromArray(CG.CGRectNull, win_array, CG.kCGWindowImageDefault)
    if img is None:
        return False
    dest = Quartz.CGImageDestinationCreateWithURL(NSURL.fileURLWithPath_(path), "public.png", 1, None)
    Quartz.CGImageDestinationAddImage(dest, img, None)
    return Quartz.CGImageDestinationFinalize(dest)


def main():
    ap = argparse.ArgumentParser(description="App 维度干净录制(只合成本 app 窗口)")
    ap.add_argument("--owner", default="PetAgent", help="app 名(CGWindowOwnerName 子串)")
    ap.add_argument("--frames", type=int, default=70, help="抓多少帧")
    ap.add_argument("--out", required=True, help="PNG 输出目录")
    ap.add_argument("--wait", type=parse_range, metavar="LO-HI",
                    help="等宽度在此区间的窗口出现再开抓(对齐动画触发点),如 500-540")
    ap.add_argument("--match", type=parse_range, action="append", metavar="LO-HI",
                    help="只合成宽度在此区间的窗口(可重复);不给则合成全部 owner 窗口")
    ap.add_argument("--max-wait", type=float, default=12.0, help="等触发窗口的最长秒数")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    # 轮询等触发窗口出现(= 动画起点),再开抓。
    if args.wait:
        t0 = time.time()
        while time.time() - t0 < args.max_wait:
            if any(width_in(w, [args.wait]) for w in list_windows(args.owner)):
                break
            time.sleep(0.008)
        else:
            print(f"触发窗口(宽 {args.wait[0]}-{args.wait[1]})未出现", file=sys.stderr)
            sys.exit(1)

    ids = matching_ids(args.owner, args.match or [])
    if not ids:
        print("没匹配到任何窗口", file=sys.stderr)
        sys.exit(1)
    win_array = CF.CFArrayCreate(None, ids, len(ids), CF.kCFTypeArrayCallBacks)

    start = time.time()
    last = start
    for i in range(args.frames):
        grab(win_array, os.path.join(args.out, f"f{i:03d}.png"))
        last = time.time()
    elapsed = last - start
    fps = (args.frames - 1) / elapsed if elapsed > 0 else 30.0
    with open(os.path.join(args.out, "fps.txt"), "w") as f:
        f.write(f"{fps:.2f}")
    print(f"ids={ids} | {args.frames} 帧 / {elapsed:.2f}s → {fps:.1f} fps → {args.out}")


if __name__ == "__main__":
    main()
