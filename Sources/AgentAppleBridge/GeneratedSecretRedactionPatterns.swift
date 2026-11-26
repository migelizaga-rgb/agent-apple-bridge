// Generic outbound credential detectors; maintained in this package.
import Foundation

enum GeneratedSecretRedactionPatterns {
    static let blocked: [(String, NSRegularExpression)] = [
        ("private key", try! NSRegularExpression(pattern: #"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"#, options: [.caseInsensitive])),
        ("auth token", try! NSRegularExpression(pattern: #"\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, options: [.caseInsensitive])),
        ("auth token", try! NSRegularExpression(pattern: #"\b(?:sk-[A-Za-z0-9_*.-]{8,}|gsk_[A-Za-z0-9_-]{8,}|sk_live_[A-Za-z0-9]{8,})"#, options: [.caseInsensitive])),
        ("GitHub token", try! NSRegularExpression(pattern: #"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9_]{20,})\b"#, options: [.caseInsensitive])),
        ("Slack token", try! NSRegularExpression(pattern: #"\b(?:xoxe\.)?xox[baprs]-[A-Za-z0-9_-]{10,}\b"#, options: [.caseInsensitive])),
        ("AWS access key", try! NSRegularExpression(pattern: #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, options: [.caseInsensitive])),
        ("Google API key", try! NSRegularExpression(pattern: #"\bAIza[0-9A-Za-z_-]{20,}\b"#, options: [.caseInsensitive])),
        ("Google OAuth token", try! NSRegularExpression(pattern: #"\b(?:ya29\.[A-Za-z0-9._-]{8,}|1//[A-Za-z0-9_-]{8,})"#, options: [.caseInsensitive])),
        ("GOG keyring password", try! NSRegularExpression(pattern: #"\bGOG_KEYRING_PASSWORD=\S+"#, options: [.caseInsensitive])),
        ("Telegram bot token", try! NSRegularExpression(pattern: #"(?<!\d)\d{8,10}(?!\d):[A-Za-z0-9_-]{35,}"#, options: [.caseInsensitive])),
        ("JWT", try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#, options: [.caseInsensitive])),
        ("hex token", try! NSRegularExpression(pattern: #"\b[A-Fa-f0-9]{64,}\b"#, options: [.caseInsensitive])),
        ("network key", try! NSRegularExpression(pattern: #"\btskey-[A-Za-z0-9_-]{8,}\b"#, options: [.caseInsensitive])),
        ("service token", try! NSRegularExpression(pattern: #"\bFlyV1\s+[A-Za-z0-9+/=_-]{8,}\b"#, options: [.caseInsensitive])),
        ("service access token", try! NSRegularExpression(pattern: #"\baccess-(?:sandbox|development|production)-[A-Za-z0-9-]{8,}\b"#, options: [.caseInsensitive])),
        ("credential assignment", try! NSRegularExpression(pattern: #"([A-Za-z0-9_-]*(?:api[_-]?key|auth(?:orization)?|password|passwd|secret|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?key|private[_-]?key|credential)\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;]{6,})"#, options: [.caseInsensitive])),
        ("credential URL userinfo", try! NSRegularExpression(pattern: #"(?<=:\/\/)[^\s/@]+(?=@)"#, options: [.caseInsensitive])),
        ("OAuth JSON field", try! NSRegularExpression(pattern: #"(\\*)"(access_token|refresh_token|client_secret)\1"\s*:\s*\1"(?:\\.|[^"\\])*?\1""#, options: [.caseInsensitive])),
    ]
}
