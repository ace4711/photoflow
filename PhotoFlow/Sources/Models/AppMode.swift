import Foundation

enum AppMode: Equatable {
    case launcher        // Startup: pick mode
    case watching        // Watching for new files / SD cards
    case processing      // Running the pipeline
    case interactive     // Manual review / culling
}
