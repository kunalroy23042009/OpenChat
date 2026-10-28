import Flutter
import UIKit
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate, CXProviderDelegate {
    private let callKitProvider = CXProvider(configuration: AppDelegate.providerConfiguration)
    private let pushRegistry = PKPushRegistry(queue: DispatchQueue.main)
    private var currentCallUUID: UUID?
    private var pendingIncomingCall: [String: Any]?

    static var providerConfiguration: CXProviderConfiguration {
        let config = CXProviderConfiguration(localizedName: "OpenChat")
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        config.ringtoneSound = "ringtone.caf"
        return config
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register for VoIP pushes
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]

        // Setup CallKit provider
        callKitProvider.setDelegate(self, queue: DispatchQueue.main)

        // Handle flutter_callkit_incoming events
        SwiftFlutterCallkitIncomingPlugin.sharedInstance().setDelegate(self)

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // MARK: - PKPushRegistryDelegate

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("VoIP push token: \(token)")
        // Send token to Dart side
        SwiftFlutterCallkitIncomingPlugin.sharedInstance().setVoIPToken(token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("VoIP push token invalidated")
        SwiftFlutterCallkitIncomingPlugin.sharedInstance().setVoIPToken("")
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("Received VoIP push: \(payload.dictionaryPayload)")

        guard let data = payload.dictionaryPayload as? [String: Any],
              let inviteId = data["invite"] as? String,
              let callerId = data["peer"] as? String,
              let callerName = data["name"] as? String,
              let video = data["video"] as? Bool else {
            completion()
            return
        }

        // Store for when Flutter is ready
        pendingIncomingCall = [
            "inviteId": inviteId,
            "callerId": callerId,
            "callerName": callerName,
            "video": video
        ]

        // Report to CallKit
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = video
        update.localizedCallerName = callerName

        let callUUID = UUID()
        currentCallUUID = callUUID

        callKitProvider.reportNewIncomingCall(with: callUUID, update: update) { error in
            if error == nil {
                print("CallKit reported incoming call: \(callUUID)")
            } else {
                print("CallKit error: \(error!)")
            }
            completion()
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        print("CallKit provider reset")
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let callUUID = action.callUUID as UUID? else {
            action.fail()
            return
        }
        print("CallKit answer action for: \(callUUID)")

        // Forward to Flutter
        SwiftFlutterCallkitIncomingPlugin.sharedInstance().onAnswerCall(uuid: callUUID.uuidString)

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let callUUID = action.callUUID as UUID? else {
            action.fail()
            return
        }
        print("CallKit end action for: \(callUUID)")

        SwiftFlutterCallkitIncomingPlugin.sharedInstance().onDeclineCall(uuid: callUUID.uuidString)

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        // Handle mute
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Handle hold
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        print("CallKit action timed out: \(action)")
    }

    // MARK: - FlutterCallkitIncomingDelegate

    func didActivateAudioSession() {
        print("Audio session activated")
    }

    func didDeactivateAudioSession() {
        print("Audio session deactivated")
    }

    // Called when Flutter wants to start an outgoing call
    func startCall(uuid: String, handle: String, video: Bool, completion: @escaping (Bool) -> Void) {
        let callUUID = UUID(uuidString: uuid) ?? UUID()
        currentCallUUID = callUUID

        let startCallAction = CXStartCallAction(call: callUUID, handle: CXHandle(type: .generic, value: handle))
        startCallAction.isVideo = video

        let transaction = CXTransaction(action: startCallAction)
        callKitProvider.request(transaction) { error in
            if error == nil {
                print("Outgoing call started: \(callUUID)")
                completion(true)
            } else {
                print("Outgoing call failed: \(error!)")
                completion(false)
            }
        }
    }

    // Called when Flutter wants to end a call
    func endCall(uuid: String, completion: @escaping (Bool) -> Void) {
        guard let callUUID = UUID(uuidString: uuid) else {
            completion(false)
            return
        }

        let endCallAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction(action: endCallAction)
        callKitProvider.request(transaction) { error in
            if error == nil {
                print("Call ended: \(callUUID)")
                completion(true)
            } else {
                print("End call failed: \(error!)")
                completion(false)
            }
        }
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    }
}