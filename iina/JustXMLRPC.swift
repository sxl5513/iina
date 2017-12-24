//
//  JustXMLRPC.swift
//  iina
//
//  Created by lhc on 11/3/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa
import Just

fileprivate let ISO8601FormatString = "yyyyMMdd'T'HH:mm:ss"


class JustXMLRPC {

  struct XMLRPCError: Error {
    var method: String
    var httpCode: Int
    var reason: String
    var readableDescription: String {
      return "\(method): [\(httpCode)] \(reason)"
    }
  }

  enum Result {
    case ok(Any)
    case failure(Any)
    case error(XMLRPCError)
  }

  /** (success, result) */
  typealias CallBack = (Result) -> Void

  private static let iso8601DateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = ISO8601FormatString
    return formatter
  }()

  var location: String

  init(_ loc: String) {
    self.location = loc
  }

  /**
   *  Call a XMLRPC method.
   */
  func call(_ method: String, _ parameters: [Any] = [], callback: @escaping CallBack) {
    // Construct request XML
    let reqXML = XMLDocument()
    reqXML.version = "1.0"
    reqXML.characterEncoding = "UTF-8"
    //  - method call
    let eMethodCall = XMLElement.init(name: "methodCall")
    reqXML.setRootElement(eMethodCall)
    //  - method name
    eMethodCall.addChild(XMLElement.init(name: "methodName", stringValue: method))
    //  - params
    eMethodCall.addChild(XMLElement.init(name: "params"))
    let eParams = eMethodCall.element(forName: "params")!
    for param in parameters {
      let eParam = XMLElement.init(name: "param")
      eParam.addChild(JustXMLRPC.toValueNode(param))
      eParams.addChild(eParam)
    }
    // Request
    Just.post(location, requestBody: reqXML.xmlData) { response in
      if response.ok, let content = response.content, let responseDoc = try? XMLDocument(data: content) {
        let rootElement = responseDoc.rootElement()!
        let eParam = rootElement.element(forName: "params")!.element(forName: "param")!
        // let eParam = responseDoc.findChild("params")!.findChild("param")!
        let eFault = rootElement.element(forName: "fault")
        // let eFault = responseDoc.findChild("fault")!
        if (eParam.children?.count ?? 0) == 1 {
          // if success
          callback(.ok(JustXMLRPC.value(fromValueNode: eParam.elements(forName: "value").first!)))
        } else if (eFault?.children?.count ?? 0) == 1 {
          // if fault
          callback(.failure(JustXMLRPC.value(fromValueNode: eParam.elements(forName: "value").first!)))
        } else {
          // unexpected return value
          callback(.error(XMLRPCError(method: method, httpCode: response.statusCode ?? 0, reason: "Bad response")))
        }
      } else {
        // http error
        callback(.error(XMLRPCError(method: method, httpCode: response.statusCode ?? 0, reason: response.reason)))
      }
    }
  }

  private static func toValueNode(_ value: Any) -> XMLElement {
    let eValue = XMLElement.init(name: "value")
    switch value {
    case is Bool:
      let vBool = value as! Bool
      eValue.addChild(XMLElement.init(name: "boolean", stringValue: vBool ? "1" : "0"))
    case is Int, is Int8, is Int16, is UInt, is UInt8, is UInt16:
      eValue.addChild(XMLElement.init(name: "int", stringValue: "\(value)"))
    case is Float, is Double:
      eValue.addChild(XMLElement.init(name: "double", stringValue: "\(value)"))
    case is String:
      let vString = value as! String
      eValue.addChild(XMLElement.init(name: "string", stringValue: vString))
    case is Date:
      let vDate = value as! Date
      eValue.addChild(XMLElement.init(name: "dateTime.iso8601", stringValue: iso8601DateFormatter.string(from: vDate)))
    case is Data:
      let vData = value as! Data
      eValue.addChild(XMLElement.init(name: "base64", stringValue: vData.base64EncodedString()))
    case is [Any]:
      let vArray = value as! [Any]
      eValue.addChild(XMLElement.init(name: "array"))
      eValue.element(forName: "array")!.addChild(XMLElement.init(name: "data"))
      // (eValue.child(at: 0) as! XMLElement).addChild(XMLElement.init(name: "data"))
      let eArrayData = eValue.element(forName: "array")!.element(forName: "data")!
      // let eArrayData = eValue.child(at: 0)?.child(at: 0) as! XMLElement
      for e in vArray {
        eArrayData.addChild(JustXMLRPC.toValueNode(e))
      }
    case is [String: Any]:
      let vDic = value as! [String: Any]
      eValue.addChild(XMLElement.init(name: "struct"))
      let eStruct = eValue.element(forName: "struct")!
      // let eStruct = eValue.child(at: 0) as! XMLElement
      for (k, v) in vDic {
        eStruct.addChild(XMLElement.init(name: "member"))
        let eMember = eStruct.element(forName: "member")!
        // let eMember = eStruct.child(at: 0) as! XMLElement
        eMember.addChild(XMLElement.init(name: "name", stringValue: k))
        eMember.addChild(JustXMLRPC.toValueNode(v))
      }
    default:
      Utility.log("XMLRPC: Value type not supported")
    }
    return eValue
  }

  private static func value(fromValueNode node: XMLElement) -> Any {
    let eNode = node.child(at: 0) as! XMLElement
    switch eNode.name! {
    case "boolean":
      return Bool(eNode.stringValue!) as Any
    case "int", "i4":
      return Int(eNode.stringValue!) as Any
    case "double":
      return Double(eNode.stringValue!) as Any
    case "string":
      return (eNode.stringValue!) as Any
    case "dateTime.iso8601":
      return iso8601DateFormatter.date(from: eNode.stringValue!)!
    case "base64":
      return Data(base64Encoded: eNode.stringValue!) ?? Data()
    case "array":
      var resultArray: [Any] = []
      for n in eNode.element(forName: "data")?.element(forName: "value")?.children ?? [] {
        resultArray.append(JustXMLRPC.value(fromValueNode: n as! XMLElement))
      }
      return resultArray
    case "struct":
      var resultDict: [String: Any] = [:]
      for m in eNode.elements(forName: "member") {
        let key = m.element(forName: "name")!.stringValue!
        let value = JustXMLRPC.value(fromValueNode: m.element(forName: "value")!)
        resultDict[key] = value
      }
      return resultDict
    default:
      Utility.log("XMLRPC: Unexpected value type: \(eNode.name ?? "Unknown value type")")
      return 0
    }
  }

}
