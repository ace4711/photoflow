import SwiftUI
import MapKit
import CoreLocation

struct AddressBanner: View {
    @EnvironmentObject var pipeline: PipelineState
    @EnvironmentObject var runner: RunnerWrapper

    private var settings: AppSettings { AppSettings.shared }

    @State private var correctionTarget: CorrectionTarget?

    /// Fas 4 (kvarstående från Fas 1b): satt efter en adressrättning om filer
    /// redan hunnit sorteras under den GAMLA adressen — visar en fråga/knapp
    /// för att döpa om de befintliga mapparna i stället för att tyst lämna
    /// dem kvar under fel namn.
    @State private var pendingResort: PendingResort?

    /// Stockholm center for distance calculation
    private static let stockholmCenter = CLLocation(latitude: 59.3293, longitude: 18.0686)

    var body: some View {
        if settings.calendarMatchEnabled {
            if !pipeline.allMatchedAddresses.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(pipeline.allMatchedAddresses.enumerated()), id: \.offset) { index, match in
                        addressRow(match: match, index: index)
                    }
                    if let pendingResort {
                        resortBanner(pendingResort)
                    }
                }
                .sheet(item: $correctionTarget) { target in
                    AddressCorrectionView(
                        originalAddress: target.address,
                        eventTitle: target.eventTitle,
                        index: target.index,
                        onSave: { correctedAddress, coordinate in
                            let oldAddress = target.address
                            pipeline.correctAddress(at: target.index, newAddress: correctedAddress, coordinate: coordinate)
                            // Fix the folder-naming source of truth immediately — without
                            // this, calendarMappings kept pointing at the old address until
                            // the calendar step was fully re-run (see
                            // PipelineRunner+AddressCorrection.swift).
                            runner.runner?.updateCalendarMappingAddress(from: oldAddress, to: correctedAddress)
                            if oldAddress != correctedAddress,
                               runner.runner?.addressFolderAlreadySorted(oldAddress) == true {
                                pendingResort = PendingResort(oldAddress: oldAddress, newAddress: correctedAddress)
                            }
                            correctionTarget = nil
                        }
                    )
                }
            } else if pipeline.matchedAddress != nil {
                addressRow(
                    match: (address: pipeline.matchedAddress!, eventTitle: pipeline.matchedEventTitle ?? "", hasGPS: true, coordinate: nil),
                    index: 0
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text("Adress ej funnen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Distance helpers

    private func distanceFromStockholm(_ coordinate: CLLocationCoordinate2D?) -> Double? {
        guard let coordinate else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return location.distance(from: Self.stockholmCenter) / 1000.0 // km
    }

    private func distanceText(_ km: Double) -> String {
        if km < 1 {
            return "< 1 km"
        } else if km < 10 {
            return String(format: "%.1f km", km)
        } else {
            return "\(Int(km)) km"
        }
    }

    private func rowColor(hasGPS: Bool, coordinate: CLLocationCoordinate2D?) -> Color {
        guard hasGPS else { return Color.red.opacity(0.75) }
        if let dist = distanceFromStockholm(coordinate), dist > 50 {
            return Color.orange.opacity(0.85)
        }
        return Color.green.opacity(0.85)
    }

    // MARK: - Row

    @ViewBuilder
    private func addressRow(match: (address: String, eventTitle: String, hasGPS: Bool, coordinate: CLLocationCoordinate2D?), index: Int) -> some View {
        let distance = distanceFromStockholm(match.coordinate)
        let bgColor = rowColor(hasGPS: match.hasGPS, coordinate: match.coordinate)

        HStack(spacing: 8) {
            // Map pin indicator
            Image(systemName: match.hasGPS ? "mappin.circle.fill" : "mappin.slash.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(.white)

            Text(match.address)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)

            if match.eventTitle != match.address && !match.eventTitle.isEmpty {
                Text("·")
                    .foregroundColor(.white.opacity(0.6))
                Text(match.eventTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            // Distance from Stockholm
            if let distance {
                HStack(spacing: 3) {
                    Image(systemName: distance > 50 ? "exclamationmark.triangle.fill" : "location.fill")
                        .font(.system(size: 10))
                    Text(distanceText(distance))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .foregroundColor(distance > 50 ? .yellow : .white.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(distance > 50 ? 0.2 : 0.1))
                )
                .help(distance > 50 ? "Långt från Stockholm — kontrollera att adressen stämmer" : "Avstånd från Stockholms centrum")
            } else if !match.hasGPS {
                Text("Ingen GPS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
            }

            // Edit button — always available for shortening/correcting address
            Button {
                correctionTarget = CorrectionTarget(
                    index: index,
                    address: match.address,
                    eventTitle: match.eventTitle
                )
            } label: {
                Text("Ändra")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(bgColor == Color.green.opacity(0.85) ? Color(red: 0.1, green: 0.4, blue: 0.1) : Color(red: 0.6, green: 0.1, blue: 0.1))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.9))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(bgColor)
        )
    }
}

// MARK: - Correction Target

private struct CorrectionTarget: Identifiable {
    let id = UUID()
    let index: Int
    let address: String
    let eventTitle: String
}

// MARK: - Resort-after-correction banner (Fas 4)

private struct PendingResort {
    let oldAddress: String
    let newAddress: String
}

extension AddressBanner {
    /// "Sortera om filerna till den nya adressmappen"-frågan som visas efter
    /// en adressrättning när filer redan hann sorteras under det gamla
    /// namnet — döper om de tre adressmapparna (`AddressFolderLayout`) i
    /// `PipelineRunner.resortAddressFolder`. Rör aldrig filsystemet förrän
    /// användaren uttryckligen trycker knappen.
    fileprivate func resortBanner(_ resort: PendingResort) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundColor(.white)
            Text("Filer är redan sorterade under \"\(resort.oldAddress)\".")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            Spacer()
            Button {
                _ = runner.runner?.resortAddressFolder(from: resort.oldAddress, to: resort.newAddress)
                pendingResort = nil
            } label: {
                Text("Sortera om filerna till den nya adressmappen")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.1, green: 0.3, blue: 0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.9)))
            }
            .buttonStyle(.plain)
            Button {
                pendingResort = nil
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Låt filerna ligga kvar under det gamla mappnamnet")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.85)))
    }
}

// MARK: - Identifiable Map Item wrapper

private struct IdentifiableMapItem: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
    // `.placemark` deprecated macOS 26.0 (Fas 3c) — `.location`/`.address`
    // are the non-deprecated replacements (verifierat i SDK:n,
    // `MKMapItem.h`). `.address?.fullAddress` is the closest equivalent to
    // the old `.placemark.title` (a full, formatted address string).
    var coordinate: CLLocationCoordinate2D { mapItem.location.coordinate }
    var name: String? { mapItem.name }
    var title: String? { mapItem.address?.fullAddress }
}

// MARK: - Address Correction View

struct AddressCorrectionView: View {
    let originalAddress: String
    let eventTitle: String
    let index: Int
    let onSave: (String, CLLocationCoordinate2D) -> Void

    @State private var editedAddress: String
    @State private var searchResults: [IdentifiableMapItem] = []
    @State private var selectedID: UUID?
    @State private var cameraPosition: MapCameraPosition
    @State private var isSearching = false
    @Environment(\.dismiss) private var dismiss

    private var selectedResult: IdentifiableMapItem? {
        searchResults.first { $0.id == selectedID }
    }

    init(originalAddress: String, eventTitle: String, index: Int, onSave: @escaping (String, CLLocationCoordinate2D) -> Void) {
        self.originalAddress = originalAddress
        self.eventTitle = eventTitle
        self.index = index
        self.onSave = onSave
        _editedAddress = State(initialValue: originalAddress)
        _cameraPosition = State(initialValue: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 59.33, longitude: 18.07),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Ändra adress")
                    .font(.headline)
                Spacer()
                Button("Avbryt") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Address editing
            HStack(spacing: 8) {
                TextField("Adress", text: $editedAddress)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { searchAddress() }

                Button("Sök") { searchAddress() }
                    .disabled(editedAddress.isEmpty || isSearching)
            }
            .padding()

            // Map
            Map(position: $cameraPosition) {
                ForEach(searchResults) { item in
                    Annotation(item.name ?? "", coordinate: item.coordinate) {
                        Image(systemName: item.id == selectedID ? "mappin.circle.fill" : "mappin.circle")
                            .font(.system(size: item.id == selectedID ? 28 : 22))
                            .foregroundColor(item.id == selectedID ? .green : .red)
                            .onTapGesture {
                                selectedID = item.id
                                editedAddress = item.name ?? editedAddress
                            }
                    }
                }
            }
            .frame(minHeight: 300)

            // Search results list
            if !searchResults.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(searchResults) { item in
                            Button {
                                selectedID = item.id
                                editedAddress = item.name ?? editedAddress
                                cameraPosition = .region(MKCoordinateRegion(
                                    center: item.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                                ))
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? "Okänd plats")
                                            .font(.system(size: 13, weight: .medium))
                                        if let subtitle = item.title {
                                            Text(subtitle)
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if item.id == selectedID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(item.id == selectedID ? Color.green.opacity(0.1) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 150)
            }

            Divider()

            // Save button
            HStack {
                Spacer()
                Button("Spara") {
                    guard let selected = selectedResult else { return }
                    onSave(editedAddress, selected.coordinate)
                }
                .disabled(selectedResult == nil)
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding()
        }
        .frame(width: 550, height: 600)
        .onAppear {
            searchAddress()
        }
    }

    private func searchAddress() {
        guard !editedAddress.isEmpty else { return }
        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = editedAddress.contains("Sverige") ? editedAddress : "\(editedAddress), Sverige"
        request.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 59.33, longitude: 18.07),
            span: MKCoordinateSpan(latitudeDelta: 5, longitudeDelta: 5)
        )

        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            isSearching = false
            guard let response else { return }
            searchResults = response.mapItems.prefix(5).map { IdentifiableMapItem(mapItem: $0) }
            if let first = searchResults.first {
                selectedID = first.id
                cameraPosition = .region(MKCoordinateRegion(
                    center: first.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        }
    }
}
