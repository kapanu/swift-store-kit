//
//  InAppReceiptRefreshRequest.swift
//  IvoSmile2
//
//  Created by Angel Rodríguez Junquera on 12.03.21.
//  Copyright © 2021 Kapanu AG. All rights reserved.
//

import StoreKit
import Foundation

class InAppReceiptRefreshRequest: NSObject, SKRequestDelegate {

    typealias RequestCallback = (Result<Void,Error>) -> Void
    typealias ReceiptRefresh = (_ receiptProperties: [String: Any]?, _ callback: @escaping RequestCallback) -> InAppReceiptRefreshRequest

    class func refresh(_ receiptProperties: [String: Any]? = nil, callback: @escaping RequestCallback) -> InAppReceiptRefreshRequest {
        let request = InAppReceiptRefreshRequest(receiptProperties: receiptProperties, callback: callback)
        request.start()
        return request
    }

    let refreshReceiptRequest: SKReceiptRefreshRequest
    let callback: RequestCallback

    deinit {
        refreshReceiptRequest.delegate = nil
    }

    init(receiptProperties: [String: Any]? = nil, callback: @escaping RequestCallback) {
        self.callback = callback
        self.refreshReceiptRequest = SKReceiptRefreshRequest(receiptProperties: receiptProperties)
        super.init()
        self.refreshReceiptRequest.delegate = self
    }

    func start() {
        self.refreshReceiptRequest.start()
    }

    func cancel() {
        self.refreshReceiptRequest.cancel()
    }
    
    func requestDidFinish(_ request: SKRequest) {
      DispatchQueue.main.async {
        self.callback(.success(()))
      }
    }
  
    func request(_ request: SKRequest, didFailWithError error: Error) {
      DispatchQueue.main.async {
        self.callback(.failure(error))
      }
    }
}
