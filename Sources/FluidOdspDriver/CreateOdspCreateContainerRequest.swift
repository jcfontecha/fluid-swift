import FluidDriverDefinitions
import FluidJS

/// createOdspCreateContainerRequest.ts: the request a host resolves to create a file in the folder
/// at `filePath` (an empty path is the drive root). Share links and package info are not ported.
public func createOdspCreateContainerRequest(siteUrl: String, driveId: String, filePath: String, fileName: String) -> IRequest {
    var createNew = JSObject<JSONValue>()
    createNew["fileName"] = .string(JSString(fileName))
    var headers = JSObject<JSONValue>()
    headers["createNew"] = .object(createNew)
    return IRequest(url: siteUrl + "?driveId=" + encodeOdspComponent(driveId) + "&path=" + encodeOdspComponent(filePath), headers: headers)
}
