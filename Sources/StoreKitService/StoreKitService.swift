//
//  StoreKitService.swift
//  IvoSmile2
//
//  Created by Angel Rodríguez Junquera on 26.02.21.
//  Copyright © 2021 Kapanu AG. All rights reserved.
//

import Foundation
import StoreKit
import os

public class StoreKitService: NSObject {
  
  public typealias ProductRequestCompletion = ([SKProduct])->()
  public typealias PaymentRequestCompletion = (Result<Void, Error>)->()
  public typealias RestoreTransactionsRequestCompletion = (Result<Void, Error>)->()
  
  public static let shared = StoreKitService()
  
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
  
  public func fetchProducts(matchingIdentifiers identifiers: [String], completion: @escaping ProductRequestCompletion) {
    let productIdentifiers = Set(identifiers)
    let productRequest = SKProductsRequest(productIdentifiers: productIdentifiers)
    productRequest.delegate = self
    productRequests[productRequest] = completion
    productRequest.start()
  }
  
  
  public func buy(_ product: SKProduct, completion: @escaping PaymentRequestCompletion) {
    let payment = SKMutablePayment(product: product)
    purchaseRequests[product.productIdentifier] = completion
    
    SKPaymentQueue.default().add(payment)
  }
  
  public func restoreTransactions(completion: @escaping RestoreTransactionsRequestCompletion) {
    
    if !restoredTransactions.isEmpty {
      restoredTransactions.removeAll()
    }
    restoredTransactionsCompletion = completion
    SKPaymentQueue.default().restoreCompletedTransactions()
  }
  
  
  public func validateSubscriptions(environment: VerifyReceiptURLType, sharedSecret: String, subscriptionType: SubscriptionType = .autoRenewable, productIds: Set<String>, completion: @escaping (Result<VerifySubscriptionResult, Error>)->()) {
    
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
      os_log(.debug, "Error while purchsing. Error: %{private}@", error.localizedDescription)
      
      if let completion = purchaseRequests[transaction.payment.productIdentifier] {
        DispatchQueue.main.async {
          completion(.failure(error))
        }
      }
    }
    
    SKPaymentQueue.default().finishTransaction(transaction)
  }
  
  /// Handles restored purchase transactions.
  fileprivate func handleRestored(_ transaction: SKPaymentTransaction) {
    restoredTransactions.append(transaction)
    os_log(.debug, "Restored transaction %{private}@", transaction.payment.productIdentifier)
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
  
  public func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
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
  public func paymentQueue(_ queue: SKPaymentQueue, removedTransactions transactions: [SKPaymentTransaction]) {
  }
  
  /// Called when an error occur while restoring purchases. Notify the user about the error.
  public func paymentQueue(_ queue: SKPaymentQueue, restoreCompletedTransactionsFailedWithError error: Error) {
    os_log(.debug, "Error restoring transactions. Error: %{private}@", error.localizedDescription)
    restoredTransactionsCompletion?(.failure(error))
    restoredTransactionsCompletion = nil
  }
  
  /// Called when all restorable transactions have been processed by the payment queue.
  public func paymentQueueRestoreCompletedTransactionsFinished(_ queue: SKPaymentQueue) {
    os_log(.debug, "Transaction restoration completed")
    restoredTransactionsCompletion?(.success(()))
    restoredTransactionsCompletion = nil
  }
}

extension StoreKitService: SKProductsRequestDelegate {
  
  public func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
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
