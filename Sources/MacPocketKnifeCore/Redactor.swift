// Copyright 2026 Francisco Perdigon Romero and contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

@preconcurrency import Foundation

/// Apply before logging or displaying error descriptions. Exact values are case-sensitive.
public enum Redactor {
    public static let mask = "[REDACTED]"

    public static func redact(
        _ text: String, secrets: [String] = [],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let patterns = [
            #"[0-9]{5,}:[A-Za-z0-9_-]{20,}"#,
            #"(?i)\bBearer[ \t]+[A-Za-z0-9._~+/-]+=*"#,
        ]
        var ranges: [NSRange] = []
        for pattern in patterns {
            // Patterns are fixed; failure must never silently return unredacted input.
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return mask }
            ranges += regex.matches(in: text, range: fullRange).map(\.range)
        }
        for secret in Set(secrets) where !secret.isEmpty {
            var searchRange = fullRange
            while searchRange.length > 0 {
                let range = source.range(of: secret, options: .literal, range: searchRange)
                guard range.location != NSNotFound else { break }
                ranges.append(range)
                let next = range.location + 1
                searchRange = NSRange(location: next, length: source.length - next)
            }
        }

        // Merge overlaps so a custom value cannot expose part of another secret.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        let result = NSMutableString(string: text)
        for range in merged.reversed() {
            result.replaceCharacters(in: range, with: mask)
        }
        let masked = result as String
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return masked }
        let escapedHome = NSRegularExpression.escapedPattern(for: homeDirectory)
        guard let homePattern = try? NSRegularExpression(pattern: escapedHome + #"(?=/|$|[\s\"\x27(),:;\[\]{}<>])"#) else {
            return mask
        }
        let maskedRange = NSRange(location: 0, length: (masked as NSString).length)
        return homePattern.stringByReplacingMatches(in: masked, range: maskedRange, withTemplate: "~")
    }
}
