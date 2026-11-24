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

public struct CompositeNotifier: AlertNotifying {
    public typealias RemoteDispatch = @Sendable (@escaping @Sendable () async -> Void) -> Void

    private let channels: [any AlertNotifying]
    private let dispatchRemote: RemoteDispatch

    /// Remote channels run fire-and-forget so a slow network can never stall callers.
    public init(
        channels: [any AlertNotifying],
        dispatchRemote: @escaping RemoteDispatch = { work in Task.detached { await work() } }
    ) {
        self.channels = channels
        self.dispatchRemote = dispatchRemote
    }

    public func deliver(_ notice: Notice) async {
        let local = channels.filter { !$0.deliversRemotely }
        for channel in channels where channel.deliversRemotely {
            dispatchRemote { await channel.deliver(notice) }
        }
        await withTaskGroup(of: Void.self) { group in
            for channel in local {
                group.addTask { await channel.deliver(notice) }
            }
        }
    }
}
