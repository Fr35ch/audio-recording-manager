import Foundation

enum CheckStatus {
    case pending
    case running
    case passed
    case failed(String)
}

struct CheckResult {
    let name: String
    var status: CheckStatus = .pending
    var detail: String = ""
}
