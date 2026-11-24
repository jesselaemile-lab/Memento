import Foundation
import SQLite3
import CoreLocation

// MARK: - Row model

struct LibraryRow: Sendable {
    let id: String
    let path: String
    let sha256: String?
    let captureDate: Date?
    let year: Int
    let month: Int
    let eventName: String?
    let fileSize: Int64
    let mediaType: String
}

// MARK: - LibraryStore actor

/// SQLite-backed index of organized media items.
/// Persists to ~/Library/Application Support/Memento/library.db.
actor LibraryStore {

    private var db: OpaquePointer?

    // SQLITE_TRANSIENT tells SQLite to make its own copy of string data.
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func makeURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = support.appendingPathComponent("Memento", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.db")
    }

    init(url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw StoreError.cannotOpen(url)
        }
        db = handle
        try LibraryStore.initSchema(db: handle)
        LibraryStore.migrate(db: handle)
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Schema

    private nonisolated static func initSchema(db: OpaquePointer) throws {
        let sql = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS library_items (
            id         TEXT PRIMARY KEY,
            path       TEXT NOT NULL,
            sha256     TEXT,
            capture_date REAL,
            year       INTEGER,
            month      INTEGER,
            event_name TEXT,
            file_size  INTEGER DEFAULT 0,
            media_type TEXT    DEFAULT 'photo'
        );
        CREATE INDEX IF NOT EXISTS idx_date ON library_items(capture_date);
        CREATE INDEX IF NOT EXISTS idx_ym   ON library_items(year, month);
        """
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw StoreError.sqlError(msg)
        }
    }

    /// Columns added after the first release. ALTER TABLE fails harmlessly when a column
    /// already exists, so this is safe to run on every launch.
    private nonisolated static func migrate(db: OpaquePointer) {
        let columns = [
            "relative_path TEXT", "latitude REAL", "longitude REAL",
            "width REAL", "height REAL", "duration REAL", "face_count INTEGER DEFAULT 0",
            "location_name TEXT", "camera_model TEXT"
        ]
        for col in columns {
            sqlite3_exec(db, "ALTER TABLE library_items ADD COLUMN \(col);", nil, nil, nil)
        }
    }

    // MARK: - Insert

    /// Records organized items. `items` must carry their *destination* URLs so the library
    /// still points at the files after a move.
    func insertItems(_ items: [MediaItem], eventName: String, relativePath: String) throws {
        guard let db else { return }
        try exec("BEGIN;")
        do {
            let sql = """
            INSERT OR REPLACE INTO library_items
            (id, path, sha256, capture_date, year, month, event_name, file_size, media_type,
             relative_path, latitude, longitude, width, height, duration, face_count, location_name, camera_model)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
            defer { sqlite3_finalize(stmt) }

            let cal = Calendar.current
            for item in items {
                let ts    = item.captureDate?.timeIntervalSince1970
                let year  = item.captureDate.map { cal.component(.year,  from: $0) } ?? 0
                let month = item.captureDate.map { cal.component(.month, from: $0) } ?? 0

                sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, transient)
                sqlite3_bind_text(stmt, 2, item.url.path,       -1, transient)
                bindText(stmt, 3, item.sha256)
                bindDouble(stmt, 4, ts)
                sqlite3_bind_int(stmt,   5, Int32(year))
                sqlite3_bind_int(stmt,   6, Int32(month))
                sqlite3_bind_text(stmt,  7, eventName, -1, transient)
                sqlite3_bind_int64(stmt, 8, item.fileSize)
                sqlite3_bind_text(stmt,  9, item.mediaType.rawValue, -1, transient)
                sqlite3_bind_text(stmt, 10, relativePath, -1, transient)
                bindDouble(stmt, 11, item.location?.latitude)
                bindDouble(stmt, 12, item.location?.longitude)
                bindDouble(stmt, 13, item.dimensions.map { Double($0.width) })
                bindDouble(stmt, 14, item.dimensions.map { Double($0.height) })
                bindDouble(stmt, 15, item.durationSeconds)
                sqlite3_bind_int(stmt, 16, Int32(item.faceCount))
                bindText(stmt, 17, item.locationName)
                bindText(stmt, 18, item.cameraModel)

                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Forgets items by destination path — used when a run is reverted.
    func deleteItems(atPaths paths: [String]) throws {
        guard let db, !paths.isEmpty else { return }
        try exec("BEGIN;")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM library_items WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for path in paths {
            sqlite3_bind_text(stmt, 1, path, -1, transient)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        try exec("COMMIT;")
    }

    // MARK: - Query: whole library as folders (Timeline / Folders / Places)

    /// Rebuilds the organized folder list from the index, one folder per relative path.
    func loadFolders() throws -> [PlannedFolder] {
        guard let db else { return [] }
        let sql = """
        SELECT id, path, sha256, capture_date, file_size, media_type, relative_path, event_name,
               latitude, longitude, width, height, duration, face_count, location_name, camera_model
        FROM library_items
        WHERE relative_path IS NOT NULL
        ORDER BY relative_path, capture_date;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var order: [String] = []
        var items: [String: [MediaItem]] = [:]
        var names: [String: String] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idText = colText(stmt, 0), let id = UUID(uuidString: idText),
                  let path = colText(stmt, 1), let relPath = colText(stmt, 6) else { continue }
            var item = MediaItem(
                id: id, url: URL(fileURLWithPath: path),
                fileSize: sqlite3_column_int64(stmt, 4),
                mediaType: MediaType(rawValue: colText(stmt, 5) ?? "") ?? .photo
            )
            item.sha256      = colText(stmt, 2)
            item.captureDate = colDouble(stmt, 3).map { Date(timeIntervalSince1970: $0) }
            if let lat = colDouble(stmt, 8), let lon = colDouble(stmt, 9) {
                item.location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
            if let w = colDouble(stmt, 10), let h = colDouble(stmt, 11) {
                item.dimensions = CGSize(width: w, height: h)
            }
            item.durationSeconds = colDouble(stmt, 12)
            item.faceCount       = Int(sqlite3_column_int(stmt, 13))
            item.locationName    = colText(stmt, 14)
            item.cameraModel     = colText(stmt, 15)

            if items[relPath] == nil { order.append(relPath) }
            items[relPath, default: []].append(item)
            names[relPath] = colText(stmt, 7) ?? (relPath as NSString).lastPathComponent
        }

        return order.map { relPath in
            let folderItems = items[relPath] ?? []
            let name = names[relPath] ?? relPath
            return PlannedFolder(
                name: name, relativePath: relPath, items: folderItems,
                event: MediaEvent(name: name, items: folderItems)
            )
        }
    }

    // MARK: - Query: month groups (for Timeline header rows)

    func monthGroups() throws -> [(year: Int, month: Int, count: Int)] {
        guard let db else { return [] }
        let sql = """
        SELECT year, month, COUNT(*)
        FROM library_items
        WHERE year > 0
        GROUP BY year, month
        ORDER BY year DESC, month DESC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [(Int, Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append((Int(sqlite3_column_int(stmt, 0)),
                         Int(sqlite3_column_int(stmt, 1)),
                         Int(sqlite3_column_int(stmt, 2))))
        }
        return rows
    }

    // MARK: - Query: paginated items for a month

    func items(year: Int, month: Int, offset: Int = 0, limit: Int = 60) throws -> [LibraryRow] {
        guard let db else { return [] }
        let sql = """
        SELECT id, path, sha256, capture_date, year, month, event_name, file_size, media_type
        FROM library_items
        WHERE year = ? AND month = ?
        ORDER BY capture_date
        LIMIT ? OFFSET ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(year))
        sqlite3_bind_int(stmt, 2, Int32(month))
        sqlite3_bind_int(stmt, 3, Int32(limit))
        sqlite3_bind_int(stmt, 4, Int32(offset))

        var rows: [LibraryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(LibraryRow(
                id:          colText(stmt, 0) ?? "",
                path:        colText(stmt, 1) ?? "",
                sha256:      colText(stmt, 2),
                captureDate: sqlite3_column_type(stmt, 3) != SQLITE_NULL
                             ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                             : nil,
                year:        Int(sqlite3_column_int(stmt, 4)),
                month:       Int(sqlite3_column_int(stmt, 5)),
                eventName:   colText(stmt, 6),
                fileSize:    sqlite3_column_int64(stmt, 7),
                mediaType:   colText(stmt, 8) ?? "photo"
            ))
        }
        return rows
    }

    // MARK: - Query: total count

    func totalCount() throws -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM library_items;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw StoreError.sqlError(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer, _ col: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, col, value, -1, transient) }
        else         { sqlite3_bind_null(stmt, col) }
    }

    private func bindDouble(_ stmt: OpaquePointer, _ col: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, col, value) }
        else         { sqlite3_bind_null(stmt, col) }
    }

    private func colDouble(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        sqlite3_column_type(stmt, col) != SQLITE_NULL ? sqlite3_column_double(stmt, col) : nil
    }

    private func colText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    enum StoreError: Error {
        case cannotOpen(URL)
        case sqlError(String)
    }
}
