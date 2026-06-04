import Foundation
import SwiftUI

// MARK: - Main View
struct MainView: View {
    @StateObject private var audioRecorder = AudioRecorder.shared
    @StateObject private var recordingsManager = RecordingsManager.shared
    @StateObject private var audioPlayer = AudioPlayer.shared

    @State private var selectedTab: AppTab = .record
    @State private var selectedRecording: RecordingItem? = nil
    @State private var selectedAnalysisId: UUID? = nil
    @State private var showAbout = false
    @State private var showLogViewer = false
    @State private var showDesignShowcase = false
    @State private var showSettings = false

    var body: some View {
        // NavigationSplitView wrapper is REQUIRED for SwiftUI's unified
        // chrome to extend content to the window's outer rounded frame.
        // See `Design/WindowChrome.swift` — bare HStack at root breaks
        // the corner-radius pipeline. The actual nav lives inside detail.
        NavigationSplitView(columnVisibility: .constant(.detailOnly)) {
            EmptyView()
        } detail: {
            HStack(spacing: 0) {
                NavPanel(
                    selectedTab: $selectedTab,
                    showAbout: $showAbout
                )
                .frame(width: 64)

                Divider()

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1100, minHeight: 700)
        .sheet(isPresented: $showAbout) {
            AboutView().presentationDetents([.large])
        }
        .sheet(isPresented: $showLogViewer) {
            PasswordGateView(isPresented: $showLogViewer)
        }
        .sheet(isPresented: $showDesignShowcase) {
            DesignShowcaseView(isPresented: $showDesignShowcase)
        }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text(AppCopy.Common.settings)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(AppCopy.Common.close) { showSettings = false }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        TranscriptionSettingsView()
                        Divider()
                            .padding(.horizontal, AppSpacing.lg)
                        LLMSettingsSection()
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowLogViewer"))) { _ in
            showLogViewer = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowDesignShowcase"))) { _ in
            showDesignShowcase = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("ClioShowSettings"))) { _ in
            showSettings = true
        }
        .onChange(of: selectedTab) { _, _ in autoSelectFirst() }
        .onChange(of: recordingsManager.recordings) { _, _ in
            if selectedTab == .recordings { autoSelectFirst() }
        }
        .onAppear { /* RecordingsManager loads on init and stays in sync via notifications */ }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .record:
            RecordingView(recorder: audioRecorder, isShowing: .constant(true))
        case .recordings:
            BibliotekScreen(
                recordingsManager: recordingsManager,
                audioPlayer: audioPlayer,
                selectedRecording: $selectedRecording
            )
        case .analyse:
            AnalyseScreen(selectedAnalysisId: $selectedAnalysisId)
        }
    }

    private func autoSelectFirst() {
        switch selectedTab {
        case .record:
            break
        case .recordings:
            if selectedRecording == nil {
                selectedRecording = recordingsManager.recordings.first
            }
        case .analyse:
            if selectedAnalysisId == nil {
                selectedAnalysisId = AnalysisStore.shared.loadAll().first?.id
            }
        }
    }
}
