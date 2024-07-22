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
            print("🎈 VoIP didReceiveIncomingPushWith completion: \(payload.dictionaryPayload)")

            self.savePayloadAsStructuredString(payload: payload)
            let info = self.parse(payload: payload)
            let pay = payload.dictionaryPayload
            print("갑니다잉")
            print(info)
            print(pay)

            // nil인 경우 기본값을 사용합니다.
           let callerName = payload.dictionaryPayload["callerName"] as? String ?? "Dr.Alexa(default)"
            let uuidString = (info?["id"] as? String) ?? "ab49b87b-e46f-4c57-b683-8cef3df8bcdb"
            let callerId = (info?["callerId"] as? String) ?? "default-caller-id"

            self.callKitCenter.incomingCall(uuidString: uuidString, callerId: callerId, callerName: callerName) { error in
                if let error = error {
                    print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                    return
                }
                do {
                    let payloadData = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: [])
                    if let payloadString = String(data: payloadData, encoding: .utf8) {
                       self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue, "payload": ["value": payloadString], "incoming_caller_name": callerName])
                    }
                } catch {
                    print("Error serializing payload to string: \(error.localizedDescription)")
                }
                completion()
            }
     }

    // NOTE: iOS10 support

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType) {
        print("🎈 VoIP didReceiveIncomingPushWith: \(payload.dictionaryPayload)")

        self.savePayloadAsStructuredString(payload: payload)
        let info = self.parse(payload: payload)
        let callerName = payload.dictionaryPayload["callerName"] as? String ?? "Dr.Alexa(default)"
        self.callKitCenter.incomingCall(uuidString: info?["id"] as! String,
                                        callerId: info?["callerId"] as! String,
                                        callerName: callerName) { error in
            if let error = error {
                print("❌ reportNewIncomingCall error: \(error.localizedDescription)")
                return
            }
           do {
               let payloadData = try JSONSerialization.data(withJSONObject: payload.dictionaryPayload, options: [])
               if let payloadString = String(data: payloadData, encoding: .utf8) {
                  self.eventSink?(["event": EventChannel.onDidReceiveIncomingPush.rawValue, "payload": ["value": payloadString], "incoming_caller_name": callerName])
               }
           } catch {
               print("Error serializing payload to string: \(error.localizedDescription)")
           }
        }
    }

  private func savePayloadAsStructuredString(payload: PKPushPayload) {
      do {
          // Step 1 & 2: Extract and parse the 'data' field from the payload
          if let dataField = payload.dictionaryPayload["data"] as? [String: Any] {
              // Step 3: Get the current date in milliseconds
              let currentDate = Date()
              let receiveDateInMilliseconds = Int(currentDate.timeIntervalSince1970 * 1000)

              // Step 4: Extract the 'id' field from the payload for callId
              let callId = payload.dictionaryPayload["id"] as? String ?? ""

              // Step 5: Create a new dictionary with the required fields
              var structuredData: [String: Any] = [:]
              structuredData["chatId"] = dataField["chat_Id"]
              structuredData["receiveDateInMilliseconds"] = receiveDateInMilliseconds
              structuredData["doctorInfo"] = ["name": dataField["doctor_name"], "imageUrl": dataField["doctor_avatar"]]
              structuredData["callId"] = callId

              // Step 6: Convert the new dictionary to a JSON string
              let jsonData = try JSONSerialization.data(withJSONObject: structuredData, options: [])
              if let jsonString = String(data: jsonData, encoding: .utf8) {
                  // Step 7: Save the JSON string to UserDefaults
                  UserDefaults.standard.set(jsonString, forKey: "flutter.LAST_INCOMING_CALL")
                  print("Structured payload saved as string successfully.")
              }
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
