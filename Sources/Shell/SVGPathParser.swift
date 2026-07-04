import Foundation
import SwiftUI

/// 极简 SVG path 字符串 → SwiftUI `Path` 解析器(仅供品牌 logo 渲染用)。
///
/// 支持命令:`M m L l H h V v C c S s Q q T t A a Z z`
/// (含 SVG arc → cubic bezier 标准端点参数化转换,每段 ≤90°)。
/// 非通用 SVG 实现 —— 不处理 text/gradient/marker 等高级特性,只覆盖
/// 品牌 logo(Claude/OpenAI,来自 cc-switch MIT 提取的 SVG)path 用到的命令。
///
/// 设计参考:SVG 1.1 实现规范(arc 端点参数化) +业界标准 arc-to-bezier 公式。
enum SVGPathParser {
    /// 把 SVG path data 解析成 SwiftUI `Path`,缩放到 `rect`(viewBox 默认 24×24)。
    /// SVG y 轴向下,SwiftUI Shape 坐标系 y 也向下,方向一致无需翻转。
    static func parse(_ d: String, in rect: CGRect, viewBox: CGSize = CGSize(width: 24, height: 24)) -> Path {
        var path = Path()
        var p = CGPoint.zero       // current point
        var start = CGPoint.zero   // subpath 起点(Z 回到这里)
        var prevC: CGPoint? = nil  // 前一 cubic 的 control2(S/s 反射用)
        var prevQ: CGPoint? = nil  // 前一 quad 的 control(T/t 反射用)
        var cmd: Character = " "
        let sx = rect.width / viewBox.width
        let sy = rect.height / viewBox.height

        let tokens = tokenize(d)
        var i = 0
        // 取下一个数字;遇到新的 .command 停(隐式命令复用上一个 cmd 时调用方先消费 command)
        func next() -> Double {
            while i < tokens.count, case .command = tokens[i] { i += 1 }
            if i < tokens.count, case .number(let v) = tokens[i] { i += 1; return v }
            return 0
        }
        func pt(_ x: Double, _ y: Double, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: p.x + x * sx, y: p.y + y * sy)
                    : CGPoint(x: x * sx, y: y * sy)
        }

        while i < tokens.count {
            if case .command(let c) = tokens[i] { cmd = c; i += 1 }
            switch cmd {
            case "M", "m":
                let rel = (cmd == "m")
                p = pt(next(), next(), relative: rel)
                path.move(to: p); start = p
                cmd = rel ? "l" : "L"   // M 后续隐式为 L/l
                prevC = nil; prevQ = nil
            case "L", "l":
                p = pt(next(), next(), relative: cmd == "l")
                path.addLine(to: p)
                prevC = nil; prevQ = nil
            case "H", "h":
                let x = next()
                p = (cmd == "H") ? CGPoint(x: x * sx, y: p.y) : CGPoint(x: p.x + x * sx, y: p.y)
                path.addLine(to: p)
                prevC = nil; prevQ = nil
            case "V", "v":
                let y = next()
                p = (cmd == "V") ? CGPoint(x: p.x, y: y * sy) : CGPoint(x: p.x, y: p.y + y * sy)
                path.addLine(to: p)
                prevC = nil; prevQ = nil
            case "C", "c":
                let rel = (cmd == "c")
                let c1 = pt(next(), next(), relative: rel)
                let c2 = pt(next(), next(), relative: rel)
                p = pt(next(), next(), relative: rel)
                path.addCurve(to: p, control1: c1, control2: c2)
                prevC = c2; prevQ = nil
            case "S", "s":
                let rel = (cmd == "s")
                let c1 = prevC.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                let c2 = pt(next(), next(), relative: rel)
                p = pt(next(), next(), relative: rel)
                path.addCurve(to: p, control1: c1, control2: c2)
                prevC = c2; prevQ = nil
            case "Q", "q":
                let rel = (cmd == "q")
                let c = pt(next(), next(), relative: rel)
                p = pt(next(), next(), relative: rel)
                path.addQuadCurve(to: p, control: c)
                prevQ = c; prevC = nil
            case "T", "t":
                let rel = (cmd == "t")
                let c = prevQ.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                p = pt(next(), next(), relative: rel)
                path.addQuadCurve(to: p, control: c)
                prevQ = c; prevC = nil
            case "A", "a":
                let rel = (cmd == "a")
                let rx = next(), ry = next(), phi = next(), large = next(), sweep = next()
                let end = pt(next(), next(), relative: rel)
                appendArc(to: &path, from: p, end: end, rx: rx * sx, ry: ry * sy,
                          phi: phi, large: large > 0.5, sweep: sweep > 0.5)
                p = end
                prevC = nil; prevQ = nil
            case "Z", "z":
                path.closeSubpath()
                p = start
                prevC = nil; prevQ = nil
            default:
                i += 1   // 未知命令跳一个 token 防死循环
            }
        }
        return path
    }

    // MARK: - arc → cubic bezier(SVG 1.1 端点参数化)

    private static func appendArc(to path: inout Path, from p1: CGPoint, end p2: CGPoint,
                                  rx: Double, ry: Double, phi: Double, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0, p1 != p2 else { path.addLine(to: p2); return }
        let phiR = phi * .pi / 180
        let (cosP, sinP) = (cos(phiR), sin(phiR))
        // 1. 端点变换到 phi=0 系求圆心
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        var rx = abs(rx), ry = abs(ry)
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }
        let sign: Double = (large != sweep) ? 1 : -1
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = den == 0 ? 0 : sign * sqrt(max(0, num / den))
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let cx = cosP * cxp - sinP * cyp + (p1.x + p2.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p1.y + p2.y) / 2
        // 2. 起止角
        func vecAng(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = vecAng(1, 0, ux, uy)
        var dtheta = vecAng(ux, uy, vx, vy)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }
        // 3. 分段(每段 ≤90°)→ cubic bezier,alpha = (4/3)tan(Δ/4)
        let n = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        let seg = dtheta / Double(n)
        let alpha = (4.0 / 3.0) * tan(seg / 4)
        var a1 = theta1
        func rotate(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cx + cosP * (x - cx) - sinP * (y - cy),
                    y: cy + sinP * (x - cx) + cosP * (y - cy))
        }
        for _ in 0..<n {
            let a2 = a1 + seg
            let p1e = rotate(cx + rx * cos(a1), cy + ry * sin(a1))
            let p2e = rotate(cx + rx * cos(a2), cy + ry * sin(a2))
            let c1 = rotate(cx + rx * (cos(a1) - alpha * sin(a1)),
                            cy + ry * (sin(a1) + alpha * cos(a1)))
            let c2 = rotate(cx + rx * (cos(a2) + alpha * sin(a2)),
                            cy + ry * (sin(a2) - alpha * cos(a2)))
            _ = p1e   // 段起点 = 当前 path 末端,不重复 move
            path.addCurve(to: p2e, control1: c1, control2: c2)
            a1 = a2
        }
    }

    // MARK: - tokenizer

    private enum Token { case command(Character), number(Double) }

    private static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let pattern = #"([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(d.startIndex..., in: d)
        re.enumerateMatches(in: d, range: range) { m, _, _ in
            guard let m = m, let r = Range(m.range, in: d) else { return }
            let s = String(d[r])
            if let c = s.first, c.isLetter { tokens.append(.command(c)) }
            else if let v = Double(s) { tokens.append(.number(v)) }
        }
        return tokens
    }
}
