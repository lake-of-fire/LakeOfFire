//import Foundation
//import FeedKit
//import SwiftSoup
//import RealmSwift
//
//enum FeedError: Error {
//    case downloadFailed
//    case parserFailed
//    case jsonFeedsUnsupported
//}
//
//fileprivate func getRssData(rssUrl: URL) async throws -> Data? {
//    let (data, response) = try await URLSession.shared.data(from: rssUrl)
//    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
//        throw FeedError.downloadFailed
//    }
//    return data
//}
//
//extension ManabiCommon.Feed {
//    private func persist(rssItems: [RSSFeedItem]) throws {
//        let realm = try! Realm(configuration: SharedRealmConfigurer.configuration)
//        let feedEntries: [FeedEntry] = rssItems.reversed().compactMap { item in
//            guard let link = item.link?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed), let url = URL(string: link) else { return nil }
//            var imageUrl: URL? = nil
//            if let enclosureAttribs = item.enclosure?.attributes, enclosureAttribs.type?.hasPrefix("image/") ?? false {
//                if let imageUrlRaw = enclosureAttribs.url {
//                    imageUrl = URL(string: imageUrlRaw)
//                }
//            }
//            let content = item.content?.contentEncoded ?? item.description
//
//            var title = item.title
//            do {
//                if let feedItemTitle = item.title?.unescapeHTML(), let doc = try? SwiftSoup.parse(feedItemTitle) {
//                    doc.outputSettings().prettyPrint(pretty: false)
//                    try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
//                    title = try doc.text()
//                } else {
//                    print("Failed to parse HTML in order to transform content.")
//                    throw FeedError.parserFailed
//                }
//            } catch { }
//            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
//
//            let feedEntry = FeedEntry()
//            feedEntry.feed = realm.object(ofType: Feed.self, forPrimaryKey: self.id)
//            feedEntry.html = content
//            feedEntry.url = url
//            feedEntry.title = title ?? ""
//            feedEntry.imageUrl = imageUrl
//            feedEntry.publicationDate = item.pubDate ?? item.dublinCore?.dcDate
//            feedEntry.updateCompoundKey()
//            return feedEntry
//        }
//
//        try! realm.write {
//            realm.add(feedEntries, update: .modified)
//        }
//    }
//
//    private func persist(atomItems: [AtomFeedEntry]) throws {
//        let realm = try! Realm(configuration: SharedRealmConfigurer.configuration)
//        let feedEntries: [FeedEntry] = atomItems.reversed().compactMap { item in
//            var url: URL?
//            var imageUrl: URL?
//            item.links?.forEach { (link: AtomFeedEntryLink) in
//                guard let linkHref = link.attributes?.href?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return }
//
//                if (link.attributes?.rel ?? "alternate") == "alternate" {
//                    url = URL(string: linkHref)
//                } else if let rel = link.attributes?.rel, let type = link.attributes?.type, rel == "enclosure" && type.starts(with: "image/") {
//                    imageUrl = URL(string: linkHref)
//                }
//            }
//            guard let url = url else { return nil }
//
//            var voiceFrameUrl: URL? = nil
//            if let rawVoiceFrameUrl = item.links?.filter({ (link) -> Bool in
//                return (link.attributes?.rel ?? "") == "voice-frame"
//            }).first?.attributes?.href {
//                voiceFrameUrl = URL(string: rawVoiceFrameUrl)
//            }
//
//            var voiceAudioUrl: URL? = nil
//            if let rawVoiceAudioUrl = item.links?.filter({ (link) -> Bool in
//                return (link.attributes?.rel ?? "") == "voice-audio"
//            }).first?.attributes?.href {
//                voiceAudioUrl = URL(string: rawVoiceAudioUrl)
//            }
//
//            var redditTranslationsUrl: URL? = nil, redditTranslationsTitle: String? = nil
//            if let redditTranslationsAttrs = item.links?.filter({ (link) -> Bool in
//                return (link.attributes?.rel ?? "") == "reddit-translations"
//            }).first?.attributes, let rawRedditTranslationsUrl = redditTranslationsAttrs.href?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
//                redditTranslationsUrl = URL(string: rawRedditTranslationsUrl)
//                redditTranslationsTitle = redditTranslationsAttrs.title
//            }
//
//            var title = item.title
//            do {
//                if let feedItemTitle = item.title, let doc = try? SwiftSoup.parse(feedItemTitle) {
//                    doc.outputSettings().prettyPrint(pretty: false)
//                    try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
//                    title = try doc.text()
//                } else {
//                    print("Failed to parse HTML in order to transform content.")
//                }
//            } catch { }
//            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
//
//            let feedEntry = FeedEntry()
//            feedEntry.feed = realm.object(ofType: Feed.self, forPrimaryKey: self.id)
//            feedEntry.url = url
//            feedEntry.title = title ?? ""
//            feedEntry.imageUrl = imageUrl
//            feedEntry.publicationDate = item.published ?? item.updated
//            feedEntry.html = item.content?.value
//            feedEntry.voiceFrameUrl = voiceFrameUrl
//            feedEntry.voiceAudioUrl = voiceAudioUrl
//            feedEntry.redditTranslationsUrl = redditTranslationsUrl
//            feedEntry.redditTranslationsTitle = redditTranslationsTitle
//            feedEntry.updateCompoundKey()
//            return feedEntry
//        }
//
//        try! realm.write {
//            realm.add(feedEntries, update: .modified)
//        }
//    }
//
//    func fetch() async throws {
//        guard var rssData = try await getRssData(rssUrl: rssUrl) else {
//            throw FeedError.downloadFailed
//        }
//
//        rssData = cleanRssData(rssData)
//        let parser = FeedKit.FeedParser(data: rssData)
//        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<(), Error>) in
//            parser.parseAsync { parserResult in
//                switch parserResult {
//                case .success(let feed):
//                    switch feed {
//                    case .rss(let rssFeed):
//                        guard let items = rssFeed.items else {
//                            continuation.resume(throwing: FeedError.parserFailed)
//                            return
//                        }
//                        do {
//                            try self.persist(rssItems: items)
//                        } catch {
//                            continuation.resume(throwing: error)
//                            return
//                        }
//                    case .atom(let atomFeed):
//                        guard let items = atomFeed.entries else {
//                            continuation.resume(throwing: FeedError.parserFailed)
//                            return
//                        }
//                        do {
//                            try self.persist(atomItems: items)
//                        } catch {
//                            continuation.resume(throwing: error)
//                            return
//                        }
//                    case .json(let jsonFeed):
//                        continuation.resume(throwing: FeedError.parserFailed)
//                        return
//                    }
//                case .failure(_):
//                    continuation.resume(throwing: FeedError.parserFailed)
//                    return
//                }
//                continuation.resume(returning: ())
//            }
//        })
//    }
//}
//
//fileprivate func cleanRssData(_ rssData: Data) -> Data {
//    guard let rssString = String(data: rssData, encoding: .utf8) else { return rssData }
//    let cleanedString = rssString.replacingOccurrences(of: "<前編>", with: "&lt;前編&gt;")
//    return cleanedString.data(using: .utf8) ?? rssData
//}
