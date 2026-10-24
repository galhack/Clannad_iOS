import AVFoundation
import SwiftUI

@main
struct ClannadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = GameLibrary()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The engine draws its own flower-shaped in-game cursor; hide it on
        // every platform.  The platform pointer (Mac) and touches (iOS,
        // visionOS) are unaffected.  Set before the engine is created.
        setenv("SIGLUS_HIDE_MOUSE_CURSOR", "1", 1)
        Self.configureAudio()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(library.transfer)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshIfIdle()
            }
        }
        #if os(visionOS)
        .defaultSize(width: 1280, height: 900)
        #endif
    }

    /// Game sound plays even with the silent switch on, and comes back after a
    /// call or another interruption.
    private static func configureAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
}

/// Lets the launcher rotate freely while the player forces landscape.  The
/// window asks its application delegate for the mask whenever it changes.
final class OrientationController {
    static let shared = OrientationController()
    var lockedToLandscape = false

    var mask: UIInterfaceOrientationMask {
        lockedToLandscape ? .landscape : .all
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationController.shared.mask
    }
}

struct RootView: View {
    @EnvironmentObject private var library: GameLibrary

    var body: some View {
        if let session = library.session {
            PlayerScreen(session: session) {
                library.stopPlayback()
            }
        } else {
            LauncherView()
        }
    }
}
