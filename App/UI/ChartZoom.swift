import SwiftUI
import Charts

// 通用：给曲线图加「双指放大缩小、放大后单指左右拖」
// 用法：Chart { … }.chartZoom(dates: 开始...结束) 或 .chartZoom(numbers: 0...40)
// 没放大时图表和原来一模一样；放大后左上角出现「还原」，期间页面不会左右翻页

struct ChartZoom: ViewModifier {
    let lo: Double
    let hi: Double
    let dates: Bool
    let minSpan: Double
    var fixed = false     // 没放大时也固定显示整个范围（原来就写死了横轴范围的图用）

    @State private var span: Double?          // nil = 没放大
    @State private var end: Double = 0
    @State private var pinchFrom: Double?
    @State private var dragFrom: Double?
    @State private var width: CGFloat = 300

    private var full: Double { max(hi - lo, 0.000_001) }
    private var zoomed: Bool { span != nil }

    private var window: (Double, Double) {
        guard let s = span else { return (lo, hi) }
        let e = min(max(end, lo + s), hi)
        return (e - s, e)
    }

    func body(content: Content) -> some View {
        scaled(content)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in pinch(v.magnification) }
                    .onEnded { _ in pinchFrom = nil }
            )
            .horizontalPan(enabled: zoomed, changed: pan, ended: { dragFrom = nil })
            .background(DisableTabPaging(active: zoomed || pinchFrom != nil).frame(width: 0, height: 0))
            .overlay(alignment: .topLeading) {
                if zoomed {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { span = nil }
                    } label: {
                        Label("还原", systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
            }
            .onChange(of: lo) { _, _ in span = nil }
            .onChange(of: hi) { _, _ in span = nil }
    }

    @ViewBuilder
    private func scaled(_ content: Content) -> some View {
        if !zoomed && !fixed {
            content
        } else if dates {
            let w = window
            content
                .chartXScale(domain: Date(timeIntervalSinceReferenceDate: w.0)...Date(timeIntervalSinceReferenceDate: w.1))
                .chartPlotStyle { $0.clipped() }
        } else {
            let w = window
            content
                .chartXScale(domain: w.0...w.1)
                .chartPlotStyle { $0.clipped() }
        }
    }

    private func pinch(_ scale: CGFloat) {
        let cur = span ?? full
        if pinchFrom == nil {
            pinchFrom = cur
            if span == nil { end = hi }
        }
        let center = window.1 - cur / 2
        let ns = min(max(pinchFrom! / Double(max(scale, 0.05)), min(minSpan, full)), full)
        if ns >= full * 0.98 { span = nil; return }
        span = ns
        end = min(max(center + ns / 2, lo + ns), hi)
    }

    private func pan(_ dx: CGFloat) {
        guard let s = span else { return }
        if dragFrom == nil { dragFrom = window.1 }
        let e = dragFrom! - Double(dx / max(width - 40, 100)) * s
        end = min(max(e, lo + s), hi)
    }
}

extension View {
    /// 横轴是日期的图：full = 整个数据范围；最小能放大到 minDays 天
    func chartZoom(dates full: ClosedRange<Date>, minDays: Double = 3, fixed: Bool = false) -> some View {
        modifier(ChartZoom(lo: full.lowerBound.timeIntervalSinceReferenceDate,
                           hi: full.upperBound.timeIntervalSinceReferenceDate,
                           dates: true, minSpan: minDays * 86400, fixed: fixed))
    }

    /// 横轴是数字的图
    func chartZoom(numbers full: ClosedRange<Double>, minFraction: Double = 0.1, fixed: Bool = false) -> some View {
        modifier(ChartZoom(lo: full.lowerBound, hi: full.upperBound, dates: false,
                           minSpan: (full.upperBound - full.lowerBound) * minFraction, fixed: fixed))
    }
}

/// 一组日期的范围（前后各留一点空），给 chartZoom 用
func zoomRange(_ ds: [Date], padDays: Double = 0.6) -> ClosedRange<Date> {
    let a = ds.min() ?? Date().addingTimeInterval(-7 * 86400)
    let b = ds.max() ?? Date()
    let pad = padDays * 86400
    return a.addingTimeInterval(-pad)...max(b.addingTimeInterval(pad), a.addingTimeInterval(pad + 86400))
}

func zoomRange(_ xs: [Double]) -> ClosedRange<Double> {
    let a = xs.min() ?? 0
    let b = xs.max() ?? 1
    let pad = max((b - a) * 0.05, 0.5)
    return (a - pad)...(b + pad)
}
