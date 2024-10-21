//
//  VoIPCenter.swift
//  flutter_ios_voip_kit
//
//  Created by 須藤将史 on 2020/07/02.
//

import Foundation
import Flutter
import PushKit
import CallKit
import AVFoundation

extension String {
    internal init(deviceToken: Data) {
        self = deviceToken.map { String(format: "%.2hhx", $0) }.joined()
    }
}

class VoIPCenter: NSObject {

    // MARK: - event channel

    private let eventChannel: FlutterEventChannel
    private var eventSink: FlutterEventSink?

    private enum EventChannel: String {
        case onDidReceiveIncomingPush
        case onDidAcceptIncomingCall
        case onDidRejectIncomingCall
        
        case onDidUpdatePushToken
        case onDidActivateAudioSession
        case onDidDeactivateAudioSession
    }

    // MARK: - PushKit

    private let didUpdateTokenKey = "Did_Update_VoIP_Device_Token"
    private let pushRegistry: PKPushRegistry

    var token: String? {
        if let didUpdateDeviceToken = UserDefaults.standard.data(forKey: didUpdateTokenKey) {
            let token = String(deviceToken: didUpdateDeviceToken)
            print("🎈 VoIP didUpdateDeviceToken: \(token)")
            return token
        }

        guard let cacheDeviceToken = self.pushRegistry.pushToken(for: .voIP) else {
            return nil
        }

        let token = String(deviceToken: cacheDeviceToken)
        print("🎈 VoIP cacheDeviceToken: \(token)")
        return token
    }

    // MARK: - CallKit

    let callKitCenter: CallKitCenter
    
    fileprivate var audioSessionMode: AVAudioSession.Mode
    fileprivate let ioBufferDuration: TimeInterval
    fileprivate let audioSampleRate: Double

    init(eventChannel: FlutterEventChannel) {
        self.eventChannel = eventChannel
        self.pushRegistry = PKPushRegistry(queue: .main)
        self.pushRegistry.desiredPushTypes = [.voIP]
        self.callKitCenter = CallKitCenter()
        
        if let path = Bundle.main.path(forResource: "Info", ofType: "plist"), let plist = NSDictionary(contentsOfFile: path) {
            self.audioSessionMode = ((plist["FIVKAudioSessionMode"] as? String) ?? "audio") == "video" ? .videoChat : .voiceChat
            self.ioBufferDuration = plist["FIVKIOBufferDuration"] as? TimeInterval ?? 0.005
            self.audioSampleRate = plist["FIVKAudioSampleRate"] as? Double ?? 44100.0
        } else {
            self.audioSessionMode = .voiceChat
            self.ioBufferDuration = TimeInterval(0.005)
            self.audioSampleRate = 44100.0
        }
        
        super.init()
        self.eventChannel.setStreamHandler(self)
        self.pushRegistry.delegate = self
        self.callKitCenter.setup(delegate: self)
    }
}

extension VoIPCenter: PKPushRegistryDelegate {

    // MARK: - PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        print("🎈 VoIP didUpdate pushCredentials")
        UserDefaults.standard.set(pushCredentials.token, forKey: didUpdateTokenKey)
        
        self.eventSink?(["event": EventChannel.onDidUpdatePushToken.rawValue,
                         "token": pushCredentials.token.hexString])
    }

    // NOTE: iOS11 or more support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {

           savePayloadToSharedPrefs(payload: payload)
if !isVideoCall(payload: payload) {
        // Call the functions to end the current call

        self.callKitCenter.disconnected(reason: .remoteEnded)
                  UserDefaults.standard.set("call declined", forKey: "flutter.DECLINED_CALL")
        // Insert any additional code to end the call here
    }
    else{

let structuredData = createStructuredDataFromPayload(payload: payload)
        self.savePayloadAsStructuredString(structuredData: structuredData)
        let info = self.parse(payload: payload)
        let pay = payload.dictionaryPayload


        // Use default values if nil
        let callerName = (structuredData["doctorInfo"] as? [String: Any])?["name"] as? String ?? "default"
        let uuidString = (structuredData["callId"] as? String) ?? "ab49b87b-e46f-4c57-b683-8cef3df8bcdb"
        let callerId = (info?["callerId"] as? String) ?? "default-caller-id"
  self.sendStructuredDataEvent(payload: payload, callerName: callerName)
        self.callKitCenter.incomingCall(uuidString: uuidString, callerId: callerId, callerName: callerName) { error in
            if let error = error {

                return
            }
            // Call sendStructuredDataEvent instead of manually serializing and sending the payload

            completion()
        }
        }
    }

    // NOTE: iOS10 support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
          savePayloadToSharedPrefs(payload: payload)
        if !isVideoCall(payload: payload) {
                // Call the functions to end the current call
                self.callKitCenter.disconnected(reason: .remoteEnded)
                            UserDefaults.standard.set("call declined", forKey: "flutter.DECLINED_CALL")
                // Insert any additional code to end the call here
            }
            else{

let structuredData = createStructuredDataFromPayload(payload: payload)
        self.savePayloadAsStructuredString(structuredData: structuredData)
        // Extract callerName from the payload, defaulting to "Dr.Alexa(default)" if not present.
        let callerName = (structuredData["doctorInfo"] as? [String: Any])?["name"] as? String ?? "default"

        // Call the existing CallKitCenter logic to handle the incoming call UI.
        if let info = self.parse(payload: payload),
           let uuidString = info["id"] as? String,

           let callerId = info["callerId"] as? String {
  self.sendStructuredDataEvent(payload: payload, callerName: callerName)
            self.callKitCenter.incomingCall(uuidString: uuidString, callerId: callerId, callerName: callerName) { error in
                if let error = error {
                    print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                    return
                }

                // Use the sendStructuredDataEvent function to process and send the payload.

            }
        } else {
            print("❌ Error: Missing call information in payload.")
        }
        }

    }

    private func sendStructuredDataEvent(payload: PKPushPayload, callerName: String) {
        let structuredData = createStructuredDataFromPayload(payload: payload)
        self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue, "payload": structuredData, "incoming_caller_name": callerName])
    }

   private func savePayloadToSharedPrefs(payload: PKPushPayload) {
       // Convert payload dictionary to JSON data
       do {
           let jsonData = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: [])

           // Convert JSON data to string
           if let jsonString = String(data: jsonData, encoding: .utf8) {
                    UserDefaults.standard.set(jsonString, forKey: "flutter.PAYLOAD_STRING")
               // Retrieve existing string from UserDefaults
//               let existingString = UserDefaults.standard.string(forKey: "flutter.PAYLOAD_STRING") ?? ""
//
//               // Create a new entry with the current timestamp
//               let timestamp = Date().timeIntervalSince1970
//               let newEntry = "\(timestamp):\(jsonString)"
//
//               // Append the new entry to the existing string
//               let updatedString = existingString.isEmpty ? newEntry : "\(existingString)\n\(newEntry)"
//
//               // Save the updated string back to UserDefaults
//               UserDefaults.standard.set(updatedString, forKey: "flutter.PAYLOAD_STRING")
               print("Payload appended to shared preferences successfully.")
           }
       } catch {
           print("Error converting payload to string: \(error.localizedDescription)")
       }
   }

    private func isVideoCall(payload: PKPushPayload) -> Bool {
        if let dataField = payload.dictionaryPayload["data"] as? [String: Any],
           let type = dataField["type"] as? String {
            return type == "videoCall"
        }
        return false
    }

    private func createStructuredDataFromPayload(payload: PKPushPayload) -> [String: Any] {
        var structuredData: [String: Any] = [:]
        if let dataField = payload.dictionaryPayload["data"] as? [String: Any] {
            let currentDate = Date()
            let receiveDateInMilliseconds = Int(currentDate.timeIntervalSince1970 * 1000)
            let callId = payload.dictionaryPayload["id"] as? String ?? ""

            structuredData["chatId"] = dataField["chat_id"]
            structuredData["receiveDateInMilliseconds"] = receiveDateInMilliseconds
            structuredData["doctorInfo"] = ["name": dataField["doctor_name"], "imageUrl": dataField["doctor_avatar"]]
            structuredData["callId"] = callId
        }
        return structuredData
    }

 private func savePayloadAsStructuredString(structuredData: [String: Any]) {
     do {
         let jsonData = try JSONSerialization.data(withJSONObject: structuredData, options: [])
         if let jsonString = String(data: jsonData, encoding: .utf8) {
             UserDefaults.standard.set(jsonString, forKey: "flutter.LAST_INCOMING_CALL")
             print("Structured payload saved as string successfully.")
         }
     } catch {
         print("Error converting payload to string: \(error.localizedDescription)")
     }
 }

    private func parse(payload: PKPushPayload) -> [String: Any]? {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: .prettyPrinted)
            let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            let aps = json?["aps"] as? [String: Any]
            return aps?["alert"] as? [String: Any]
        } catch let error as NSError {
            print("❌ VoIP parsePayload: \(error.localizedDescription)")
            return nil
        }
    }
}

extension VoIPCenter: CXProviderDelegate {

    // MARK:  - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        print("🚫 VoIP providerDidReset")
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("🤙 VoIP CXStartCallAction")
        self.callKitCenter.connectingOutgoingCall()
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("✅ VoIP CXAnswerCallAction")
        self.callKitCenter.answerCallAction = action
        self.configureAudioSession()
        self.eventSink?(["event": EventChannel.onDidAcceptIncomingCall.rawValue,
                         "uuid": self.callKitCenter.uuidString as Any,
                         "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("❎ VoIP CXEndCallAction")

        if (self.callKitCenter.isCalleeBeforeAcceptIncomingCall) {

            self.eventSink?(["event": EventChannel.onDidRejectIncomingCall.rawValue,
                             "uuid": self.callKitCenter.uuidString as Any,
                             "incoming_caller_id": self.callKitCenter.incomingCallerId as Any])
        }

        self.callKitCenter.disconnected(reason: .remoteEnded)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("🔈 VoIP didActivate audioSession")
        self.eventSink?(["event": EventChannel.onDidActivateAudioSession.rawValue])
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("🔇 VoIP didDeactivate audioSession")
        self.eventSink?(["event": EventChannel.onDidDeactivateAudioSession.rawValue])
    }
    
    // This is a workaround for known issue, when audio doesn't start from lockscreen call
    // https://stackoverflow.com/questions/55391026/no-sound-after-connecting-to-webrtc-when-app-is-launched-in-background-using-pus
    private func configureAudioSession() {
        let sharedSession = AVAudioSession.sharedInstance()
        do {
            try sharedSession.setCategory(.playAndRecord,
                                          options: [AVAudioSession.CategoryOptions.allowBluetooth,
                                                    AVAudioSession.CategoryOptions.defaultToSpeaker])
            try sharedSession.setMode(audioSessionMode)
            try sharedSession.setPreferredIOBufferDuration(ioBufferDuration)
            try sharedSession.setPreferredSampleRate(audioSampleRate)
        } catch {
            print("❌ VoIP Failed to configure `AVAudioSession`")
        }
    }
}

extension VoIPCenter: FlutterStreamHandler {

    // MARK: - FlutterStreamHandler（event channel）

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
}
