//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftAWSLambdaRuntime open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftAWSLambdaRuntime project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftAWSLambdaRuntime project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import AWSLambdaRuntimeCore
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest

class LambdaRuntimeTest: XCTestCase {
    func testShutdownFutureIsFulfilledWithStartUpError() {
        let server = MockLambdaServer(behavior: FailedBootstrapBehavior())
        XCTAssertNoThrow(try server.start().wait())
        defer { XCTAssertNoThrow(try server.stop().wait()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let eventLoop = eventLoopGroup.next()
        let logger = Logger(label: "TestLogger")
        let runtime = LambdaRuntime<StartupErrorHandler>(eventLoop: eventLoop, logger: logger)

        // eventLoop.submit in this case returns an EventLoopFuture<EventLoopFuture<ByteBufferHandler>>
        // which is why we need `wait().wait()`
        XCTAssertThrowsError(try eventLoop.flatSubmit { runtime.start() }.wait()) {
            XCTAssert($0 is StartupError)
        }

        XCTAssertThrowsError(_ = try runtime.shutdownFuture.wait()) {
            XCTAssert($0 is StartupError)
        }
    }

    func testShutdownIsCalledWhenLambdaShutsdown() {
        let server = MockLambdaServer(behavior: BadBehavior())
        XCTAssertNoThrow(try server.start().wait())
        defer { XCTAssertNoThrow(try server.stop().wait()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        let eventLoop = eventLoopGroup.next()
        let logger = Logger(label: "TestLogger")
        let runtime = LambdaRuntime<EchoHandler>(eventLoop: eventLoop, logger: logger)

        XCTAssertNoThrow(_ = try eventLoop.flatSubmit { runtime.start() }.wait())
        XCTAssertThrowsError(_ = try runtime.shutdownFuture.wait()) {
            XCTAssertEqual(.badStatusCode(HTTPResponseStatus.internalServerError), $0 as? Lambda.RuntimeError)
        }
    }

    func testLambdaResultIfShutsdownIsUnclean() {
        let server = MockLambdaServer(behavior: BadBehavior())
        XCTAssertNoThrow(try server.start().wait())
        defer { XCTAssertNoThrow(try server.stop().wait()) }
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { XCTAssertNoThrow(try eventLoopGroup.syncShutdownGracefully()) }

        struct ShutdownError: Error {}

        struct ShutdownErrorHandler: EventLoopLambdaHandler {
            typealias Event = String
            typealias Output = Void

            static func makeHandler(context: Lambda.InitializationContext) -> EventLoopFuture<ShutdownErrorHandler> {
                context.eventLoop.makeSucceededFuture(ShutdownErrorHandler())
            }

            func handle(_ event: String, context: LambdaContext) -> EventLoopFuture<Void> {
                context.eventLoop.makeSucceededVoidFuture()
            }

            func shutdown(context: Lambda.ShutdownContext) -> EventLoopFuture<Void> {
                context.eventLoop.makeFailedFuture(ShutdownError())
            }
        }

        let eventLoop = eventLoopGroup.next()
        let logger = Logger(label: "TestLogger")
        let runtime = LambdaRuntime<ShutdownErrorHandler>(eventLoop: eventLoop, logger: logger)

        XCTAssertNoThrow(try eventLoop.flatSubmit { runtime.start() }.wait())
        XCTAssertThrowsError(try runtime.shutdownFuture.wait()) { error in
            guard case Lambda.RuntimeError.shutdownError(let shutdownError, .failure(let runtimeError)) = error else {
                XCTFail("Unexpected error: \(error)"); return
            }

            XCTAssert(shutdownError is ShutdownError)
            XCTAssertEqual(runtimeError as? Lambda.RuntimeError, .badStatusCode(.internalServerError))
        }
    }
}

struct BadBehavior: LambdaServerBehavior {
    func getInvocation() -> GetInvocationResult {
        .failure(.internalServerError)
    }

    func processResponse(requestId: String, response: String?) -> Result<Void, ProcessResponseError> {
        XCTFail("should not report a response")
        return .failure(.internalServerError)
    }

    func processError(requestId: String, error: ErrorResponse) -> Result<Void, ProcessErrorError> {
        XCTFail("should not report an error")
        return .failure(.internalServerError)
    }

    func processInitError(error: ErrorResponse) -> Result<Void, ProcessErrorError> {
        XCTFail("should not report an error")
        return .failure(.internalServerError)
    }
}
