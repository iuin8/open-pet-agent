import Testing
import SwiftUI
@testable import Shell

@Suite("SVGPathParser")
struct SVGPathParserTests {
    @Test("空字符串 → 空 path")
    func empty() {
        let path = SVGPathParser.parse("", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty)
    }

    @Test("M L L Z → 三角形,boundingRect 覆盖三个顶点")
    func triangle() {
        let path = SVGPathParser.parse("M0 0 L24 0 L12 24 Z", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.minX == 0)
        #expect(bb.maxX == 24)
        #expect(bb.minY == 0)
        #expect(bb.maxY == 24)
    }

    @Test("相对命令 m l 等价绝对 M L(同 boundingRect)")
    func relativeEqualsAbsolute() {
        let abs = SVGPathParser.parse("M0 0 L24 0 L24 24 Z", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        let rel = SVGPathParser.parse("m0 0 l24 0 l0 24 z", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(abs.boundingRect == rel.boundingRect)
    }

    @Test("H V 命令画矩形")
    func hRect() {
        let path = SVGPathParser.parse("M0 0 H24 V24 H0 Z", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        let bb = path.boundingRect
        #expect(bb.width == 24)
        #expect(bb.height == 24)
    }

    @Test("缩放到非 24×24 rect(viewBox 24 → 输出 48)")
    func scaleToRect() {
        let path = SVGPathParser.parse("M0 0 H24 V24 Z", in: CGRect(x: 0, y: 0, width: 48, height: 48))
        let bb = path.boundingRect
        #expect(bb.width == 48)
        #expect(bb.height == 48)
    }

    @Test("cubic bezier C 命令生成非空 path")
    func cubicBezier() {
        let path = SVGPathParser.parse("M0 0 C0 12 12 24 24 24", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.maxX == 24)
        #expect(bb.maxY == 24)
    }

    @Test("arc 命令(半圆)生成覆盖宽度的 path")
    func arcHalfCircle() {
        // M0 12 A12 12 0 0 1 24 12 —— 半径 12,从 (0,12) 到 (24,12) 的上半圆
        let path = SVGPathParser.parse("M0 12 A12 12 0 0 1 24 12", in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.minX == 0)
        #expect(bb.maxX == 24)
    }

    @Test("Claude 品牌 logo path 渲染非空 + 覆盖大部分 viewBox")
    func claudeLogoRenders() {
        let path = SVGPathParser.parse(BrandLogo.claude.pathData, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.width > 20)
        #expect(bb.height > 20)
    }

    @Test("OpenAI(Codex)品牌 logo path 渲染非空 + 覆盖大部分 viewBox")
    func codexLogoRenders() {
        let path = SVGPathParser.parse(BrandLogo.codex.pathData, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.width > 20)
        #expect(bb.height > 20)
    }

    @Test("BrandLogoShape 渲染(15×15 rect 内非空)")
    func shapeRenders() {
        let shape = BrandLogoShape(logo: .claude)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 15, height: 15))
        #expect(path.isEmpty == false)
        let bb = path.boundingRect
        #expect(bb.width > 12)
        #expect(bb.height > 12)
    }
}
