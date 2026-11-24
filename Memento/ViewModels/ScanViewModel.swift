import Foundation

@Observable
@MainActor
final class ScanViewModel {

    enum Phase: String {
        case idle               = "Idle"
        case indexing           = "Indexing files"
        case readingMetadata    = "Reading metadata"
        case hashing            = "Computing checksums"
        case detectingFaces     = "Detecting faces"
        case classifying        = "Finding duplicates"
        case grouping           = "Grouping events"
        case ready              = "Ready"
        case cancelled          = "Cancelled"

        var order: Int {
            switch self {
            case .idle:            return 0
            case .indexing:        return 1
            case .readingMetadata: return 2
            case .hashing:         return 3
            case .detectingFaces:  return 4
            case .classifying:     return 5
            case .grouping:        return 6
            case .ready:           return 7
            case .cancelled:       return 8
            }
        }

        func isDone(relativeTo current: Phase) -> Bool { current.order > self.order }
    }

    var phase: Phase = .idle
    var scanProgress = MediaScanner.ScanProgress()
    var metaDone: Int = 0;  var metaTotal: Int = 0
    var hashDone: Int = 0;  var hashTotal: Int = 0
    var faceDone: Int = 0;  var faceTotal: Int = 0
    var foundItems: Int = 0
    var videoCount: Int = 0
    var noDatesCount: Int = 0
    var duplicateSetsCount: Int = 0
    /// Real read throughput measured while hashing (bytes actually read from disk).
    var mbPerSecond: Double = 0
    private(set) var measuredBytesPerSecond: Double = 0
    var hashETA: String = ""

    // Per-phase timing
    private(set) var phaseDurations: [Phase: TimeInterval] = [:]
    var currentPhaseElapsed: TimeInterval = 0
    private(set) var totalScanDuration: TimeInterval? = nil
    private(set) var phaseStartDate: Date? = nil
    private var scanStartDate: Date? = nil
    private var clockTask: Task<Void, Never>? = nil
    private var hashPhaseStart: Date? = nil

    // Results
    private(set) var items: [MediaItem] = []
    private(set) var faceClusters: [FaceCluster] = []
    /// Whether this scan includes the face phase (People mode only).
    private(set) var runsFaceDetection = false
    private(set) var classificationResult: DuplicateClassifier.Result?

    /// Everything PlanBuilder needs, kept so the plan can be rebuilt after people are named.
    private struct PlanInputs {
        let events: [MediaEvent]
        let items: [MediaItem]
        let destinationURL: URL
        let placementMode: PlacementMode
        let sourceURLs: [URL]
        let duplicateSets: [DuplicateSet]
    }
    private var planInputs: PlanInputs?

    private var scanTask: Task<Void, Never>?
    private let sleepBlocker = SleepBlocker()

    func start(
        sourceURLs: [URL],
        destinationURL: URL,
        placementMode: PlacementMode,
        rules: GroupingRules,
        knownPeople: [FaceCluster] = [],
        onPlanReady: @escaping @Sendable (OrganizationPlan) -> Void
    ) {
        scanTask = Task {
            await run(
                sourceURLs: sourceURLs,
                destinationURL: destinationURL,
                placementMode: placementMode,
                rules: rules,
                knownPeople: knownPeople,
                onPlanReady: onPlanReady
            )
        }
    }

    func cancel() { scanTask?.cancel(); clockTask?.cancel(); phase = .cancelled; sleepBlocker.end() }

    // MARK: - Pipeline

    private func run(
        sourceURLs: [URL],
        destinationURL: URL,
        placementMode: PlacementMode,
        rules: GroupingRules,
        knownPeople: [FaceCluster],
        onPlanReady: @escaping @Sendable (OrganizationPlan) -> Void
    ) async {

        // Keep the Mac awake for the duration of the scan, even if the screen
        // locks or turns off. Released on every exit path, including cancellation.
        sleepBlocker.begin(reason: "Scanning photo library")
        defer { sleepBlocker.end() }

        scanStartDate = Date()
        startClock()

        // ── Phase 1: Index ──────────────────────────────────────────────
        transition(to: .indexing)
        var rawItems: [MediaItem] = []
        let scanner = MediaScanner()
        for sourceURL in sourceURLs {
            let opts = scanOptions(from: rules)
            let stream = await scanner.scan(sourceURL: sourceURL, options: opts) { [weak self] prog in
                Task { @MainActor [weak self] in
                    self?.scanProgress = prog
                    self?.foundItems   = prog.foundItems
                }
            }
            do {
                for try await item in stream {
                    rawItems.append(item)
                    if item.mediaType == .video { videoCount += 1 }
                }
            } catch { break }
        }
        guard !Task.isCancelled else { clockTask?.cancel(); phase = .cancelled; return }

        // ── Phase 2: Metadata ──────────────────────────────────────────
        transition(to: .readingMetadata)
        metaTotal = rawItems.count
        let reader = MetadataReader()
        var enriched = await reader.readBatch(rawItems)
        if rules.dateBasis == .dateCreated {
            for i in enriched.indices {
                if let created = enriched[i].fileCreatedDate {
                    enriched[i].captureDate = created
                    enriched[i].dateSource = .filesystem
                    enriched[i].hasMissingEXIF = false
                }
            }
        }
        metaDone = enriched.count
        noDatesCount = enriched.filter { $0.hasMissingEXIF }.count
        guard !Task.isCancelled else { clockTask?.cancel(); phase = .cancelled; return }

        // ── Phase 3: Hashing ───────────────────────────────────────────
        transition(to: .hashing)
        hashTotal = enriched.count
        hashPhaseStart = Date()
        let hasher = FileHasher()
        let hashes = await hasher.hashBatch(enriched) { [weak self] done, total, bytesHashed, bytesToHash in
            guard done % 8 == 0 || done == total else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hashDone = done
                self.hashETA = self.etaString(bytesHashed: bytesHashed, bytesTotal: bytesToHash)
                if let start = self.hashPhaseStart {
                    let elapsed = Date().timeIntervalSince(start)
                    if elapsed > 0.5, bytesHashed > 0 {
                        self.measuredBytesPerSecond = Double(bytesHashed) / elapsed
                        self.mbPerSecond = self.measuredBytesPerSecond / 1_000_000
                    }
                }
                self.refreshElapsed()
            }
        }
        hashETA = ""
        var hashed = enriched
        for i in hashed.indices { hashed[i].sha256 = hashes[hashed[i].id] }
        guard !Task.isCancelled else { clockTask?.cancel(); phase = .cancelled; return }

        // Perceptual hashes for burst/lower-res detection.
        // Sliding window limits peak concurrency; nonisolated perceptualHash runs in true parallel.
        await withTaskGroup(of: (UUID, UInt64?).self) { group in
            let photoItems = hashed.filter { $0.mediaType == .photo || $0.mediaType == .rawPhoto }
            let concurrency = ProcessInfo.processInfo.activeProcessorCount
            var pHashResults: [UUID: UInt64] = [:]
            var index = 0

            func enqueue() {
                guard index < photoItems.count else { return }
                let item = photoItems[index]; index += 1
                group.addTask { (item.id, await hasher.perceptualHash(of: item.url)) }
            }

            for _ in 0..<min(concurrency, photoItems.count) { enqueue() }
            for await (id, hash) in group {
                if let hash { pHashResults[id] = hash }
                enqueue()
            }
            for i in hashed.indices {
                if let hash = pHashResults[hashed[i].id] { hashed[i].perceptualHash = hash }
            }
        }

        // ── Phase 4: Face detection ────────────────────────────────────
        runsFaceDetection = rules.needsFaceDetection
        if rules.needsFaceDetection {
            transition(to: .detectingFaces)
            let photoItems = hashed.filter { $0.mediaType == .photo || $0.mediaType == .rawPhoto }
            faceTotal = photoItems.count
            let clusterer = FaceClusterer()
            let faceResults = await clusterer.detectBatch(photoItems) { [weak self] done, total in
                guard done % 8 == 0 || done == total else { return }
                Task { @MainActor [weak self] in self?.faceDone = done; self?.refreshElapsed() }
            }
            for i in hashed.indices {
                hashed[i].faceCount = faceResults[hashed[i].id]?.faceCount ?? 0
            }
            faceClusters = await clusterer.cluster(
                items: hashed,
                faceResults: faceResults,
                matchDistance: Float(rules.faceMatchDistance),
                knownPeople: knownPeople
            )
        }
        guard !Task.isCancelled else { clockTask?.cancel(); phase = .cancelled; return }

        // ── Phase 5: Duplicate classification ─────────────────────────
        // Runs off the main actor: classify() is O(n²) over all photos and would
        // otherwise freeze the UI (this VM is @MainActor).
        transition(to: .classifying)
        let classifier = DuplicateClassifier()
        let classification = await Task.detached(priority: .userInitiated) {
            classifier.classify(items: hashed)
        }.value
        classificationResult = classification
        duplicateSetsCount = classification.allDuplicateSets.count

        // Remove quarantine candidates from the items that get organized
        let quarantineIDs = Set(
            classification.allDuplicateSets.flatMap { $0.quarantined.map(\.id) }
        )
        var organizable = hashed.filter { !quarantineIDs.contains($0.id) }

        // Mark paired items (RAW+JPEG, Live Photo) so PlanBuilder keeps them together
        for pair in classification.rawJpegPairs + classification.livePhotoPairs {
            if let pi = organizable.firstIndex(where: { $0.id == pair.primary.id }) {
                organizable[pi].pairedItemID = pair.companion.id
            }
        }

        // ── Phase 6: Event grouping ────────────────────────────────────
        // Grouping and plan building are also CPU-bound; keep them off the main actor.
        transition(to: .grouping)
        let grouper  = EventGrouper(rules: rules)
        let organizableItems = organizable
        var events = await Task.detached(priority: .userInitiated) {
            grouper.group(items: organizableItems)
        }.value

        // Resolve place names from photo GPS so events read as
        // "March 14–16 · San Francisco" instead of bare dates.
        if rules.enableLocationReading {
            events = await LocationNamer().nameEvents(events)
        }

        planInputs = PlanInputs(
            events: events,
            items: organizableItems,
            destinationURL: destinationURL,
            placementMode: placementMode,
            sourceURLs: sourceURLs,
            duplicateSets: classification.allDuplicateSets
        )
        guard let plan = await buildPlan(rules: rules) else { return }

        items = hashed
        transition(to: .ready)
        totalScanDuration = scanStartDate.map { Date().timeIntervalSince($0) }
        clockTask?.cancel()
        onPlanReady(plan)
    }

    // MARK: - Plan

    /// Builds (or rebuilds) the organization plan from the finished scan. `personByItem`
    /// maps photos to their main named person and only matters in People mode.
    func buildPlan(rules: GroupingRules, personByItem: [UUID: String] = [:]) async -> OrganizationPlan? {
        guard let inputs = planInputs else { return nil }
        let builder = PlanBuilder(rules: rules)
        var plan = await Task.detached(priority: .userInitiated) {
            builder.build(
                events: inputs.events,
                allItems: inputs.items,
                destinationURL: inputs.destinationURL,
                placementMode: inputs.placementMode,
                sourceURLs: inputs.sourceURLs,
                personByItem: personByItem
            )
        }.value
        plan.duplicateSets = inputs.duplicateSets
        plan.measuredBytesPerSecond = measuredBytesPerSecond > 0 ? measuredBytesPerSecond : nil
        return plan
    }

    /// Items that can be organized (duplicates removed), used to resolve paired companions.
    var organizableItems: [MediaItem] { planInputs?.items ?? [] }

    // MARK: - Helpers

    // MARK: Timing

    private func transition(to next: Phase) {
        if let start = phaseStartDate {
            phaseDurations[phase] = Date().timeIntervalSince(start)
        }
        phase = next
        phaseStartDate = Date()
        currentPhaseElapsed = 0
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let start = self.phaseStartDate else { continue }
                self.currentPhaseElapsed = Date().timeIntervalSince(start)
            }
        }
    }

    /// Duration string for a completed phase, nil if not yet done.
    func durationDetail(for targetPhase: Phase) -> String? {
        guard let d = phaseDurations[targetPhase] else { return nil }
        return formatDuration(d)
    }

    var elapsedString: String { formatDuration(currentPhaseElapsed) }

    /// Elapsed time of the current phase at `now` — lets the view drive its own clock so
    /// the counter keeps moving even when progress callbacks are sparse.
    func elapsedString(at now: Date) -> String {
        guard let start = phaseStartDate else { return "" }
        return formatDuration(now.timeIntervalSince(start))
    }

    /// Recomputes `currentPhaseElapsed` from the wall clock (called from progress callbacks).
    private func refreshElapsed() {
        if let start = phaseStartDate { currentPhaseElapsed = Date().timeIntervalSince(start) }
    }

    var totalDurationString: String? {
        totalScanDuration.map { "Completed in \(formatDuration($0))" }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        // Round to the nearest second so 1.9 s reads "2s", not "1s"; only truly sub-second
        // phases show "<1s".
        let secs = Int(t.rounded())
        if secs < 1  { return "<1s" }
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60, s = secs % 60
        return s > 0 ? "\(m)m \(s)s" : "\(m)m"
    }

    // MARK: Hashing

    func hashDetail(elapsed: String) -> String {
        guard hashTotal > 0 else {
            return phase == .hashing ? elapsed : ""
        }
        let count = "\(hashDone) / \(hashTotal)"
        guard phase == .hashing else { return count }
        if !hashETA.isEmpty { return "\(count) · \(hashETA)" }
        return "\(count) · \(elapsed)"
    }

    private func etaString(bytesHashed: Int64, bytesTotal: Int64) -> String {
        guard let start = hashPhaseStart, bytesHashed > 0, bytesTotal > bytesHashed else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        let rate = Double(bytesHashed) / elapsed
        guard rate > 0 else { return "" }
        let remaining = Double(bytesTotal - bytesHashed) / rate
        if remaining < 5  { return "almost done" }
        if remaining < 60 { return "~\(Int(remaining))s" }
        let m = Int(remaining / 60), s = Int(remaining.truncatingRemainder(dividingBy: 60))
        return s > 0 ? "~\(m)m \(s)s" : "~\(m)m"
    }

    private func scanOptions(from rules: GroupingRules) -> MediaScanner.ScanOptions {
        MediaScanner.ScanOptions(
            scanNestedSubfolders: rules.scanNestedSubfolders,
            followSymlinks: rules.followSymlinks,
            includeSidecars: rules.includeSidecars,
            includeScreenshots: rules.includeScreenshots,
            mediaFilter: rules.mediaFilter
        )
    }
}
