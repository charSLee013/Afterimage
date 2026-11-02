import AppKit
import ServiceManagement

enum LoginRegistration: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case failed(Int)

    var label: String {
        switch self {
        case .enabled: "已启用"
        case .notRegistered: "未启用"
        case .requiresApproval: "等待系统批准"
        case .notFound: "系统未找到登录项"
        case .failed(let code): "失败（\(code)）"
        }
    }
}

@MainActor
final class LoginController {
    private let service = SMAppService.mainApp
    private(set) var status: LoginRegistration = .notRegistered
    var onChange: (() -> Void)?

    init() { refresh() }

    func refresh() {
        switch service.status {
        case .enabled: status = .enabled
        case .notRegistered: status = .notRegistered
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        @unknown default: status = .failed(-1)
        }
        onChange?()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            status = .failed((error as NSError).code)
            onChange?()
        }
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
}
