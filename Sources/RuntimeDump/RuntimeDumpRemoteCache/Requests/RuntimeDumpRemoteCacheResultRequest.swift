import RequestSender

class RuntimeDumpRemoteCacheResultRequest: NetworkRequest {
    typealias Response = RuntimeQueryResult

    public let httpMethod: HTTPMethod
    public let pathWithLeadingSlash: String
    public let payload: EmptyData? = nil

    public init(
        httpMethod: HTTPMethod,
        pathWithLeadingSlash: String
    ) {
        self.httpMethod = httpMethod
        self.pathWithLeadingSlash = pathWithLeadingSlash
    }
}
