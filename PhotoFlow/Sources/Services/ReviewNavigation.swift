import Foundation

/// Rena hjälpfunktioner för navigering i granska-läget.
nonisolated enum ReviewNavigation {
    /// Index för nästa grupp som inte är färdiggranskad, med wrap-around.
    /// `reviewed[i]` är sant när grupp i är klar. Returnerar nil om alla är granskade
    /// (eller listan är tom). `direction` är +1 eller -1.
    static func nextUnreviewed(from current: Int, reviewed: [Bool], direction: Int = 1) -> Int? {
        let n = reviewed.count
        guard n > 0, direction != 0 else { return nil }
        let step = direction > 0 ? 1 : -1
        for offset in 1...n {
            let idx = (((current + step * offset) % n) + n) % n
            if !reviewed[idx] { return idx }
        }
        return nil
    }

    /// Index som ska förhämtas runt `current` (nästa först, sedan föregående), inom gränserna.
    static func prefetchNeighbors(of current: Int, count: Int, radius: Int = 2) -> [Int] {
        guard count > 0, radius > 0 else { return [] }
        var result: [Int] = []
        for d in 1...radius {
            if current + d < count { result.append(current + d) }
            if current - d >= 0 && current - d < count { result.append(current - d) }
        }
        return result
    }

    /// "12 av 100 granskade"
    static func progressText(reviewed: Int, total: Int) -> String {
        "\(reviewed) av \(total) granskade"
    }
}
