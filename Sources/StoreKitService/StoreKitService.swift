//
//  StoreKitService.swift
//  IvoSmile2
//
//  Created by Angel Rodríguez Junquera on 26.02.21.
//  Copyright © 2021 Kapanu AG. All rights reserved.
//

import Foundation
import StoreKit

class StoreKitService: NSObject {
  
  typealias ProductRequestCompletion = ([SKProduct])->()
  typealias PaymentRequestCompletion = (Result<Void, Error>)->()
  typealias RestoreTransactionsRequestCompletion = (Result<Void, Error>)->()
  
  static let shared = StoreKitService()
  
  private var productRequests: [SKProductsRequest: ProductRequestCompletion] = [:]
  private var purchaseRequests: [String : PaymentRequestCompletion] = [:]
  private var restoredTransactions: [SKPaymentTransaction] = []
  private var restoredTransactionsCompletion: RestoreTransactionsRequestCompletion?
  private var receiptRefreshRequest: InAppReceiptRefreshRequest?
  private var appStoreReceiptData: Data? {
    guard let appStoreReceiptURL = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: appStoreReceiptURL.path) else { return nil }
    return try? Data(contentsOf: appStoreReceiptURL, options: .alwaysMapped)
  }

  fileprivate override init() {
    super.init()
    SKPaymentQueue.default().add(self)
  }
  
  func fetchProducts(matchingIdentifiers identifiers: [String], completion: @escaping ProductRequestCompletion) {
    let productIdentifiers = Set(identifiers)
    let productRequest = SKProductsRequest(productIdentifiers: productIdentifiers)
    productRequest.delegate = self
    productRequests[productRequest] = completion
    productRequest.start()
  }
  
  
  func buy(_ product: SKProduct, completion: @escaping PaymentRequestCompletion) {
    let payment = SKMutablePayment(product: product)
    purchaseRequests[product.productIdentifier] = completion
    
    SKPaymentQueue.default().add(payment)
  }
  
  func restoreTransactions(completion: @escaping RestoreTransactionsRequestCompletion) {
    
    if !restoredTransactions.isEmpty {
      restoredTransactions.removeAll()
    }
    restoredTransactionsCompletion = completion
    SKPaymentQueue.default().restoreCompletedTransactions()
  }
  
  
  func validateSubscriptions(environment: VerifyReceiptURLType, sharedSecret: String, subscriptionType: SubscriptionType = .autoRenewable, productIds: Set<String>, completion: @escaping (Result<VerifySubscriptionResult, Error>)->()) {
    
    validateReceiptData(sharedSecret: sharedSecret) { result in
      switch result {
      case .success(let receiptInfo):
        let subscriptionState = InAppReceipt.verifySubscriptions(ofType: subscriptionType, productIds: productIds, inReceipt: receiptInfo)
        completion(.success(subscriptionState))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
  
  fileprivate func handlePurchased(_ transaction: SKPaymentTransaction) {
    SKPaymentQueue.default().finishTransaction(transaction)
    guard let completion = purchaseRequests[transaction.payment.productIdentifier] else { return }
    purchaseRequests.removeValue(forKey: transaction.payment.productIdentifier)
    DispatchQueue.main.async {
      completion(.success(()))
    }
  }
  
  /// Handles failed purchase transactions.
  fileprivate func handleFailed(_ transaction: SKPaymentTransaction) {
    if let error = transaction.error {
      print("Purchase Error \(error.localizedDescription)")
      
      if let completion = purchaseRequests[transaction.payment.productIdentifier] {
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }
    
    // Finish the failed transaction.
    SKPaymentQueue.default().finishTransaction(transaction)
  }
  
  /// Handles restored purchase transactions.
  fileprivate func handleRestored(_ transaction: SKPaymentTransaction) {
    restoredTransactions.append(transaction)
    print("Restoring transaction \(transaction.payment.productIdentifier).")
    // Finishes the restored transaction.
    SKPaymentQueue.default().finishTransaction(transaction)
  }
  
  private func getReceiptData(completion: @escaping(Result<Data, Error>)->()) {
    if let receiptData = appStoreReceiptData {
      completion(.success(receiptData))
    }
    else {
      receiptRefreshRequest = InAppReceiptRefreshRequest.refresh { [weak self] result in
        if let receiptData = self?.appStoreReceiptData {
          completion(.success(receiptData))
        }
        else {
          completion(.failure(ReceiptError.noReceiptData))
        }
      }
    }
  }
  
  private func validateReceiptData(sharedSecret: String, completion: @escaping (Result<ReceiptInfo, Error>)->()) {
    getReceiptData { result in
      switch result {
      case .success(let data):
        let validator = AppleReceiptValidator(sharedSecret: sharedSecret)
        validator.validate(service: .production, receiptData: data, completion: completion)
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
}

extension StoreKitService: SKPaymentTransactionObserver {
  
  func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
    for transaction in transactions {
      switch transaction.transactionState {
      case .purchasing: break
      // Do not block the UI. Allow the user to continue using the app.
      case .deferred: print("Deferred")
      // The purchase was successful.
      case .purchased: handlePurchased(transaction)
      // The transaction failed.
      case .failed: handleFailed(transaction)
      // There're restored products.
      case .restored: handleRestored(transaction)
      @unknown default: fatalError("Fatal error")
      }
    }
  }
  
  /// Logs all transactions that have been removed from the payment queue.
  func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction]) {
  }
  
  /// Called when an error occur while restoring purchases. Notify the user about the error.
  func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
    print("Restoring transactions failed")
    restoredTransactionsCompletion?(.failure(error))
    restoredTransactionsCompletion = nil
  }
  
  /// Called when all restorable transactions have been processed by the payment queue.
  func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
    print("All transactions restored")
    restoredTransactionsCompletion?(.success(()))
    restoredTransactionsCompletion = nil
  }
}

extension StoreKitService: SKProductsRequestDelegate {
  
  func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
    guard let completion = productRequests[request] else { return }
    productRequests.removeValue(forKey: request)
    DispatchQueue.main.async {
      completion(response.products)
    }
  }
}

public enum VerifyReceiptURLType: String {
  case production = "https://buy.itunes.apple.com/verifyReceipt"
  case sandbox = "https://sandbox.itunes.apple.com/verifyReceipt"
}

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

