import Diary
import Foundation
import Observation

/// Restores a backup by merging it into the diary: the picked file is only copied, the copy is checked and previewed,
/// a copy of the current diary is kept first, and the merge is one transaction. Only while the app is open.
@MainActor @Observable final class ImportService {
    static let shared = ImportService()

    enum Phase: Equatable, Sendable { case idle, reading, ready(BackupSummary, URL), merging, rebuilding, done(Int), failed(String) }

    /// True from before the chain is stopped until the merge has ended; nothing in the chain starts meanwhile.
    var merging = false
    var phase: Phase = .idle
    /// The copy being merged; a rebuild that ends after a newer restore began must not close that one.
    private var mergingCopy: URL?

    /// Copies the picked file into the temporary folder (an iCloud file downloads first) and reads its summary from the copy.
    func read(_ picked: URL) async {
        phase = .reading
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).lifepath")
        let result = await Task.detached(priority: .userInitiated) { () -> Result<BackupSummary, any Error> in
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            var coordinatorError: NSError?, copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: picked, options: [], error: &coordinatorError) { url in
                do { try FileManager.default.copyItem(at: url, to: copy) } catch { copyError = error }
            }
            if coordinatorError != nil || copyError != nil { return .failure(CocoaError(.fileReadUnknown)) }
            return Result { try Diary.backupSummary(at: copy.path) }
        }.value
        guard phase == .reading else { try? FileManager.default.removeItem(at: copy); return }   // cancelled while checking
        switch result {
        case .success(let summary): phase = .ready(summary, copy)
        case .failure(let error):
            try? FileManager.default.removeItem(at: copy)
            phase = .failed((error as? DiaryError) == .newerBackup ? error.localizedDescription
                : error is CocoaError ? "The file couldn't be read. If it is in iCloud Drive, check the connection and try again."
                : "This file isn't a LifePath backup.")
        }
    }

    func merge() async {
        guard case .ready(_, let copy) = phase else { return }
        guard let diary = Recorder.shared.diaryForImport() else {
            phase = .failed("The diary can't be opened right now. Unlock the iPhone and try again.")
            return
        }
        merging = true
        mergingCopy = copy
        phase = .merging
        await SmoothingService.stop()
        Recorder.shared.holdWrites = true   // points recorded meanwhile stay in memory and are written right after
        // nil: the kept copy couldn't be written, so nothing was merged.
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<MergeResult, any Error>? in
            do {
                if try diary.lastPoint() != nil {
                    let kept = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent("before-import.lifepath")
                    try? FileManager.default.removeItem(at: kept)
                    do { try diary.backup(to: kept) } catch { try? FileManager.default.removeItem(at: kept); return nil }
                }
                return .success(try diary.merge(backupAt: copy.path))
            } catch { return .failure(error) }
        }.value
        try? FileManager.default.removeItem(at: copy)
        Recorder.shared.holdWrites = false
        Recorder.shared.flush()
        merging = false

        guard let outcome else {
            Recorder.shared.log("import", "failed keep-copy")
            phase = .failed("Not enough space to keep a copy of your diary first. Nothing was changed.")
            return
        }
        switch outcome {
        case .failure(let error):
            Recorder.shared.log("import", "failed")
            phase = .failed("Restore failed: \(error.localizedDescription). Your diary is unchanged.")
        case .success(let r):
            if let places = try? diary.places() { PlaceService.shared.places = places }
            for name in [SmoothingService.linesChanged, DayService.changed, PlaceService.changed] { NotificationCenter.default.post(name: name, object: nil) }
            Recorder.shared.log("import", "added=\(r.addedPoints) fresh=\(r.fresh)")
            Recorder.shared.flush()
            phase = .rebuilding
            await SmoothingService.start().value
            if phase == .rebuilding, mergingCopy == copy { phase = .done(r.addedPoints) }   // "Done" while rebuilding closed the sheet: stay closed
        }
    }

    /// Closes the sheet; a copy not yet merged is deleted. A running rebuild goes on.
    func cancel() {
        if case .ready(_, let copy) = phase { try? FileManager.default.removeItem(at: copy) }
        phase = .idle
    }
}
