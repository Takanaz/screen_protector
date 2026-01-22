import Flutter
import UIKit
import ScreenProtectorKit
#if canImport(FirebaseCrashlytics)
    import FirebaseCrashlytics
#endif

public class SwiftScreenProtectorPlugin: NSObject, FlutterPlugin {
    private static var channel: FlutterMethodChannel? = nil
    private var screenProtectorKit: ScreenProtectorKit?
    private weak var trackedWindow: UIWindow?
    private var sceneObservers: [NSObjectProtocol] = []
    private var preventScreenshotState: ProtectionState = .idle
    private var blurProtectionState: ProtectionState = .idle
    private var imageProtectionState: ProtectionState = .idle
    private var colorProtectionState: ProtectionState = .idle
    private var imageProtectionName: String = ""
    private var colorProtectionHex: String = ""
    private var isProtectionEnabled: Bool = false
    private var pendingScreenshotState: ProtectionState? = nil
    private var lastAppliedScreenshotState: ProtectionState = .idle
    private var screenshotStateWorkItem: DispatchWorkItem? = nil
    private let screenshotStateDelay: TimeInterval = 0.2
    private var lastDidBecomeActiveAt: TimeInterval = 0
    private let reparentCooldownAfterActive: TimeInterval = 2.0
    
    override public init() {
        super.init()
        observeSceneLifecycle()
    }
    
    private func initializeManagerIfNeeded(forceRecreate: Bool = false) {
        if Thread.isMainThread == false {
            DispatchQueue.main.async { [weak self] in
                self?.initializeManagerIfNeeded(forceRecreate: forceRecreate)
            }
            return
        }
        
        let currentWindow = Self.activeWindow()
        logWindowState(context: "initializeManagerIfNeeded", window: currentWindow)
        
        if forceRecreate || (trackedWindow != nil && currentWindow != nil && currentWindow !== trackedWindow) {
            self.didBecomeActive(.dataLeakage)
            tearDownManager()
        }
        
        guard screenProtectorKit == nil else {
            if let window = currentWindow {
                screenProtectorKit?.updateWindowIfNeeded(window)
            }
            return
        }
        guard let window = currentWindow else {
            self.log()
            // Disable data leakage protection when no active UIWindow is available
            self.didBecomeActive(.dataLeakage)
            print("[screen_protector] Active UIWindow is not available.")
            return
        }
        
        self.screenProtectorKit = ScreenProtectorKit(window: window)
        
        self.trackedWindow = window
        scheduleApplyPendingScreenshotState()
    }

    private func scheduleApplyPendingScreenshotState() {
        screenshotStateWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.initializeManagerIfNeeded()
            guard let pending = self.pendingScreenshotState else { return }
            guard self.screenProtectorKit != nil else {
                self.scheduleApplyPendingScreenshotState()
                return
            }
            guard Self.activeWindow() != nil else {
                self.scheduleApplyPendingScreenshotState()
                return
            }
            guard pending == self.preventScreenshotState else {
                self.pendingScreenshotState = nil
                return
            }
            self.pendingScreenshotState = nil
            if pending == .on {
                if !self.isProtectionEnabled {
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if self.lastDidBecomeActiveAt > 0 {
                    let elapsed = now - self.lastDidBecomeActiveAt
                    if elapsed < self.reparentCooldownAfterActive {
                        self.scheduleApplyPendingScreenshotState()
                        return
                    }
                }
                if self.lastAppliedScreenshotState == .on {
                    return
                }
                self.logWindowState(context: "applyPendingScreenshotOn", window: Self.activeWindow())
                self.screenProtectorKit?.configurePreventionScreenshot()
                self.screenProtectorKit?.prepareReparentForScreenshotOn()
                self.screenProtectorKit?.enabledPreventScreenshot()
                self.lastAppliedScreenshotState = .on
            } else if pending == .off {
                if self.lastAppliedScreenshotState == .off {
                    return
                }
                self.logWindowState(context: "applyPendingScreenshotOff", window: Self.activeWindow())
                self.screenProtectorKit?.disablePreventScreenshot()
                self.lastAppliedScreenshotState = .off
            }
        }
        screenshotStateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + screenshotStateDelay, execute: workItem)
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        SwiftScreenProtectorPlugin.channel = FlutterMethodChannel(name: "screen_protector", binaryMessenger: registrar.messenger())
        let instance = SwiftScreenProtectorPlugin()
        registrar.addMethodCallDelegate(instance, channel: SwiftScreenProtectorPlugin.channel!)
        registrar.addApplicationDelegate(instance)
        
        // Initialize manager safely on main thread
        DispatchQueue.main.async {
            instance.initializeManagerIfNeeded()
        }
    }
    
    public func willResignActive(_ type: ProtectionType) {
        if type == .dataLeakage {
            // Protect Data Leakage - ON
            if colorProtectionState == .on {
                onMain { self.screenProtectorKit?.enabledColorScreen(hexColor: self.colorProtectionHex) }
            } else if imageProtectionState == .on {
                onMain { self.screenProtectorKit?.enabledImageScreen(named: self.imageProtectionName) }
            } else if blurProtectionState == .on {
                onMain { self.screenProtectorKit?.enabledBlurScreen() }
            }
        }
        
        if type == .screenshot {
            // Prevent Screenshot - OFF
            if preventScreenshotState == .off {
                onMain { self.screenProtectorKit?.disablePreventScreenshot() }
            }
        }
    }
    
    public func didBecomeActive(_ type: ProtectionType) {
        if type == .dataLeakage {
            // Protect Data Leakage - OFF
            if colorProtectionState == .on {
                onMain { self.screenProtectorKit?.disableColorScreen() }
            } else if imageProtectionState == .on {
                onMain { self.screenProtectorKit?.disableImageScreen() }
            } else if blurProtectionState == .on {
                onMain { self.screenProtectorKit?.disableBlurScreen() }
            }
        }
        
        if type == .screenshot {
            // Prevent Screenshot - ON
            if preventScreenshotState == .on && isProtectionEnabled {
                self.pendingScreenshotState = .on
                self.scheduleApplyPendingScreenshotState()
            }
        }
    }
    
    public func applicationWillResignActive(_ application: UIApplication) {
        // Protect Data Leakage - ON && Prevent Screenshot - OFF
        DispatchQueue.main.async {
            self.logWindowState(context: "applicationWillResignActive", window: Self.activeWindow())
            self.initializeManagerIfNeeded()
            self.willResignActive(.dataLeakage)
            // ここで reparent を外す（復帰クラッシュ回避）
            if self.preventScreenshotState == .on {
                self.screenProtectorKit?.forceRestoreWindowLayerIfPossible()
            }
        }
    }
    
    public func applicationDidBecomeActive(_ application: UIApplication) {
        // Protect Data Leakage - OFF && Prevent Screenshot - ON
        DispatchQueue.main.async {
            self.lastDidBecomeActiveAt = ProcessInfo.processInfo.systemUptime
            self.logWindowState(context: "applicationDidBecomeActive", window: Self.activeWindow())
            self.initializeManagerIfNeeded()
            self.didBecomeActive(.dataLeakage)
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        DispatchQueue.main.async {
            self.initializeManagerIfNeeded()
            switch call.method {
            case "protectDataLeakageWithBlur":
                self.blurProtectionState = .on
                result(true)
                break
            case "protectDataLeakageWithBlurOff":
                self.blurProtectionState = .off
                self.screenProtectorKit?.disableBlurScreen()
                result(true)
                break
            case "protectDataLeakageWithImage":
                self.imageProtectionName = (args?["name"] as? String) ?? "LaunchImage"
                self.imageProtectionState = .on
                result(true)
                break
            case "protectDataLeakageWithImageOff":
                self.imageProtectionName = ""
                self.imageProtectionState = .off
                result(true)
                break
            case "protectDataLeakageWithColor":
                guard let hexColor = args?["hexColor"] as? String else {
                    result(false)
                    return
                }
                self.colorProtectionHex = hexColor
                self.colorProtectionState = .on
                break
            case "protectDataLeakageWithColorOff":
                self.colorProtectionHex = ""
                self.colorProtectionState = .off
                self.screenProtectorKit?.disableColorScreen()
                result(true)
                break
            case "protectDataLeakageOff":
                self.colorProtectionState = .off
                self.imageProtectionState = .off
                self.blurProtectionState = .off
                self.screenProtectorKit?.disableColorScreen()
                self.screenProtectorKit?.disableImageScreen()
                self.screenProtectorKit?.disableBlurScreen()
                result(true)
                break
            case "preventScreenshotOn":
                if self.preventScreenshotState == .on, self.lastAppliedScreenshotState == .on {
                    result(true)
                    break
                }
                self.preventScreenshotState = .on
                self.logWindowState(context: "preventScreenshotOn", window: Self.activeWindow())
                if self.isProtectionEnabled {
                    self.pendingScreenshotState = .on
                    self.scheduleApplyPendingScreenshotState()
                }
                result(true)
                break
            case "preventScreenshotOff":
                if self.preventScreenshotState == .off, self.lastAppliedScreenshotState == .off {
                    result(true)
                    break
                }
                self.preventScreenshotState = .off
                self.logWindowState(context: "preventScreenshotOff", window: Self.activeWindow())
                self.pendingScreenshotState = .off
                self.scheduleApplyPendingScreenshotState()
                result(true)
                break
            case "setProtectionEnabled":
                let enabled = args?["enabled"] as? Bool ?? false
                self.isProtectionEnabled = enabled
                if enabled {
                    if self.preventScreenshotState == .on {
                        self.pendingScreenshotState = .on
                        self.scheduleApplyPendingScreenshotState()
                    }
                } else {
                    self.pendingScreenshotState = .off
                    self.scheduleApplyPendingScreenshotState()
                }
                result(true)
                break
            case "addListener":
                self.screenProtectorKit?.removeScreenshotObserver()
                self.screenProtectorKit?.screenshotObserver {
                    SwiftScreenProtectorPlugin.channel?.invokeMethod("onScreenshot", arguments: nil)
                }
                
                if #available(iOS 11.0, *) {
                    self.screenProtectorKit?.removeScreenRecordObserver()
                    self.screenProtectorKit?.screenRecordObserver { isRecording in
                        SwiftScreenProtectorPlugin.channel?.invokeMethod("onScreenRecord", arguments: isRecording)
                    }
                }
                
                result("listened")
                break
            case "removeListener":
                self.screenProtectorKit?.removeAllObserver()
                result("removed")
                break
            case "isRecording":
                result(self.screenProtectorKit?.screenIsRecording() ?? false)
                break
            default:
                result(false)
                break
            }
        }
    }
    
    private func observeSceneLifecycle() {
        guard #available(iOS 13.0, *) else { return }
        let center = NotificationCenter.default
        
        let disconnectObserver = center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] notification in
            guard let scene = notification.object as? UIWindowScene,
                  let trackedScene = self?.trackedWindow?.windowScene,
                  trackedScene == scene else { return }
            self?.tearDownManager()
        }
        
        let foregroundObserver = center.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.lastDidBecomeActiveAt = ProcessInfo.processInfo.systemUptime
            self?.initializeManagerIfNeeded()
        }
        
        sceneObservers.append(contentsOf: [disconnectObserver, foregroundObserver])
    }
    
    private func tearDownManager() {
        onMain { self.screenProtectorKit?.removeAllObserver() }
        screenProtectorKit = nil
        trackedWindow = nil
    }
    
    private static func activeWindow() -> UIWindow? {
        // FlutterViewController.view.window を最優先
        if let flutterWindow = currentFlutterWindowFromView() {
            return flutterWindow
        }
        if #available(iOS 13.0, *) {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive }
                .flatMap { $0.windows }
            let stableWindows = windows.filter { isStableWindow($0) }
            return stableWindows.first { $0.isKeyWindow } ?? stableWindows.first
        } else {
            let stableWindows = UIApplication.shared.windows.filter { isStableWindow($0) }
            return stableWindows.first { $0.isKeyWindow } ?? stableWindows.first
        }
    }

    private static func isFlutterRootWindow(_ window: UIWindow) -> Bool {
        return window.rootViewController is FlutterViewController
    }

    private static func currentFlutterWindowFromView() -> UIWindow? {
        let allWindows: [UIWindow]
        if #available(iOS 13.0, *) {
            allWindows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
        } else {
            allWindows = UIApplication.shared.windows
        }
        if let flutterWindow = allWindows.first(where: { isFlutterRootWindow($0) }) {
            return flutterWindow.rootViewController?.view.window
        }
        return nil
    }

    private static func isStableWindow(_ window: UIWindow) -> Bool {
        if window.isHidden || window.alpha <= 0.0 {
            return false
        }
        let screenBounds = (window.windowScene?.screen.bounds ?? UIScreen.main.bounds).integral
        return window.bounds.integral == screenBounds
    }
    
    private func log() {
        debugPrint("[screen_protector] screenProtectorKit: \(screenProtectorKit)")
        debugPrint("[screen_protector] trackedWindow: \(trackedWindow)")
        debugPrint("[screen_protector] sceneObservers: \(sceneObservers)")
        debugPrint("[screen_protector] preventScreenshotState: \(preventScreenshotState)")
        debugPrint("[screen_protector] blurProtectionState: \(blurProtectionState)")
        debugPrint("[screen_protector] imageProtectionState: \(imageProtectionState)")
        debugPrint("[screen_protector] colorProtectionState: \(colorProtectionState)")
        debugPrint("[screen_protector] imageProtectionName: \(imageProtectionName)")
        debugPrint("[screen_protector] colorProtectionHex: \(colorProtectionHex)")
    }

    private func logWindowState(context: String, window: UIWindow?) {
        guard let window = window else {
            let message = "[screen_protector] \(context): window=nil"
            debugPrint(message)
            logToCrashlytics(message)
            return
        }
        let bounds = window.bounds
        let frame = window.frame
        let sceneState = (window.windowScene?.activationState).map { "\($0.rawValue)" } ?? "nil"
        let isKey = window.isKeyWindow
        let rootVC = String(describing: window.rootViewController)
        let message =
            "[screen_protector] \(context): isKey=\(isKey) scene=\(sceneState) " +
            "bounds=\(bounds) frame=\(frame) rootVC=\(rootVC)"
        debugPrint(message)
        logToCrashlytics(message)
    }

    private func logToCrashlytics(_ message: String) {
        #if canImport(FirebaseCrashlytics)
            Crashlytics.crashlytics().log(message)
        #endif
    }
    
    deinit {
        screenshotStateWorkItem?.cancel()
        sceneObservers.forEach { NotificationCenter.default.removeObserver($0) }
        tearDownManager()
    }
}

