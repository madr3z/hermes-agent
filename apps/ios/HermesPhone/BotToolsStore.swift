import Foundation
import Observation
import HermesGateway

func botToolsError(_ error: Error) -> String {
    if case GatewayError.rpc(let code, _) = error, code == -32601 {
        return "This gateway does not support this feature yet. Update its Hermes runtime on your Mac."
    }
    return error.localizedDescription
}
