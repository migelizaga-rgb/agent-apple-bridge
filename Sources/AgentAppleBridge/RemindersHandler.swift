import EventKit
import Darwin
import Foundation

private final class ChangeMarkerWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.mig\u{65}lizaga-rgb.agentapplebridge.reminders-changed")
    private var pendingWrite: DispatchWorkItem?

    func schedule() {
        lock.lock()
        defer { lock.unlock() }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write() }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func write() {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AGENT_BRIDGE_STATE_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentAppleBridge").path)
        let marker = directory.appendingPathComponent("reminders-changed")
        let temporary = directory.appendingPathComponent(".reminders-changed-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let timestamp = ISO8601DateFormatter().string(from: Date()) + "\n"
            try Data(timestamp.utf8).write(to: temporary, options: .atomic)
            let renameResult = temporary.path.withCString { source in
                marker.path.withCString { destination in Darwin.rename(source, destination) }
            }
            guard renameResult == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            fputs("AgentAppleBridge Reminders change marker failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

final class RemindersHandler {
    private final class AccessResult: @unchecked Sendable {
        var granted = false
        var error: Error?
    }

    private let store: EKEventStore
    private let observerLock = NSLock()
    private var storeChangeObserver: NSObjectProtocol?
    private let changeMarkerWriter = ChangeMarkerWriter()

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
        // A restarted bridge must emit change markers before its first request.
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            observeStoreChangesIfNeeded()
        }
    }

    func handle(mode: String, params: [String: Any]) throws -> Any {
        let action = (params["action"] as? String ?? "").lowercased()
        if action == "capabilities" { return capabilities() }
        try ensureAccess()
        if mode == "read" {
            switch action {
            case "lists": return lists()
            case "get", "list", "search": return try read(action: action, params: params)
            default: throw BridgeError("unsupported_action", "unsupported reminders read action")
            }
        }
        switch action {
        case "create": return try create(params)
        case "update", "complete", "move": return try update(action: action, params: params)
        case "delete": return try delete(params)
        default: throw BridgeError("unsupported_action", "unsupported reminders write action")
        }
    }

    private func ensureAccess() throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess {
            observeStoreChangesIfNeeded()
            return
        }
        if status == .denied || status == .restricted {
            throw BridgeError("permission_denied", "Reminders access is denied in System Settings")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = AccessResult()
        store.requestFullAccessToReminders { allowed, error in
            result.granted = allowed
            result.error = error
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 60)
        if !result.granted {
            throw BridgeError("permission_required", result.error?.localizedDescription ?? "Reminders permission is required")
        }
        observeStoreChangesIfNeeded()
    }

    private func observeStoreChangesIfNeeded() {
        observerLock.lock()
        defer { observerLock.unlock() }
        guard storeChangeObserver == nil else { return }
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: nil
        ) { [changeMarkerWriter] _ in
            changeMarkerWriter.schedule()
        }
    }

    private func capabilities() -> [String: Any] {
        [
            "read": ["lists", "list", "get", "search"],
            "write": ["create", "update", "complete", "move", "delete"],
            "stableIds": true,
            "pagination": true,
        ]
    }

    private func lists() -> [String: Any] {
        let rows = store.calendars(for: .reminder).map {
            ["id": $0.calendarIdentifier, "title": $0.title, "source": $0.source.title]
        }
        return ["items": rows, "nextCursor": NSNull()]
    }

    private func fetchAll() throws -> [EKReminder] {
        let semaphore = DispatchSemaphore(value: 0)
        var reminders: [EKReminder]?
        store.fetchReminders(matching: store.predicateForReminders(in: nil)) {
            reminders = $0
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw BridgeError("timeout", "Reminders fetch timed out")
        }
        return reminders ?? []
    }

    private func read(action: String, params: [String: Any]) throws -> [String: Any] {
        let id = params["id"] as? String
        let query = (params["query"] as? String)?.lowercased()
        let filters = params["filters"] as? [String: Any] ?? [:]
        let listId = filters["listId"] as? String
        let completed = filters["completed"] as? Bool
        let limit = min(max(params["limit"] as? Int ?? 50, 1), 200)
        let offset = max(Int(params["cursor"] as? String ?? "0") ?? 0, 0)
        let matches = try fetchAll().filter { reminder in
            if let id, reminder.calendarItemIdentifier != id { return false }
            if let listId, reminder.calendar.calendarIdentifier != listId { return false }
            if let completed, reminder.isCompleted != completed { return false }
            if let query {
                let haystack = "\(reminder.title ?? "")\n\(reminder.notes ?? "")".lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
        let page = Array(matches.dropFirst(offset).prefix(limit)).map(serialize)
        let next = offset + page.count < matches.count ? String(offset + page.count) : nil
        return ["items": page, "nextCursor": next ?? NSNull(), "total": matches.count]
    }

    private func calendar(_ params: [String: Any], fallback: EKCalendar? = nil) throws -> EKCalendar {
        let target = params["target"] as? [String: Any] ?? [:]
        let requestedId = target["listId"]
        let requestedTitle = target["list"]
        if requestedId != nil && !(requestedId is String) {
            throw BridgeError("invalid_target", "target.listId must be a string")
        }
        if requestedTitle != nil && !(requestedTitle is String) {
            throw BridgeError("invalid_target", "target.list must be a string")
        }

        let idCalendar: EKCalendar?
        if let id = requestedId as? String {
            guard let calendar = store.calendar(withIdentifier: id), calendar.allowedEntityTypes.contains(.reminder) else {
                throw BridgeError("list_not_found", "Reminders list id was not found: \(id)")
            }
            idCalendar = calendar
        } else {
            idCalendar = nil
        }

        let titleCalendar: EKCalendar?
        if let title = requestedTitle as? String {
            let matches = store.calendars(for: .reminder).filter { $0.title == title }
            guard !matches.isEmpty else {
                throw BridgeError("list_not_found", "Reminders list was not found: \(title)")
            }
            guard matches.count == 1 else {
                let ids = matches.map(\.calendarIdentifier).joined(separator: ", ")
                throw BridgeError("list_ambiguous", "Reminders list title \(title) matches multiple lists: \(ids)")
            }
            titleCalendar = matches[0]
        } else {
            titleCalendar = nil
        }

        if let idCalendar, let titleCalendar,
           idCalendar.calendarIdentifier != titleCalendar.calendarIdentifier {
            throw BridgeError("list_not_found", "target.listId and target.list identify different Reminders lists")
        }
        if let idCalendar { return idCalendar }
        if let titleCalendar { return titleCalendar }
        if let fallback { return fallback }
        if let calendar = store.defaultCalendarForNewReminders() { return calendar }
        throw BridgeError("list_not_found", "no writable Reminders list was found")
    }

    private func hasNamedListTarget(_ params: [String: Any]) -> Bool {
        guard let target = params["target"] as? [String: Any] else { return false }
        return target["listId"] != nil || target["list"] != nil
    }

    private func create(_ params: [String: Any], destination: EKCalendar? = nil) throws -> [String: Any] {
        let content = params["content"] as? [String: Any] ?? [:]
        guard let title = content["title"] as? String, !title.isEmpty else {
            throw BridgeError("invalid_content", "reminder title is required")
        }
        let resolvedDestination: EKCalendar?
        if let destination {
            resolvedDestination = destination
        } else if hasNamedListTarget(params) {
            resolvedDestination = try calendar(params)
        } else {
            resolvedDestination = nil
        }
        if params["dryRun"] as? Bool == true {
            return ["dryRun": true, "preview": ["action": "create", "title": title]]
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try resolvedDestination ?? calendar(params)
        apply(content, to: reminder)
        try store.save(reminder, commit: true)
        return ["item": serialize(reminder)]
    }

    private func find(_ id: String?) throws -> EKReminder {
        guard let id, !id.isEmpty else { throw BridgeError("missing_id", "reminder id is required") }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw BridgeError("not_found", "reminder was not found")
        }
        return reminder
    }

    private func update(action: String, params: [String: Any]) throws -> [String: Any] {
        let reminder = try find(params["id"] as? String)
        let resolvedMoveCalendar: EKCalendar?
        if action == "move", hasNamedListTarget(params) {
            resolvedMoveCalendar = try calendar(params, fallback: reminder.calendar)
        } else {
            resolvedMoveCalendar = nil
        }
        if params["dryRun"] as? Bool == true {
            return ["dryRun": true, "preview": ["action": action, "id": reminder.calendarItemIdentifier]]
        }
        if action == "complete" {
            reminder.isCompleted = true
            reminder.completionDate = Date()
        } else {
            let patch = params["patch"] as? [String: Any] ?? [:]
            apply(patch, to: reminder)
            if action == "move" {
                reminder.calendar = try resolvedMoveCalendar ?? calendar(params, fallback: reminder.calendar)
            }
        }
        try store.save(reminder, commit: true)
        return ["item": serialize(reminder)]
    }

    private func delete(_ params: [String: Any]) throws -> [String: Any] {
        let reminder = try find(params["id"] as? String)
        if params["dryRun"] as? Bool == true {
            return ["dryRun": true, "preview": ["action": "delete", "id": reminder.calendarItemIdentifier, "title": reminder.title ?? ""]]
        }
        try store.remove(reminder, commit: true)
        return ["deleted": true, "id": reminder.calendarItemIdentifier]
    }

    private func apply(_ fields: [String: Any], to reminder: EKReminder) {
        if let title = fields["title"] as? String { reminder.title = title }
        if let notes = fields["notes"] as? String { reminder.notes = notes }
        if let priority = fields["priority"] as? Int { reminder.priority = priority }
        if let completed = fields["completed"] as? Bool { reminder.isCompleted = completed }
        if let due = fields["due"] as? String, let date = ISO8601DateFormatter().date(from: due) {
            reminder.dueDateComponents = Calendar.current.dateComponents(in: TimeZone.current, from: date)
        }
    }

    private func serialize(_ reminder: EKReminder) -> [String: Any] {
        [
            "id": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
            "notes": reminder.notes ?? "",
            "completed": reminder.isCompleted,
            "completionDate": reminder.completionDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "due": reminder.dueDateComponents?.date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "priority": reminder.priority,
            "list": ["id": reminder.calendar.calendarIdentifier, "title": reminder.calendar.title],
            "lastModified": reminder.lastModifiedDate.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
        ]
    }
}
