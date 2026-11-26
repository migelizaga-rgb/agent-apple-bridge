import Contacts
import Foundation

final class ContactsHandler {
    private final class AccessResult: @unchecked Sendable {
        var granted = false
        var error: Error?
    }

    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func handle(mode: String, params: [String: Any]) throws -> Any {
        guard mode == "read" else {
            throw BridgeError("read_only", "Apple Contacts access is read-only")
        }
        switch params["action"] as? String {
        case "search":
            guard let rawQuery = params["query"] as? String else {
                throw BridgeError("invalid_params", "a non-empty query is required for Contacts search")
            }
            let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw BridgeError("invalid_params", "a non-empty query is required for Contacts search")
            }
            let limit: Int
            if let rawLimit = params["limit"] {
                guard let requestedLimit = rawLimit as? Int else {
                    throw BridgeError("invalid_params", "Contacts search limit must be an integer")
                }
                limit = requestedLimit
            } else {
                limit = 10
            }
            guard (1...25).contains(limit) else {
                throw BridgeError("invalid_params", "Contacts search limit must be between 1 and 25")
            }
            try ensureAccess()
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: query),
                keysToFetch: keysToFetch
            )
            return ["contacts": contacts.prefix(limit).map(contactSummary)]
        case "get":
            guard let id = params["id"] as? String,
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeError("invalid_params", "a non-empty id is required to get a Contact")
            }
            try ensureAccess()
            let contact = try store.unifiedContact(withIdentifier: id, keysToFetch: keysToFetch)
            return contactSummary(contact)
        default:
            throw BridgeError("unsupported_action", "unsupported Contacts read action")
        }
    }

    private var keysToFetch: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
    }

    private func ensureAccess() throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized { return }
        if status == .denied || status == .restricted {
            throw BridgeError("contacts_access_denied", "Contacts access is denied in System Settings")
        }
        guard status == .notDetermined else {
            throw BridgeError("contacts_access_denied", "Contacts access is unavailable")
        }

        let semaphore = DispatchSemaphore(value: 0)
        let result = AccessResult()
        store.requestAccess(for: .contacts) { granted, error in
            result.granted = granted
            result.error = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            throw BridgeError("timeout", "Contacts permission request timed out")
        }
        guard result.granted else {
            throw BridgeError("contacts_access_denied", result.error?.localizedDescription ?? "Contacts access is denied")
        }
    }

    private func contactSummary(_ contact: CNContact) -> [String: Any] {
        let addresses: [[String: Any]] = contact.postalAddresses.map { labeledAddress in
            let address = labeledAddress.value
            return [
                "label": CNLabeledValue<NSString>.localizedString(forLabel: labeledAddress.label ?? ""),
                "street": address.street,
                "city": address.city,
                "state": address.state,
                "postalCode": address.postalCode,
                "country": address.country,
            ]
        }
        let phoneNumbers: [[String: Any]] = contact.phoneNumbers.map {
            ["label": CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), "number": $0.value.stringValue]
        }
        let emailAddresses: [[String: Any]] = contact.emailAddresses.map {
            ["label": CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? ""), "address": $0.value as String]
        }
        return [
            "id": contact.identifier,
            "givenName": contact.givenName,
            "familyName": contact.familyName,
            "nickname": contact.nickname,
            "organizationName": contact.organizationName,
            "postalAddresses": addresses,
            "phoneNumbers": phoneNumbers,
            "emailAddresses": emailAddresses,
        ]
    }
}
