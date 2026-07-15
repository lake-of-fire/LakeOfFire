import SwiftUI
import Nuke
import NukeUI
import LakeOfFireContent

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

func readerImageData(url: URL) async throws -> Data? {
    guard url.scheme == "reader-file" && url.host == "file" else { return nil }

    guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value else { return nil }

    guard let readerFileURL = url.deletingQuery else { return nil }
    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
        forPackageURL: readerFileURL,
        readerFileManager: ReaderFileManager.shared
    )
    return try cachedSource.source.readEntry(subpath: subpathValue)
}

fileprivate final class ReaderImageLoadTask: Nuke.Cancellable, @unchecked Sendable {
    var task: Task<Void, Never>?
    var fallbackTask: (any Nuke.Cancellable)?

    func cancel() {
        task?.cancel()
        fallbackTask?.cancel()
    }
}

fileprivate final class ReaderImageLoadCallbacks: @unchecked Sendable {
    let didReceiveData: (Data, URLResponse) -> Void
    let completion: (Error?) -> Void

    init(
        didReceiveData: @escaping (Data, URLResponse) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        self.didReceiveData = didReceiveData
        self.completion = completion
    }
}

fileprivate final class ReaderImageDataLoader: DataLoading, @unchecked Sendable {
    private let defaultDataLoader: DataLoading = DataLoader()
    private let interceptor: @Sendable (URL) async throws -> Data?

    init(interceptor: @escaping @Sendable (URL) async throws -> Data?) {
        self.interceptor = interceptor
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping (Data, URLResponse) -> Void,
        completion: @escaping (Error?) -> Void
    ) -> any Nuke.Cancellable {
        let task = ReaderImageLoadTask()
        let callbacks = ReaderImageLoadCallbacks(
            didReceiveData: didReceiveData,
            completion: completion
        )

        guard let url = request.url else {
            callbacks.completion(NSError(domain: "ReaderImageDataLoader", code: 0, userInfo: nil))
            return task
        }

        task.task = Task {
            do {
                if let data = try await interceptor(url) {
                    guard !Task.isCancelled else { return }
                    if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
                        callbacks.didReceiveData(data, response)
                        callbacks.completion(nil)
                    } else {
                        callbacks.completion(NSError(domain: "ReaderImageDataLoader", code: 0, userInfo: nil))
                    }
                    return
                }
            } catch {
                guard !Task.isCancelled else { return }
                debugPrint("Error loading image URL:", url, error)
            }

            guard !Task.isCancelled else { return }
            task.fallbackTask = defaultDataLoader.loadData(
                with: request,
                didReceiveData: callbacks.didReceiveData,
                completion: callbacks.completion
            )
        }

        return task
    }
}

fileprivate struct ReaderAsyncImage: View {
    let url: URL
    let contentMode: ContentMode
    let maxWidth: CGFloat?
    let minHeight: CGFloat?
    let maxHeight: CGFloat?
    let cornerRadius: CGFloat?
    let imagePipeline: ImagePipeline

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight, alignment: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? 0))
            } else if state.error != nil {
                Color.clear
            } else {
                Color.gray
                    .opacity(0.7)
                    .frame(minHeight: minHeight)
            }
        }
        .priority(.high)
        .pipeline(imagePipeline)
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
    }
}

public struct ReaderImage: View {
    let url: URL
    let contentMode: ContentMode
    var maxWidth: CGFloat? = nil
    var minHeight: CGFloat? = nil
    var maxHeight: CGFloat? = nil
    var cornerRadius: CGFloat? = nil
    
    public init(
        _ url: URL,
        contentMode: ContentMode = .fill,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        cornerRadius: CGFloat? = nil
    ) {
        self.url = url
        self.contentMode = contentMode
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.cornerRadius = cornerRadius
    }
    
    public var body: some View {
        ReaderAsyncImage(
            url: url,
            contentMode: contentMode,
            maxWidth: maxWidth,
            minHeight: minHeight,
            maxHeight: maxHeight,
            cornerRadius: cornerRadius,
            imagePipeline: Self.imagePipeline
        )
    }

    private static let imagePipeline: ImagePipeline = {
        var configuration = ImagePipeline.Configuration.withDataCache
        configuration.dataLoader = ReaderImageDataLoader(interceptor: { url in
            try await readerImageData(url: url)
        })
        return ImagePipeline(configuration: configuration)
    }()
}
