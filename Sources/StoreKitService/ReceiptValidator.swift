//
//  ReceiptValidator.swift
//  
//
//  Created by Angel Rodríguez Junquera on 18.03.21.
//

import Foundation

public class AppleReceiptValidator {
  
  enum ValidatorError: Error {
    case noData
    case jsonDecoding(String)
    case invalidRecipt
  }
 
  /// You should always verify your receipt first with the `production` service
  /// Note: will auto change to `.sandbox` and validate again if received a 21007 status code from Apple
  
  private let sharedSecret: String?
  
  /**
   * Reference Apple Receipt Validator
   *  - Parameter service: Either .production or .sandbox
   *  - Parameter sharedSecret: Only used for receipts that contain auto-renewable subscriptions. Your app’s shared secret (a hexadecimal string).
   */
  public init(sharedSecret: String? = nil) {
    self.sharedSecret = sharedSecret
  }
  
  public func validate(service: VerifyReceiptURLType, receiptData: Data, completion: @escaping (Result<ReceiptInfo, Error>) -> Void) {
    
    let storeURL = URL(string: service.rawValue)! // safe (until no more)
    let storeRequest = NSMutableURLRequest(url: storeURL)
    storeRequest.httpMethod = "POST"
    
    let receipt = receiptData.base64EncodedString(options: [])
    let requestContents: NSMutableDictionary = [ "receipt-data": receipt ]
    // password if defined
    if let password = sharedSecret {
      requestContents.setValue(password, forKey: "password")
    }
    
    // Encore request body
    do {
      storeRequest.httpBody = try JSONSerialization.data(withJSONObject: requestContents, options: [])
    } catch let e {
      completion(.failure(e))
      return
    }
    
    // Remote task
    print("Validating recipt")
    let task = URLSession.shared.dataTask(with: storeRequest as URLRequest) { data, _, error -> Void in
      
      // there is an error
      print(storeRequest.url)
      if let networkError = error {
        completion(.failure(networkError))
        return
      }
      
      // there is no data
      guard let safeData = data else {
        completion(.failure(ValidatorError.noData))
        return
      }
      
      // cannot decode data
      guard let receiptInfo = try? JSONSerialization.jsonObject(with: safeData, options: .mutableLeaves) as? ReceiptInfo ?? [:] else {
        let jsonStr = String(data: safeData, encoding: String.Encoding.utf8)
        completion(.failure(ValidatorError.jsonDecoding(jsonStr ?? "")))
        return
      }
      
      // get status from info
      if let status = receiptInfo["status"] as? Int {
        /*
         * http://stackoverflow.com/questions/16187231/how-do-i-know-if-an-in-app-purchase-receipt-comes-from-the-sandbox
         * How do I verify my receipt (iOS)?
         * Always verify your receipt first with the production URL; proceed to verify
         * with the sandbox URL if you receive a 21007 status code. Following this
         * approach ensures that you do not have to switch between URLs while your
         * application is being tested or reviewed in the sandbox or is live in the
         * App Store.
         
         * Note: The 21007 status code indicates that this receipt is a sandbox receipt,
         * but it was sent to the production service for verification.
         */
        let receiptStatus = ReceiptStatus(rawValue: status) ?? ReceiptStatus.unknown
        if case .testReceipt = receiptStatus {
          self.validate(service: .sandbox, receiptData: receiptData, completion: completion)
        } else {
          if receiptStatus.isValid {
            completion(.success(receiptInfo))
          } else {
            completion(.failure(ValidatorError.invalidRecipt))
          }
        }
      } else {
        completion(.failure(ValidatorError.invalidRecipt))
      }
    }
    task.resume()
  }
}
