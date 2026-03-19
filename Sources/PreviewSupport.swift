#if DEBUG
import SwiftUI

extension AppState {
    static func previewState(
        selectedTab: SettingsTab = .general,
        includeDebugData: Bool = true,
        needsPermissions: Bool = false
    ) -> AppState {
        let state = AppState(runtimeMode: .preview)
        state.hasCompletedSetup = true
        state.selectedSettingsTab = selectedTab
        state.apiKey = "preview-key"
        state.apiBaseURL = "https://api.groq.com/openai/v1"
        state.customVocabulary = "FreeFlow, Groq, Whisper"
        state.shortcutStartDelay = 0.1
        state.preserveClipboard = true
        state.launchAtLogin = false
        state.hasAccessibility = !needsPermissions
        state.hasScreenRecordingPermission = !needsPermissions
        state.availableMicrophones = [
            AudioDevice(id: 1, uid: "preview-mic", name: "Studio Display Microphone"),
            AudioDevice(id: 2, uid: "preview-usb", name: "USB Audio Interface")
        ]
        state.selectedMicrophoneID = state.availableMicrophones.first?.uid ?? "default"

        if includeDebugData {
            state.debugStatusMessage = "Preview pipeline ready"
            state.lastPostProcessingStatus = "Post-processing succeeded"
            state.lastContextSummary = "Drafting release notes for the rebranded FreeFlow app."
            state.lastRawTranscript = "ship the new signed build from main"
            state.lastPostProcessedTranscript = "Ship the new signed FreeFlow build from main."
            state.lastPostProcessingPrompt = "Convert the rough dictation into polished release notes copy."
            state.lastContextScreenshotStatus = "No screenshot for preview"
            state.statusText = "Ready"
            state.lastTranscript = "Ship the new signed FreeFlow build from main."
        }

        return state
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(AppState.previewState(selectedTab: .general))
            .frame(width: 900, height: 620)
    }
}

struct SetupView_Previews: PreviewProvider {
    static var previews: some View {
        SetupView(onComplete: {})
            .environmentObject(AppState.previewState(needsPermissions: true))
            .frame(width: 520, height: 620)
    }
}

struct MenuBarView_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarView()
            .environmentObject(AppState.previewState())
            .frame(width: 320)
    }
}

struct PipelineDebugPanelView_Previews: PreviewProvider {
    static var previews: some View {
        PipelineDebugPanelView()
            .environmentObject(AppState.previewState(selectedTab: .runLog))
    }
}
#endif
