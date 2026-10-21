import SwiftUI

@main
struct ABCStudioApp: App {
    /// モデルはアプリ側で所有し、外部からの "開く" (onOpenURL) でも使えるようにする。
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // Files/メール等からの "このアプリで開く"
                    model.importFileForDisplay(url)
                }
        }
    }
}
