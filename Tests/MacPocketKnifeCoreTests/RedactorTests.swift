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

import Testing
import MacPocketKnifeCore

private var fakeTelegramToken: String {
    "123456789:" + String(repeating: "A", count: 35)
}

@Test func redactsTelegramTokensInMessagesAndRequestURLs() {
    let token = fakeTelegramToken
    let text = "Request /bot\(token)/sendMessage failed: \(token)"
    #expect(Redactor.redact(text) == "Request /bot[REDACTED]/sendMessage failed: [REDACTED]")
}

@Test(arguments: ["Bearer", "bearer", "BEARER"])
func redactsAuthorizationCredentials(scheme: String) {
    let credential = "test-" + "credential_123.abc+/=="
    let text = "Authorization: \(scheme) \(credential)"
    #expect(Redactor.redact(text) == "Authorization: [REDACTED]")
    #expect(Redactor.redact("\(scheme)\t\(credential)") == "[REDACTED]")
}

@Test func redactsExactCustomValuesLiterallyAndMergesOverlaps() {
    #expect(Redactor.redact("abcde abcde", secrets: ["abc", "bcde", ""]) == "[REDACTED] [REDACTED]")
    #expect(Redactor.redact("🔒 a.*b a.*b", secrets: ["a.*b"]) == "🔒 [REDACTED] [REDACTED]")
    #expect(Redactor.redact("ababa", secrets: ["aba"]) == "[REDACTED]")
    #expect(Redactor.redact("Exact exact", secrets: ["Exact"]) == "[REDACTED] exact")
}

@Test func redactsMixedSecretsWithoutLeakingPartialValues() {
    let token = fakeTelegramToken
    let text = "\(token) Authorization: " + "Bearer " + "test-credential custom-value"
    #expect(Redactor.redact(text, secrets: [token, "custom-value", "test-"]) ==
        "[REDACTED] Authorization: [REDACTED] [REDACTED]")
}

@Test(arguments: [
    "", "Battery at 50%; caffeinate is blocking sleep.",
    "Authorization is optional.", "Bearer", "12:30", "123456789:short", "🔋 Normal text.",
])
func redactorPreservesNormalText(text: String) {
    #expect(Redactor.redact(text) == text)
}

@Test func redactsHomeDirectoryPathsWithoutMaskingOtherUserNames() {
    let result = Redactor.redact(
        "/Users/alice /Users/alice/Movies \"/Users/alice\" /Users/alice-other/Movies",
        homeDirectory: "/Users/alice"
    )
    #expect(result == "~ ~/Movies \"~\" /Users/alice-other/Movies")
    #expect(Redactor.redact("(/Users/alice),", homeDirectory: "/Users/alice") == "(~),")
    #expect(Redactor.redact("/tmp/file", homeDirectory: "/") == "/tmp/file")
    #expect(Redactor.redact("normal", homeDirectory: "") == "normal")
    #expect(Redactor.redact("/Users/a.b/Movies", homeDirectory: "/Users/a.b") == "~/Movies")
}
