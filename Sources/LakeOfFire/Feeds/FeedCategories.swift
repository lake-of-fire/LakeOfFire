//import Foundation
//import SwiftUI
//import RealmSwift
//import LakeKit
//import ManabiWeb
//import ManabiCommon
//
//struct FeedCategories<CategoryView: View>: View {
//    let categoryView: (_ category: ManabiCommon.FeedCategory) -> CategoryView
//    @ObservedResults(FeedCategory.self, configuration: SharedRealmConfigurer.configuration, where: { $0.isDeleted == false }) var categories
//    
//    var body: some View {
//        ForEach(categories) { category in
//            categoryView(category)
//        }
//    }
//}
//
//struct ChunkedFeedCategories<CategoryView: View>: View {
//    var chunkSize = 3
//    
//    var body: some View {
//        ForEach(Array(categories).chunked(into: chunkSize)) { chunk in
//            categoryView(category)
//        }
//    }
//}
