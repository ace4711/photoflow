import AppKit
import Vision

/// Uses Apple Vision's on-device classifier to tag real estate photos
/// with scene/room categories and generate descriptions.
actor VisionTaggingService {
    static let shared = VisionTaggingService()

    // MARK: - Real estate tag mapping

    /// Maps Apple Vision classifier labels to Swedish real estate tags.
    /// Vision returns English taxonomy labels — we map relevant ones to our categories.
    private let tagMapping: [String: String] = [
        // Rooms
        "kitchen": "Kök",
        "bathroom": "Badrum",
        "bedroom": "Sovrum",
        "living_room": "Vardagsrum",
        "dining_room": "Matplats",
        "laundry_room": "Tvättstuga",
        "home_office": "Kontor",
        "nursery": "Barnrum",
        "closet": "Garderob",
        "attic": "Vind",
        "basement": "Källare",
        "garage": "Garage",
        "corridor": "Hall",
        "hallway": "Hall",
        "entrance": "Entré",
        "staircase": "Trappa",
        "stairs": "Trappa",

        // Outdoor / Building
        "building": "Fasad",
        "house": "Villa",
        "apartment_building": "Lägenhet",
        "facade": "Fasad",
        "balcony": "Balkong",
        "patio": "Uteplats",
        "terrace": "Terrass",
        "deck": "Altan",
        "porch": "Veranda",
        "garden": "Trädgård",
        "yard": "Tomt",
        "lawn": "Gräsmatta",
        "swimming_pool": "Pool",
        "pool": "Pool",
        "driveway": "Uppfart",
        "parking": "Parkering",

        // Features
        "fireplace": "Öppen spis",
        "sauna": "Bastu",
        "shower": "Dusch",
        "bathtub": "Badkar",
        "toilet": "Toalett",
        "sink": "Handfat",
        "oven": "Ugn",
        "stove": "Spis",
        "refrigerator": "Kylskåp",
        "dishwasher": "Diskmaskin",
        "bookshelf": "Bokhylla",
        "door": "Dörr",

        // Scene types
        "outdoor": "Exteriör",
        "indoor": "Interiör",
        "interior": "Interiör",
        "exterior": "Exteriör",
        "landscape": "Utsikt",
        "sky": "Utsikt",
        "tree": "Trädgård",
        "flower": "Trädgård",
        "plant": "Växter",
    ]

    /// Higher-level categories to group tags
    private let categoryGroups: [String: [String]] = [
        "Exteriör": ["Fasad", "Villa", "Lägenhet", "Balkong", "Uteplats", "Terrass", "Altan", "Veranda", "Trädgård", "Tomt", "Gräsmatta", "Pool", "Uppfart", "Parkering", "Utsikt"],
        "Interiör": ["Kök", "Badrum", "Sovrum", "Vardagsrum", "Matplats", "Kontor", "Barnrum", "Garderob", "Hall", "Entré", "Trappa", "Vind", "Källare"],
    ]

    // MARK: - Classification

    struct PhotoTags {
        let tags: [String]           // Swedish real estate tags
        let description: String      // Generated description
        let primaryCategory: String  // "Exteriör" or "Interiör"
        let confidence: Double       // Overall confidence
        let rawLabels: [(String, Double)] // Raw Vision labels with confidence
    }

    /// Classify a photo and return real estate tags.
    /// Vision's perform() is synchronous and blocks the calling thread, so we
    /// dispatch it to a GCD thread to avoid starving Swift's cooperative pool.
    func tagPhoto(at url: URL) async -> PhotoTags? {
        guard let cgImage = loadCGImage(from: url) else { return nil }

        let results: [VNClassificationObservation]? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results)
                } catch {
                    print("Vision classification failed: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let results else { return nil }

        // Filter to observations with meaningful confidence
        let significant = results.filter { $0.confidence > 0.1 }
            .sorted { $0.confidence > $1.confidence }

        // Map to Swedish real estate tags
        var tags: [String] = []
        var rawLabels: [(String, Double)] = []
        var topConfidence: Double = 0

        for obs in significant.prefix(20) {
            let label = obs.identifier.lowercased()
            let confidence = Double(obs.confidence)
            rawLabels.append((obs.identifier, confidence))

            if topConfidence == 0 { topConfidence = confidence }

            // Tags that require high confidence (must dominate the image)
            if label.contains("window") && confidence >= 0.5 && !tags.contains("Fönster") {
                tags.append("Fönster")
                continue
            }

            // Direct match
            if let tag = tagMapping[label], !tags.contains(tag) {
                tags.append(tag)
                continue
            }

            // Partial match (label contains key or key contains label)
            for (key, tag) in tagMapping {
                if (label.contains(key) || key.contains(label)) && !tags.contains(tag) {
                    tags.append(tag)
                    break
                }
            }
        }

        // Determine primary category
        let primaryCategory = determinePrimaryCategory(tags: tags, rawLabels: rawLabels)

        // Add primary category if not already present
        if !tags.contains(primaryCategory) {
            tags.insert(primaryCategory, at: 0)
        }

        // Generate description
        let description = generateDescription(tags: tags, primaryCategory: primaryCategory)

        return PhotoTags(
            tags: tags,
            description: description,
            primaryCategory: primaryCategory,
            confidence: topConfidence,
            rawLabels: rawLabels
        )
    }

    /// Batch-tag multiple photos in parallel. Returns dictionary of filename -> tags.
    func tagPhotos(urls: [(filename: String, url: URL)], progress: @Sendable @MainActor (Int, Int, String, PhotoTags?) -> Void) async -> [String: PhotoTags] {
        let total = urls.count
        let maxConcurrent = min(ProcessInfo.processInfo.activeProcessorCount, 8)

        // Use TaskGroup for parallel Vision classification
        let tagResults = await withTaskGroup(of: (String, PhotoTags?).self, returning: [(String, PhotoTags?)].self) { group in
            var inFlight = 0
            var collected: [(String, PhotoTags?)] = []
            collected.reserveCapacity(total)

            for item in urls {
                if inFlight >= maxConcurrent {
                    if let result = await group.next() {
                        collected.append(result)
                        await progress(collected.count, total, result.0, result.1)
                    }
                    inFlight -= 1
                }

                group.addTask {
                    let tags = await self.tagPhoto(at: item.url)
                    return (item.filename, tags)
                }
                inFlight += 1
            }

            for await result in group {
                collected.append(result)
                await progress(collected.count, total, result.0, result.1)
            }

            return collected
        }

        var results: [String: PhotoTags] = [:]
        for (filename, tags) in tagResults {
            if let tags {
                results[filename] = tags
            }
        }
        return results
    }

    // MARK: - Helpers

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func determinePrimaryCategory(tags: [String], rawLabels: [(String, Double)]) -> String {
        // Check if tags lean toward exterior or interior
        let exteriorTags = categoryGroups["Exteriör"] ?? []
        let interiorTags = categoryGroups["Interiör"] ?? []

        let extCount = tags.filter { exteriorTags.contains($0) }.count
        let intCount = tags.filter { interiorTags.contains($0) }.count

        if extCount > intCount { return "Exteriör" }
        if intCount > extCount { return "Interiör" }

        // Check raw labels for outdoor/indoor hints
        for (label, conf) in rawLabels where conf > 0.2 {
            let l = label.lowercased()
            if l.contains("outdoor") || l.contains("building") || l.contains("house") || l.contains("sky") || l.contains("tree") {
                return "Exteriör"
            }
            if l.contains("indoor") || l.contains("room") || l.contains("kitchen") || l.contains("bath") {
                return "Interiör"
            }
        }

        return "Interiör"
    }

    private func generateDescription(tags: [String], primaryCategory: String) -> String {
        let roomTags = tags.filter { tag in
            let rooms = ["Kök", "Badrum", "Sovrum", "Vardagsrum", "Matplats", "Tvättstuga", "Kontor", "Barnrum", "Hall", "Entré", "Trappa"]
            return rooms.contains(tag)
        }

        let featureTags = tags.filter { tag in
            let features = ["Öppen spis", "Bastu", "Balkong", "Uteplats", "Terrass", "Altan", "Pool", "Trädgård"]
            return features.contains(tag)
        }

        var parts: [String] = []

        if primaryCategory == "Exteriör" {
            if tags.contains("Fasad") {
                parts.append("Fasadbild")
            } else if tags.contains("Trädgård") || tags.contains("Tomt") {
                parts.append("Trädgård/tomt")
            } else if tags.contains("Balkong") {
                parts.append("Balkong")
            } else if tags.contains("Utsikt") {
                parts.append("Utsikt")
            } else {
                parts.append("Exteriör")
            }
        } else {
            if let room = roomTags.first {
                parts.append(room)
            } else {
                parts.append("Interiör")
            }
        }

        if !featureTags.isEmpty {
            parts.append("med " + featureTags.prefix(2).joined(separator: " och ").lowercased())
        }

        return parts.joined(separator: " ")
    }
}
