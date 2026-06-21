import Foundation
import Combine

final class ConfigStore: ObservableObject {
    @Published var config: AppConfig

    private let fileURL: URL

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SlapShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.fileURL = supportDir.appendingPathComponent("modes.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func incrementLifetimeSlapCount() {
        config.lifetimeSlapCount += 1
        save()
    }

    func slot(forSlapCount count: Int) -> Slot? {
        config.slots.first { $0.slapCount == count && $0.enabled }
    }
}
