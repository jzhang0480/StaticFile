//
//  PlaidWebViewController.swift
//  Application
//
//  Created by Abhishek Goel on 5/14/20.
//  Copyright © 2020 Green Dot Corp. All rights reserved.
//

import UIKit
import WebKit

import GDCBaseUI
import GDCNetwork
import GDCFoundation

extension Plaid {
    typealias ViewController = PlaidViewController
}

/// The controller loading plaidURL within a BaseWebVC and conforming to Plaid.Delegate
class PlaidViewController: BaseWebViewController {
    //MARK: - Properties -
    override var prefersStatusBarHidden : Bool {
        return true
    }
    
    private weak var delegate: Plaid.Delegate!      =   nil
    
    private var oauthObserver: NSObjectProtocol?    =   nil
    
    private var manager: Plaid.Manager?             =   nil
    
    private var error: AppError?                    =   nil
    
    private var product: Plaid.Product!
    private var token: Plaid.Token!
    //MARK: - Life Cycle -
    /// Returns an instance of the BaseWebVC with plaidURL loaded and confirming to Plaid.Delegate
    /// - Parameters:
    ///   - frame: The frame at which to draw the BaseWebViewController
    ///   - delegate: Plaid.Delegate to confirm to various scenarios along the Plaid Flow: Exit, Fail, Success
    ///   - product: Plaid Product ( 1. Link, 1. Deposit Switch)
    ///   - token: Plaid Token (Optional)
    convenience init(frame: CGRect, delegate incomingDelegate: Plaid.Delegate, product incomingProduct: Plaid.Product, token incomingToken: Plaid.Token? = nil) {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        self.init(frame: frame, showBrowserBar: false, bounceScrollView: false, suppressExternalBrowserLaunch: false, barItemColor: Color.primary, highlightColor: Color.primaryDark, needsAddIsMobileKey: false)
        
        delegate = incomingDelegate
        oauthObserver = NotificationCenter.default.addObserver(forName: .plaidOAuthState, object: nil, queue: nil) { (notification: Notification) in
            LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
            guard
                let url = notification.object as? URL,
                let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems
            else {
                LoggingUtility.log(format: "\(#function):\tNotification didn't contain object as URL or couldn't generate URLComponents from it.", tag: .plaidLoggingUtilityTag, level: .information)
                return
            }
            
            let parameter = queryItems.reduce(into: (currentUser: false, stateId: Optional<String>(nil))) { (parameter, item) in
                if item.name == "oauth_state_id" {
                    parameter.stateId = item.value
                    
                } else if item.name == "user_id",
                          let username = try! KeychainPersistence.userIdentifier(),
                          item.value == username {
                    parameter.currentUser = true
                }
            }
            
            guard
                var unwrapped: Plaid.Manager = self.manager,
                parameter.currentUser,
                let stateId = parameter.stateId
            else {
                LoggingUtility.log(format: "\(#function):\tManger couldn't be unwrapped, is not current user or state wasn't provided.", tag: .plaidLoggingUtilityTag, level: .information)
                return
            }
            
            unwrapped.oAuthState = stateId
            LoggingUtility.log(format: "\(#function):\tstate:\t\(stateId), triggering a webview load.", tag: .plaidLoggingUtilityTag, level: .information)
            self.load(url: url)
        }
        
        product = incomingProduct
        token = incomingToken
    }
    
    deinit {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        if let unwrappedOA: NSObjectProtocol = oauthObserver {
            NotificationCenter.default.removeObserver(unwrappedOA)
        }
    }
    
    override func viewDidLoad() {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        super.viewDidLoad()
        loadPlaid(token: token)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        super.viewDidAppear(animated)
        // Report page view when screen is presented
        if let reportName: Report.Name = product.reportName {
            LoggingUtility.log(format: "\(#function):\tReporting page:\t\(reportName)", tag: .plaidLoggingUtilityTag, level: .verbose)
            ReportingManager.reportPage(Report.page(named: reportName, ofType: .analytics, withClass: self, containedIn: self.parent))
        }
    }
    
    //MARK: - Methods -
    private func loadPlaid(token: Plaid.Token? = nil) {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        if let providerType: ACH.Pull.ExternalAccount.Link.ProviderType = ACH.Pull.ExternalAccount.Link.ProviderType(rawValue: GDApplicationConfigurationManager.default.plaidProviderType), providerType == .linkToken, token == nil {
            self.showLoadingView()
               let credentials: Credentials = try! AuthenticationManager.default.credentials()
            ACH.Services.default.linkToken(credentials: credentials) { error, token in
                   DispatchQueue.main.async {
                       self.hideLoadingView()
                       if let linkToken = token {
                           self.setupPlaidManager(token: linkToken)
                       } else {
                           let alert = AlertVC(iconType: .warning, text: TextUtility.value(for: "GeneralErrorMessage"))
                           alert.appendButton(TextUtility.value(for: "GenericAlert_ButtonTitle"), buttonStyle: MediumSolidStyleB.self) { (_) in
                               self.navigationController?.popViewController(animated: true)
                           }
                           alert.showIn(self)
                       }
                   }
               }
        } else {
            setupPlaidManager(token: token)
        }
    }
    
    func setupPlaidManager(token: Plaid.Token?) {
        if manager == nil {
            do {
                LoggingUtility.log(format: "\(#function):\tInstantiating manager", tag: .plaidLoggingUtilityTag, level: .verbose)
                manager = try Plaid.Manager(token: token, product: product)
            } catch let aE as AppError {
                LoggingUtility.log(format: "\(#function):\tError Encountered:\t\(aE.localizedDescription)", tag: .plaidLoggingUtilityTag, level: .error)
                error = aE
            } catch let e {
                LoggingUtility.log(format: "\(#function):\tError Encountered:\t\(e.localizedDescription)", tag: .plaidLoggingUtilityTag, level: .error)
                error = AppErrorCode.unknown.error(userInfo: [NSLocalizedDescriptionKey : "App Error encountered, check the \(NSUnderlyingErrorKey) for actual error.", NSUnderlyingErrorKey : e ])
            }
        }
        
        guard
            let url: URL = manager?.url
        else {
            LoggingUtility.log(format: "\(#function):\tmanager doesn't exist or doesn't have a URL", tag: .plaidLoggingUtilityTag, level: .information)
            return
        }
        self.load(url: url)
    }
}

// MARK: Helpers
extension Plaid.ViewController {
    func errorFound(url: URL?) -> Bool {
        LoggingUtility.log(format: "\(#function):\t\(url?.queryItems()?.filter({ $0.name == "error_code" }).first != nil)", tag: .plaidLoggingUtilityTag, level: .verbose)
        return url?.queryItems()?.filter({ $0.name == "error_code" }).first != nil
    }
    
    func getError(url: URL?) -> String? {
        LoggingUtility.log(format: "\(#function):\t\(url?.queryItems()?.first(where: {$0.name == "error_code"})?.value)", tag: .plaidLoggingUtilityTag, level: .verbose)
        return url?.queryItems()?.first(where: {$0.name == "error_code"})?.value
    }
}

//MARK: - WKWebKit Delegate Methods -
extension Plaid.ViewController {
    override func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping ((WKNavigationActionPolicy) -> Void)) {
        LoggingUtility.log(format: "\(#function)", tag: .plaidLoggingUtilityTag, level: .verbose)
        guard
            var unwrapped: Plaid.Manager = manager
        else {
            LoggingUtility.log(format: "\(#function):\tmanager doesn't exist, returning cancel redirect.", tag: .plaidLoggingUtilityTag, level: .information)
            decisionHandler(.cancel)
            return
        }
        
        //Determine if manager wants/does handle redirect, otherwise handle it here
        let response: (handled: Bool, modifiedURL: URL?) = unwrapped.webView(webView, handleRedirectFor: navigationAction.request.url!)
        if response.handled {
            if let unwrapped: URL = response.modifiedURL {
                LoggingUtility.log(format: "\(#function):\tmodifiedURL:\t\(unwrapped.absoluteString), triggering a webview load.", tag: .plaidLoggingUtilityTag, level: .information)
                load(url: unwrapped)
            }
            LoggingUtility.log(format: "\(#function):\tmanager handled redirect, returning cancel redirect.", tag: .plaidLoggingUtilityTag, level: .information)
            decisionHandler(.cancel)
            return
        } else {
            if let modifiedURL: URL = response.modifiedURL {
                LoggingUtility.log(format: "\(#function):\tmodifiedURL:\t\(modifiedURL.absoluteString), triggering a webview load.", tag: .plaidLoggingUtilityTag, level: .information)
                load(url: modifiedURL)
            }
            
            let decision = unwrapped.decisionFor(navigationAction: navigationAction)
            LoggingUtility.log(format: "\(#function):\tdecision:\t\(description(for: decision))", tag: .plaidLoggingUtilityTag, level: .verbose)
            if let action = decision.plaidAction {
                switch action {
                    case .connected:
                        if let criteria = decision.criteria {
                            LoggingUtility.log(format: "\(#function):\tcriteria:\t\(description(for: criteria)), calling delegate with success", tag: .plaidLoggingUtilityTag, level: .information)
                            delegate?.plaidDidSucceed(criteria: criteria.criteria, account: criteria.account)
                        } else {
                            LoggingUtility.log(format: "\(#function):\tmanager wasn't able to produce criteria needed to call API for linking new account.", tag: .plaidLoggingUtilityTag, level: .information)
#if DEBUG
                            fatalError("Unexpected Plaid response format")
#endif
                        }
                    case .exit:
                        let errorCode = getError(url: navigationAction.request.url)
                        LoggingUtility.log(format: "\(#function):\terror:\t\(errorFound(url: navigationAction.request.url)), errorCode:\t\(errorCode ?? "nil"), calling delegate with exit", tag: .plaidLoggingUtilityTag, level: .information)
                        delegate?.userDidExitPlaid(encounteredError: errorFound(url: navigationAction.request.url), errorCode: errorCode)
                        
                    default:
                        LoggingUtility.log(format: "\(#function):\tmanager decision had an action not expected/handled\(action.rawValue)", tag: .plaidLoggingUtilityTag, level: .information)
                        break
                }
            }
            
            decisionHandler(decision.navigationPolicy)
        }
    }
    
    override func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        LoggingUtility.log(format: "\(#function):\terror:\t\(error.localizedDescription)", tag: .plaidLoggingUtilityTag, level: .error)
        delegate?.plaidDidFail(with: error)
    }
    
    private func description(for decision: (plaidAction: Plaid.Action?, navigationPolicy: WKNavigationActionPolicy, criteria: (criteria: ACH.Pull.ExternalAccount.Link.Criteria, account: Plaid.Account)?)) -> String {
        var returnString: String = String("<<plaidAction:\t<\(decision.plaidAction?.rawValue ?? "nil")>>,")
        returnString.append(String("<navigationPolicy:\t<\(decision.navigationPolicy.rawValue)>( cancel = 0, allow = 1, (iOS 15.0)download = 2)>,"))
        returnString.append(String("<criteria:\t\(description(for: decision.criteria))>>"))
        return returnString
    }
    
    private func description(for criteria: (criteria: ACH.Pull.ExternalAccount.Link.Criteria, account: Plaid.Account)?) -> String {
        var returnString: String = String()
        if let unwrappedC: (criteria: ACH.Pull.ExternalAccount.Link.Criteria, account: Plaid.Account) = criteria {
            returnString.append(String("<<criteria:\t\(description(for: unwrappedC.criteria))>,"))
            returnString.append(String("<account:\t\(description(for: unwrappedC.account))>>"))
        } else {
            returnString.append(String("<nil>"))
        }
        return returnString
    }
    
    private func description(for criteria: ACH.Pull.ExternalAccount.Link.Criteria) -> String {
//        return String("<publicToken:\t\(criteria.publicToken), selectedBankAccounts:\t\(criteria.selectedBankAccounts), version:\t\(criteria.version)>")
        return String("<Unable to render description>")
    }
    
    private func description(for bankAccount: ACH.Pull.ExternalAccount) -> String {
        return String("<accountID:\t\(bankAccount.identifier), institutionID:\t\(bankAccount.institutionIdentifier), institutionName:\t\(bankAccount.institutionName)>")
    }
    
    private func description(for account: Plaid.Account) -> String {
        return String("<mask:\t\(account.mask.suffix(4)), subtype:\t\(account.subtype), bankName:\t\(account.bankName), referenceID:\t\(String(account.referenceID.suffix(6)))>")
    }
}
