import Foundation
import SwiftData

@Model
final class PracticeRecord {
    var link: String
    var name: String
    var start: Double
    var end: Double
    var rate: Double

    var videoID: String? { YouTubeLink.videoID(from: link) }

    var range: LoopRange? { LoopRange(start: start, end: end) }

    init(link: String, name: String, start: Double, end: Double, rate: Double) {
        self.link = link
        self.name = name
        self.start = start
        self.end = end
        self.rate = rate
    }

    static func sections(for videoID: String?, in records: [PracticeRecord]) -> [PracticeRecord] {
        guard let videoID else { return [] }
        return records.filter { $0.videoID == videoID }.sorted {
            ($0.start, $0.end, $0.name) < ($1.start, $1.end, $1.name)
        }
    }
}

struct SavedVideoSession: Identifiable {
    let id: String
    let title: String
    let rate: Double

    static func all(sections: [PracticeSection], titles: [String: String], rates: [String: Double] = [:]) -> [Self] {
        var representatives: [String: PracticeSection] = [:]
        for section in PracticeSection.visible(in: sections).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            guard let id = section.videoID, representatives[id] == nil else { continue }
            representatives[id] = section
        }
        return Set(representatives.keys).union(titles.keys).map { id in
            Self(id: id, title: titles[id] ?? representatives[id]?.name ?? id, rate: rates[id] ?? representatives[id]?.rate ?? 1)
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

enum YouTubeLink {
    static func videoID(from input: String) -> String? {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: clean),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.lowercased()
        else { return nil }

        let path = url.path.split(separator: "/")
        let candidate: String?
        switch host {
        case "youtu.be":
            candidate = path.count == 1 ? String(path[0]) : nil
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com":
            if path == ["watch"] {
                let videoParameters = url.queryItems?.filter { $0.name == "v" } ?? []
                candidate = videoParameters.count == 1 ? videoParameters[0].value : nil
            } else if path.count == 2, ["shorts", "embed"].contains(path[0]) {
                candidate = String(path[1])
            } else {
                candidate = nil
            }
        default:
            candidate = nil
        }
        return candidate?.wholeMatch(of: /[A-Za-z0-9_-]{11}/).map { String($0.output) }
    }

    static func watchURL(for id: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: id)]
        return components.url
    }
}
