import SwiftUI

/// The pro readout row — 对焦 / 白平衡 / 曝光 / ISO / 快门 — each showing its current value (grey "自动"
/// when automatic, orange when manual). Tapping a readout reveals its slider. Mirrors the reference
/// camera's bottom control strip.
struct ManualControlPanel: View {
    @ObservedObject var vm: CameraViewModel
    @State private var active: ProControl?

    enum ProControl: String, CaseIterable, Identifiable {
        case focus = "对焦", wb = "白平衡", ev = "曝光", iso = "ISO", shutter = "快门"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 12) {
            if let active { sliderRow(for: active).transition(.opacity) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(ProControl.allCases) { readout($0) }
                    lockButton
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: Readouts

    private func readout(_ c: ProControl) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { active = (active == c ? nil : c) }
        } label: {
            VStack(spacing: 2) {
                Text(c.rawValue).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                Text(value(for: c))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isManual(c) ? Color.rawloomAccent : .white.opacity(0.55))
            }
            .frame(minWidth: 44)
            .overlay(alignment: .bottom) {
                if active == c { Capsule().fill(Color.rawloomAccent).frame(width: 22, height: 2).offset(y: 6) }
            }
        }
    }

    private var lockButton: some View {
        Button { vm.toggleAEAFLock() } label: {
            Image(systemName: vm.exposureFocusLocked ? "lock.fill" : "lock.open")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(vm.exposureFocusLocked ? Color.rawloomAccent : .white.opacity(0.8))
                .frame(width: 40, height: 40)
        }
    }

    // MARK: Slider

    @ViewBuilder
    private func sliderRow(for c: ProControl) -> some View {
        HStack(spacing: 10) {
            switch c {
            case .ev:
                slider(Binding(get: { vm.ev }, set: { vm.setEV($0) }), in: vm.manualCaps.evRange)
            case .iso:
                logSlider(value: vm.iso, range: vm.manualCaps.isoRange) { vm.iso = $0; vm.applyManualExposure() }
            case .shutter:
                logSliderD(value: vm.shutter, range: vm.manualCaps.shutterRange) { vm.shutter = $0; vm.applyManualExposure() }
            case .wb:
                slider(Binding(get: { vm.kelvin }, set: { vm.setKelvin($0) }), in: vm.manualCaps.kelvinRange)
            case .focus:
                slider(Binding(get: { vm.lensPosition }, set: { vm.setLensPosition($0) }), in: 0...1)
            }
            Button("自动") { reset(c) }
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private func slider(_ value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        Slider(value: value, in: range).tint(Color.rawloomAccent)
    }

    private func logSlider(value: Float, range: ClosedRange<Float>, apply: @escaping (Float) -> Void) -> some View {
        let lo = max(range.lowerBound, 1e-6), hi = range.upperBound
        let t = Binding<Float>(get: { Float(min(max(log(value / lo) / log(hi / lo), 0), 1)) },
                               set: { apply(lo * pow(hi / lo, $0)) })
        return Slider(value: t, in: 0...1).tint(Color.rawloomAccent)
    }

    private func logSliderD(value: Double, range: ClosedRange<Double>, apply: @escaping (Double) -> Void) -> some View {
        let lo = max(range.lowerBound, 1e-9), hi = range.upperBound
        let t = Binding<Double>(get: { min(max(log(value / lo) / log(hi / lo), 0), 1) },
                                set: { apply(lo * pow(hi / lo, $0)) })
        return Slider(value: t, in: 0...1).tint(Color.rawloomAccent)
    }

    // MARK: Formatting / state

    private func value(for c: ProControl) -> String {
        switch c {
        case .focus:   return vm.focusManual ? String(format: "%.2f", vm.lensPosition) : "自动"
        case .wb:      return vm.wbManual ? "\(Int(vm.kelvin))K" : "自动"
        case .ev:      return abs(vm.ev) < 0.05 ? "自动" : String(format: "%+.1f", vm.ev)
        case .iso:     return vm.exposureManual ? String(format: "%.0f", vm.iso) : "自动"
        case .shutter: return vm.exposureManual ? shutterLabel : "自动"
        }
    }

    private var shutterLabel: String {
        vm.shutter >= 1 ? String(format: "%.1fs", vm.shutter) : "1/\(Int((1 / vm.shutter).rounded()))"
    }

    private func isManual(_ c: ProControl) -> Bool {
        switch c {
        case .focus:          return vm.focusManual
        case .wb:             return vm.wbManual
        case .ev:             return abs(vm.ev) > 0.01
        case .iso, .shutter:  return vm.exposureManual
        }
    }

    private func reset(_ c: ProControl) {
        switch c {
        case .focus:              vm.resetFocus()
        case .wb:                 vm.resetWhiteBalance()
        case .ev, .iso, .shutter: vm.resetExposure()
        }
    }
}
