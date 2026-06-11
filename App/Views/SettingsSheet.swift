import SwiftUI
import RawloomCore

/// Settings panel behind the gear: capture options + viewfinder aids in one place.
struct SettingsSheet: View {
    @ObservedObject var vm: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Capture") {
                    Picker("Mode", selection: $vm.mode) {
                        Text("Photo").tag(CaptureMode.photo)
                        Text("Night").tag(CaptureMode.night)
                    }
                    Picker("Aspect ratio", selection: $vm.aspect) {
                        ForEach(AspectRatio.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Flash", selection: $vm.flashMode) {
                        ForEach(FlashMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Format", selection: formatBinding) {
                        ForEach(OutputFormat.presets, id: \.rawValue) { Text($0.label).tag($0.label) }
                        if vm.proRAWSupported { Text("ProRAW").tag("ProRAW") }
                    }
                }
                Section("Viewfinder") {
                    Toggle("Grid", isOn: $vm.showGrid)
                    Toggle("Level", isOn: Binding(get: { vm.showLevel }, set: { _ in vm.toggleLevel() }))
                    Toggle("Histogram", isOn: Binding(get: { vm.showHistogram }, set: { _ in vm.toggleHistogram() }))
                }
                Section {
                    LabeledContent("Lenses", value: vm.lenses.isEmpty ? "—" : vm.lenses.map(\.label).joined(separator: " · "))
                    LabeledContent("ProRAW", value: vm.proRAWSupported ? "Supported" : "—")
                } header: { Text("Device") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    /// Bridges the format Picker (string tags) to the view-model's format/ProRAW state.
    private var formatBinding: Binding<String> {
        Binding(
            get: { vm.proRAWMode ? "ProRAW" : vm.outputFormat.label },
            set: { label in
                if label == "ProRAW" { vm.proRAWMode = true }
                else if let fmt = OutputFormat.presets.first(where: { $0.label == label }) {
                    vm.proRAWMode = false; vm.outputFormat = fmt
                }
            })
    }
}
