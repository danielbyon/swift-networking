//
//  NetworkingTests.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Testing
@testable import Networking

@Test("Networking target is importable")
func networkingTargetIsImportable() {}

@Test("foreground URL session configuration disables shared state")
func foregroundURLSessionConfigurationDisablesSharedState() {
    let configuration = makeForegroundURLSessionConfiguration()

    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
}
