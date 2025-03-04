import Sentry
import XCTest

// swiftlint:disable file_length
// We are aware that the client has a lot of logic and we should maybe
// move some of it to other classes.
class SentryClientTest: XCTestCase {
    
    private static let dsn = TestConstants.dsnAsString(username: "SentryClientTest")

    private class Fixture {
        let transport: TestTransport
        let transportAdapter: TestTransportAdapter
        
        let debugImageBuilder = SentryDebugImageProvider()
        let threadInspector = TestThreadInspector.instance
        
        let session: SentrySession
        let event: Event
        let environment = "Environment"
        let messageAsString = "message"
        let message: SentryMessage
        
        let user: User
        let fileManager: SentryFileManager
        let random = TestRandom(value: 1.0)
        
        let trace = SentryTracer(transactionContext: TransactionContext(name: "SomeTransaction", operation: "SomeOperation"), hub: nil)
        let transaction: Transaction
        let crashWrapper = TestSentryCrashWrapper.sharedInstance()
        let permissionsObserver = TestSentryPermissionsObserver()
        let deviceWrapper = TestSentryUIDeviceWrapper()
        let locale = Locale(identifier: "en_US")
        let timezone = TimeZone(identifier: "Europe/Vienna")!
        
        init() {
            session = SentrySession(releaseName: "release")
            session.incrementErrors()

            message = SentryMessage(formatted: messageAsString)

            event = Event()
            event.message = message
            
            user = User()
            user.email = "someone@sentry.io"
            user.ipAddress = "127.0.0.1"
            
            let options = Options()
            options.dsn = SentryClientTest.dsn
            fileManager = try! SentryFileManager(options: options, andCurrentDateProvider: TestCurrentDateProvider())
            
            transaction = Transaction(trace: trace, children: [])
            
            transport = TestTransport()
            transportAdapter = TestTransportAdapter(transport: transport, options: options)
        }

        func getSut(configureOptions: (Options) -> Void = { _ in }) -> Client {
            var client: Client!
            do {
                let options = try Options(dict: [
                    "dsn": SentryClientTest.dsn
                ])
                configureOptions(options)

                client = Client(
                    options: options,
                    transportAdapter: transportAdapter,
                    fileManager: fileManager,
                    threadInspector: threadInspector,
                    random: random,
                    crashWrapper: crashWrapper,
                    permissionsObserver: permissionsObserver,
                    deviceWrapper: deviceWrapper,
                    locale: locale,
                    timezone: timezone
                )
            } catch {
                XCTFail("Options could not be created")
            }

            return client
        }

        func getSutWithNoDsn() -> Client {
            getSut(configureOptions: { options in
                options.parsedDsn = nil
            })
        }
        
        func getSutDisabledSdk() -> Client {
            getSut(configureOptions: { options in
                options.enabled = false
            })
        }

        var scope: Scope {
            get {
                let scope = Scope()
                scope.setEnvironment(environment)
                scope.setTag(value: "value", key: "key")
                scope.add(TestData.dataAttachment)
                scope.setContext(value: [SentryDeviceContextFreeMemoryKey: 2_000], key: "device")
                return scope
            }
        }
        
        var eventWithCrash: Event {
            let event = TestData.event
            let exception = Exception(value: "value", type: "type")
            let mechanism = Mechanism(type: "mechanism")
            mechanism.handled = false
            exception.mechanism = mechanism
            event.exceptions = [exception]
            return event
        }
    }

    private let error = NSError(domain: "domain", code: -20, userInfo: [NSLocalizedDescriptionKey: "Object does not exist"])

    private let exception = NSException(name: NSExceptionName("My Custom exception"), reason: "User clicked the button", userInfo: nil)

    private var fixture: Fixture!

    override func setUp() {
        super.setUp()
        fixture = Fixture()
        fixture.fileManager.deleteAllEnvelopes()
    }
    
    override func tearDown() {
        super.tearDown()
        clearTestState()
    }
    
    func testCaptureMessage() {
        let eventId = fixture.getSut().capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(SentryLevel.info, actual.level)
            XCTAssertEqual(fixture.message, actual.message)

            assertValidDebugMeta(actual: actual.debugMeta, forThreads: actual.threads)
            assertValidThreads(actual: actual.threads)
        }
    }

    func testCaptureMessageWithoutStacktrace() {
        let eventId = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = false
        }).capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(SentryLevel.info, actual.level)
            XCTAssertEqual(fixture.message, actual.message)
            XCTAssertNil(actual.debugMeta)
            XCTAssertNil(actual.threads)
            XCTAssertNotNil(actual.dist)
        }
    }
    
    func testCaptureEvent() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        let scope = Scope()
        let expectedTags = ["tagKey": "tagValue"]
        scope.setTags(expectedTags)
        
        let eventId = fixture.getSut().capture(event: event, scope: scope)
        
        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(event.level, actual.level)
            XCTAssertEqual(event.message, actual.message)
            XCTAssertNotNil(actual.debugMeta)
            XCTAssertNotNil(actual.threads)
            
            XCTAssertNotNil(actual.tags)
            if let actualTags = actual.tags {
                XCTAssertEqual(expectedTags, actualTags)
            }
        }
    }
    
    func testCaptureEventWithScope_SerializedTagsAndExtraShouldMatch() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        let scope = Scope()
        let expectedTags = ["tagKey": "tagValue"]
        let expectedExtra = ["extraKey": "extraValue"]
        scope.setTags(expectedTags)
        scope.setExtras(expectedExtra)
        
        let eventId = fixture.getSut().capture(event: event, scope: scope)
        
        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            let serializedEvent = actual.serialize()
            let tags = try! XCTUnwrap(serializedEvent["tags"] as? [String: String])
            let extra = try! XCTUnwrap(serializedEvent["extra"] as? [String: String])
            XCTAssertEqual(expectedTags, tags)
            XCTAssertEqual(expectedExtra, extra)
        }
    }
        
    func testCaptureEventTypeTransactionDoesNotIncludeThreadAndDebugMeta() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        event.type = SentryEnvelopeItemTypeTransaction
        let scope = Scope()
        let expectedTags = ["tagKey": "tagValue"]
        scope.setTags(expectedTags)
        
        let eventId = fixture.getSut().capture(event: event, scope: scope)
        
        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(event.level, actual.level)
            XCTAssertEqual(event.message, actual.message)
            XCTAssertNil(actual.debugMeta)
            XCTAssertNil(actual.threads)
            
            XCTAssertNotNil(actual.tags)
            if let actualTags = actual.tags {
                XCTAssertEqual(expectedTags, actualTags)
            }
        }
    }
      
    func testCaptureEventWithException() {
        let event = Event()
        event.exceptions = [ Exception(value: "", type: "")]
        
        fixture.getSut().capture(event: event, scope: fixture.scope)
        
        assertLastSentEventWithAttachment { actual in
            assertValidDebugMeta(actual: actual.debugMeta, forThreads: event.threads)
            assertValidThreads(actual: actual.threads)
        }
    }

    func testCaptureEventWithNoDsn() {
        let event = Event()

        let eventId = fixture.getSut(configureOptions: { options in
            options.dsn = nil
        }).capture(event: event)
        
        eventId.assertIsEmpty()
    }
    
    func test_AttachmentProcessor_CaptureEvent() {
        let sut = fixture.getSut()
        let event = Event()
        let extraAttachment = Attachment(data: Data(), filename: "ExtraAttachment")

        let expectProcessorCall = expectation(description: "Processor Call")
        let processor = TestAttachmentProcessor { atts, e in
            var result = atts ?? []
            result.append(extraAttachment)
            XCTAssertEqual(event, e)
            expectProcessorCall.fulfill()
            return result
        }
        
        sut.add(processor)
        sut.capture(event: event)
        
        let sendedAttachments = fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.attachments ?? []
        
        wait(for: [expectProcessorCall], timeout: 1)
        XCTAssertEqual(sendedAttachments.count, 1)
        XCTAssertEqual(extraAttachment, sendedAttachments.first)
    }
    
    func test_AttachmentProcessor_CaptureError_WithSession() {
        let sut = fixture.getSut()
        let error = NSError(domain: "test", code: -1)
        let extraAttachment = Attachment(data: Data(), filename: "ExtraAttachment")
        
        let processor = TestAttachmentProcessor { atts, _ in
            var result = atts ?? []
            result.append(extraAttachment)
            return result
        }
        
        sut.add(processor)
        sut.captureError(error, with: fixture.session, with: Scope())
        
        let sentAttachments = fixture.transportAdapter.sentEventsWithSessionTraceState.first?.attachments ?? []
        
        XCTAssertEqual(sentAttachments.count, 1)
        XCTAssertEqual(extraAttachment, sentAttachments.first)
    }
    
    func test_AttachmentProcessor_CaptureError_WithSession_NoReleaseName() {
        let sut = fixture.getSut()
        let error = NSError(domain: "test", code: -1)
        let extraAttachment = Attachment(data: Data(), filename: "ExtraAttachment")
        
        let processor = TestAttachmentProcessor { atts, _ in
            var result = atts ?? []
            result.append(extraAttachment)
            return result
        }
        
        sut.add(processor)
        sut.captureError(error, with: SentrySession(releaseName: ""), with: Scope())
        
        let sendedAttachments = fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.attachments ?? []
        
        XCTAssertEqual(sendedAttachments.count, 1)
        XCTAssertEqual(extraAttachment, sendedAttachments.first)
    }
    
    func testCaptureEventWithDsnSetAfterwards() {
        let event = Event()

        let sut = fixture.getSut(configureOptions: { options in
            options.dsn = nil
        })
        
        sut.options.dsn = SentryClientTest.dsn
        
        let eventId = sut.capture(event: event)
        eventId.assertIsNotEmpty()
    }
    
    func testCaptureEventWithDebugMeta_KeepsDebugMeta() {
        let sut = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = true
        })
        
        let event = givenEventWithDebugMeta()
        sut.capture(event: event)
        
        assertLastSentEvent { actual in
            XCTAssertEqual(event.debugMeta, actual.debugMeta)
            assertValidThreads(actual: actual.threads)
        }
    }
    
    func testCaptureEventWithAttachedThreads_KeepsThreads() {
        let sut = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = true
        })
        
        let event = givenEventWithThreads()
        sut.capture(event: event)
        
        assertLastSentEvent { actual in
            assertValidDebugMeta(actual: actual.debugMeta, forThreads: event.threads)
            XCTAssertEqual(event.threads, actual.threads)
        }
    }
    
    func testCaptureEventWithAttachStacktrace() {
        let event = Event(level: SentryLevel.fatal)
        event.message = fixture.message
        let eventId = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = true
        }).capture(event: event)
        
        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(event.level, actual.level)
            XCTAssertEqual(event.message, actual.message)
            assertValidDebugMeta(actual: actual.debugMeta, forThreads: event.threads)
            assertValidThreads(actual: actual.threads)
        }
    }
    
    func testCaptureErrorWithoutAttachStacktrace() {
        let eventId = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = false
        }).capture(error: error, scope: fixture.scope)
        
        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            assertValidErrorEvent(actual, error)
        }
    }
    
    func testCaptureErrorWithEnum() {
        let eventId = fixture.getSut().capture(error: TestError.invalidTest)

        eventId.assertIsNotEmpty()
        let error = TestError.invalidTest as NSError
        assertLastSentEvent { actual in
            assertValidErrorEvent(actual, error)
        }
    }

    func testCaptureErrorUsesErrorDebugDescriptionWhenSet() {
        let error = NSError(
            domain: "com.sentry",
            code: 999,
            userInfo: [NSDebugDescriptionErrorKey: "Custom error description"]
        )
        let eventId = fixture.getSut().capture(error: error)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            do {
                let exceptions = try XCTUnwrap(actual.exceptions)
                XCTAssertEqual("Custom error description (Code: 999)", try XCTUnwrap(exceptions.first).value)
            } catch {
                XCTFail("Exception expected but was nil")
            }
        }
    }

    func testCaptureErrorUsesErrorCodeAsDescriptionIfNoCustomDescriptionProvided() {
        let error = NSError(
            domain: "com.sentry",
            code: 999,
            userInfo: [:]
        )
        let eventId = fixture.getSut().capture(error: error)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            do {
                let exceptions = try XCTUnwrap(actual.exceptions)
                XCTAssertEqual("Code: 999", try XCTUnwrap(exceptions.first).value)
            } catch {
                XCTFail("Exception expected but was nil")
            }
        }
    }

    func testCaptureErrorWithComplexUserInfo() {
        let url = URL(string: "https://github.com/getsentry")!
        let error = NSError(domain: "domain", code: 0, userInfo: ["url": url])
        let eventId = fixture.getSut().capture(error: error, scope: fixture.scope)

        eventId.assertIsNotEmpty()

        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual(url.absoluteString, actual.context!["user info"]!["url"] as? String)
        }
    }

    func testCaptureErrorWithSession() {
        let eventId = fixture.getSut().captureError(error, with: fixture.session, with: Scope())
        
        eventId.assertIsNotEmpty()
        XCTAssertNotNil(fixture.transportAdapter.sentEventsWithSessionTraceState.last)
        if let eventWithSessionArguments = fixture.transportAdapter.sentEventsWithSessionTraceState.last {
            assertValidErrorEvent(eventWithSessionArguments.event, error)
            XCTAssertEqual(fixture.session, eventWithSessionArguments.session)
        }
    }
    
    func testCaptureErrorWithSession_WithBeforeSendReturnsNil() {
        let eventId = fixture.getSut(configureOptions: { options in
            options.beforeSend = { _ in return nil }
        }).captureError(error, with: fixture.session, with: Scope())
        
        eventId.assertIsEmpty()
        assertLastSentEnvelopeIsASession()
    }

    func testCaptureCrashEventWithSession() {
        let eventId = fixture.getSut().captureCrash(fixture.event, with: fixture.session, with: fixture.scope)

        eventId.assertIsNotEmpty()
        
        assertLastSentEventWithSession { event, session, _ in
            XCTAssertEqual(fixture.event.eventId, event.eventId)
            XCTAssertEqual(fixture.event.message, event.message)
            XCTAssertEqual("value", event.tags?["key"] ?? "")

            XCTAssertEqual(fixture.session, session)
        }
    }
    
    func testCaptureCrashWithSession_DoesntOverideStacktrace() {
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil
        
        fixture.getSut().captureCrash(event, with: fixture.session, with: fixture.scope)
        
        assertLastSentEventWithSession { event, _, _ in
            XCTAssertNil(event.threads)
            XCTAssertNil(event.debugMeta)
        }
    }
    
    func testCaptureCrashEvent() {
        let eventId = fixture.getSut().captureCrash(fixture.event, with: fixture.scope)

        eventId.assertIsNotEmpty()
        
        assertLastSentEventWithAttachment { event in
            XCTAssertEqual(fixture.event.eventId, event.eventId)
            XCTAssertEqual(fixture.event.message, event.message)
            XCTAssertEqual("value", event.tags?["key"] ?? "")
        }
    }
    
    func testCaptureOOMEvent_RemovesMutableInfoFromDeviceContext() {
        let oomEvent = TestData.oomEvent
        
        _ = fixture.getSut().captureCrash(oomEvent, with: fixture.scope)

        assertLastSentEventWithAttachment { event in
            XCTAssertEqual(oomEvent.eventId, event.eventId)
            XCTAssertNil(event.context?["device"]?["free_memory"])
            XCTAssertNil(event.context?["device"]?["free_storage"])
            XCTAssertNil(event.context?["device"]?["orientation"])
            XCTAssertNil(event.context?["device"]?["charging"])
            XCTAssertNil(event.context?["device"]?["battery_level"])
            XCTAssertNil(event.context?["app"]?["app_memory"])
        }
    }
    
    func testCaptureOOMEvent_WithNoContext_ContextNotModified() {
        let oomEvent = TestData.oomEvent
        
        _ = fixture.getSut().captureCrash(oomEvent, with: Scope())

        assertLastSentEvent { event in
            XCTAssertEqual(oomEvent.eventId, event.eventId)
            XCTAssertEqual(oomEvent.context?.count, event.context?.count)
        }
    }
    
    func testCaptureOOMEvent_WithNoDeviceContext_ContextNotModified() {
        let oomEvent = TestData.oomEvent
        let scope = Scope()
        scope.setContext(value: ["some": "thing"], key: "any")
        
        _ = fixture.getSut().captureCrash(oomEvent, with: scope)

        assertLastSentEvent { event in
            XCTAssertEqual(oomEvent.eventId, event.eventId)
            XCTAssertEqual(oomEvent.context?.count, event.context?.count)
        }
    }
    
    func testCaptureCrash_DoesntOverideStacktraceFor() {
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil
        
        fixture.getSut().captureCrash(event, with: fixture.scope)
        
        assertLastSentEventWithAttachment { actual in
            XCTAssertNil(actual.threads)
            XCTAssertNil(actual.debugMeta)
        }
    }

    func testCaptureCrash_CrashWrapper_MemoryAndStorage() {
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil

        fixture.crashWrapper.internalFreeMemorySize = 123_456
        fixture.crashWrapper.internalAppMemorySize = 234_567
        fixture.crashWrapper.internalFreeStorageSize = 345_678
        fixture.getSut().captureCrash(event, with: fixture.scope)

        assertLastSentEventWithAttachment { actual in
            let eventFreeMemory = actual.context?["device"]?["free_memory"] as? Int
            XCTAssertEqual(eventFreeMemory, 123_456)

            let eventAppMemory = actual.context?["app"]?["app_memory"] as? Int
            XCTAssertEqual(eventAppMemory, 234_567)

            let eventFreeStorage = actual.context?["device"]?["free_storage"] as? Int
            XCTAssertEqual(eventFreeStorage, 345_678)
        }
    }

    func testCaptureCrash_DeviceProperties() {
#if os(iOS)
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil

        fixture.getSut().captureCrash(event, with: fixture.scope)

        assertLastSentEventWithAttachment { actual in
            let orientation = actual.context?["device"]?["orientation"] as? String
            XCTAssertEqual(orientation, "portrait")

            let charging = actual.context?["device"]?["charging"] as? Bool
            XCTAssertEqual(charging, true)

            let batteryLevel = actual.context?["device"]?["battery_level"] as? Int
            XCTAssertEqual(batteryLevel, 60)
        }
#endif
    }

    func testCaptureCrash_DeviceProperties_OtherValues() {
#if os(iOS)
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil

        fixture.deviceWrapper.internalOrientation = .landscapeLeft
        fixture.deviceWrapper.interalBatteryState = .full

        fixture.getSut().captureCrash(event, with: fixture.scope)

        assertLastSentEventWithAttachment { actual in
            let orientation = actual.context?["device"]?["orientation"] as? String
            XCTAssertEqual(orientation, "landscape")

            let charging = actual.context?["device"]?["charging"] as? Bool
            XCTAssertEqual(charging, false)
        }
#endif
    }

    func testCaptureCrash_Permissions() {
        fixture.permissionsObserver.internalLocationPermissionStatus = SentryPermissionStatus.granted
        fixture.permissionsObserver.internalPushPermissionStatus = SentryPermissionStatus.granted
        fixture.permissionsObserver.internalMediaLibraryPermissionStatus = SentryPermissionStatus.denied
        fixture.permissionsObserver.internalPhotoLibraryPermissionStatus = SentryPermissionStatus.partial

        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil

        fixture.getSut().captureCrash(event, with: fixture.scope)

        assertLastSentEventWithAttachment { actual in
            let permissions = actual.context?["app"]?["permissions"] as? [String: String]
            XCTAssertEqual(permissions?["push_notifications"], "granted")
            XCTAssertEqual(permissions?["location_access"], "granted")
            XCTAssertEqual(permissions?["photo_library"], "partial")
        }
    }

    func testCaptureCrash_Culture() {
        let event = TestData.event
        event.threads = nil
        event.debugMeta = nil

        fixture.getSut().captureCrash(event, with: fixture.scope)

        assertLastSentEventWithAttachment { actual in
            let culture = actual.context?["culture"]
            XCTAssertEqual(culture?["calendar"] as? String, "Gregorian Calendar")
            XCTAssertEqual(culture?["display_name"] as? String, "English (United States)")
            XCTAssertEqual(culture?["locale"] as? String, "en_US")
            XCTAssertEqual(culture?["is_24_hour_format"] as? Bool, false)
            XCTAssertEqual(culture?["timezone"] as? String, "Europe/Vienna")
        }
    }

    func testCaptureErrorWithUserInfo() {
        let expectedValue = "val"
        let error = NSError(domain: "domain", code: 0, userInfo: ["key": expectedValue])
        let eventId = fixture.getSut().capture(error: error, scope: fixture.scope)

        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual(expectedValue, actual.context!["user info"]!["key"] as? String)
        }
    }

    func testCaptureExceptionWithoutAttachStacktrace() {
        let eventId = fixture.getSut(configureOptions: { options in
            options.attachStacktrace = false
        }).capture(exception: exception, scope: fixture.scope)
        
        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            assertValidExceptionEvent(actual)
        }
    }
    
    func testCaptureExceptionWithSession() {
        let eventId = fixture.getSut().capture(exception, with: fixture.session, with: fixture.scope)
        
        eventId.assertIsNotEmpty()
        XCTAssertNotNil(fixture.transportAdapter.sentEventsWithSessionTraceState.last)
        if let eventWithSessionArguments = fixture.transportAdapter.sentEventsWithSessionTraceState.last {
            assertValidExceptionEvent(eventWithSessionArguments.event)
            XCTAssertEqual(fixture.session, eventWithSessionArguments.session)
            XCTAssertEqual([TestData.dataAttachment], eventWithSessionArguments.attachments)
        }
    }
    
    func testCaptureExceptionWithSession_WithBeforeSendReturnsNil() {
        let eventId = fixture.getSut(configureOptions: { options in
            options.beforeSend = { _ in return nil }
        }).capture(exception, with: fixture.session, with: fixture.scope)
        
        eventId.assertIsEmpty()
        assertLastSentEnvelopeIsASession()
    }

    func testCaptureExceptionWithUserInfo() {
        let expectedValue = "val"
        let exception = NSException(name: NSExceptionName("exception"), reason: "reason", userInfo: ["key": expectedValue])
        let eventId = fixture.getSut().capture(exception: exception, scope: fixture.scope)

        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual(expectedValue, actual.context!["user info"]!["key"] as? String)
        }
    }

    func testScopeIsNotNil() {
        let eventId = fixture.getSut().capture(message: fixture.messageAsString, scope: fixture.scope)

        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual(fixture.environment, actual.environment)
        }
    }

    func testCaptureSession() {
        let session = SentrySession(releaseName: "release")
        fixture.getSut().capture(session: session)

        assertLastSentEnvelopeIsASession()
    }
    
    func testCaptureSessionWithoutReleaseName() {
        let session = SentrySession(releaseName: "")
        
        fixture.getSut().capture(session: session)
        fixture.getSut().capture(exception, with: session, with: Scope())
            .assertIsNotEmpty()
        fixture.getSut().captureCrash(fixture.event, with: session, with: Scope())
            .assertIsNotEmpty()
        
        // No sessions sent
        XCTAssertTrue(fixture.transport.sentEnvelopes.isEmpty)
        XCTAssertEqual(0, fixture.transportAdapter.sentEventsWithSessionTraceState.count)
        XCTAssertEqual(2, fixture.transportAdapter.sendEventWithTraceStateInvocations.count)
    }

    func testBeforeSendReturnsNil_EventNotSent() {
        beforeSendReturnsNil { $0.capture(message: fixture.messageAsString) }

        assertNoEventSent()
    }
    
    func testBeforeSendReturnsNil_LostEventRecorded() {
        beforeSendReturnsNil { $0.capture(message: fixture.messageAsString) }
        
        assertLostEventRecorded(category: .error, reason: .beforeSend)
    }
    
    func testBeforeSendReturnsNilForTransaction_TransactionNotSend() {
        beforeSendReturnsNil { $0.capture(event: fixture.transaction) }
        
        assertLostEventRecorded(category: .transaction, reason: .beforeSend)
    }
    
    func testBeforeSendReturnsNilForTransaction_LostEventRecorded() {
        beforeSendReturnsNil { $0.capture(event: fixture.transaction) }
        
        assertLostEventRecorded(category: .transaction, reason: .beforeSend)
    }

    func testBeforeSendReturnsNewEvent_NewEventSent() {
        let newEvent = Event()
        let releaseName = "1.0.0"
        let eventId = fixture.getSut(configureOptions: { options in
            options.beforeSend = { _ in
                newEvent
            }
            options.releaseName = releaseName
        }).capture(message: fixture.messageAsString)

        XCTAssertEqual(newEvent.eventId, eventId)
        assertLastSentEvent { actual in
            XCTAssertEqual(newEvent.eventId, actual.eventId)
            XCTAssertNil(actual.releaseName)
        }
    }
    
    func testBeforeSendModifiesEvent_ModifiedEventSent() {
        fixture.getSut(configureOptions: { options in
            options.beforeSend = { event in
                event.threads = []
                event.debugMeta = []
                return event
            }
            options.attachStacktrace = true
        }).capture(message: fixture.messageAsString)

        assertLastSentEvent { actual in
            XCTAssertEqual([], actual.debugMeta)
            XCTAssertEqual([], actual.threads)
        }
    }

    func testNoDsn_MessageNotSent() {
        let sut = fixture.getSutWithNoDsn()
        let eventId = sut.capture(message: fixture.messageAsString)
        eventId.assertIsEmpty()
        assertNothingSent()
    }
    
    func testDisabled_MessageNotSent() {
        let sut = fixture.getSutDisabledSdk()
        let eventId = sut.capture(message: fixture.messageAsString)
        eventId.assertIsEmpty()
        assertNothingSent()
    }

    func testNoDsn_ExceptionNotSent() {
        let sut = fixture.getSutWithNoDsn()
        let eventId = sut.capture(exception: exception)
        eventId.assertIsEmpty()
        assertNothingSent()
    }

    func testNoDsn_ErrorNotSent() {
        let sut = fixture.getSutWithNoDsn()
        let eventId = sut.capture(error: error)
        eventId.assertIsEmpty()
        assertNothingSent()
    }

    func testNoDsn_SessionsNotSent() {
        _ = SentryEnvelope(event: Event())
        fixture.getSut(configureOptions: { options in
            options.dsn = nil
        }).capture(session: fixture.session)

        assertNothingSent()
    }

    func testNoDsn_EventWithSessionsNotSent() {
        _ = SentryEnvelope(event: Event())
        let eventId = fixture.getSut(configureOptions: { options in
            options.dsn = nil
        }).captureCrash(Event(), with: fixture.session, with: fixture.scope)

        eventId.assertIsEmpty()
        assertNothingSent()
    }

    func testNoDsn_ExceptionWithSessionsNotSent() {
        _ = SentryEnvelope(event: Event())
        let eventId = fixture.getSut(configureOptions: { options in
            options.dsn = nil
        }).capture(self.exception, with: fixture.session, with: fixture.scope)

        eventId.assertIsEmpty()
        assertNothingSent()
    }

    func testNoDsn_ErrorWithSessionsNotSent() {
        _ = SentryEnvelope(event: Event())
        let eventId = fixture.getSut(configureOptions: { options in
            options.dsn = nil
        }).captureError(self.error, with: fixture.session, with: fixture.scope)

        eventId.assertIsEmpty()
        assertNothingSent()
    }
    
    func testSampleRateNil_EventNotSampled() {
        assertSampleRate(sampleRate: nil, randomValue: 0, isSampled: false)
    }
    
    func testSampleRateBiggerRandom_EventNotSampled() {
        assertSampleRate(sampleRate: 0.5, randomValue: 0.49, isSampled: false)
    }
    
    func testSampleRateEqualsRandom_EventNotSampled() {
        assertSampleRate(sampleRate: 0.5, randomValue: 0.5, isSampled: false)
    }
    
    func testSampleRateSmallerRandom_EventSampled() {
        assertSampleRate(sampleRate: 0.50, randomValue: 0.51, isSampled: true)
    }
    
    private func assertSampleRate( sampleRate: NSNumber?, randomValue: Double, isSampled: Bool) {
        fixture.random.value = randomValue
        
        let eventId = fixture.getSut(configureOptions: { options in
            options.sampleRate = sampleRate
        }).capture(event: TestData.event)
        
        if isSampled {
            eventId.assertIsEmpty()
            assertNothingSent()
        } else {
            eventId.assertIsNotEmpty()
            assertLastSentEvent { actual in
                XCTAssertEqual(eventId, actual.eventId)
            }
        }
    }
    
    func testSampleRateDoesNotImpactTransactions() {
        fixture.random.value = 0.51
        
        let eventId = fixture.getSut(configureOptions: { options in
            options.sampleRate = 0.00
        }).capture(event: fixture.transaction)
        
        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(eventId, actual.eventId)
        }
    }
    
    func testEventSampled_RecordsLostEvent() {
        fixture.getSut(configureOptions: { options in
            options.sampleRate = 0.00
        }).capture(event: TestData.event)
        
        assertLostEventRecorded(category: .error, reason: .sampleRate)
    }
    
    func testEventDroppedByEventProcessor_RecordsLostEvent() {
        SentryGlobalEventProcessor.shared().add { _ in return nil }
        
        beforeSendReturnsNil { $0.capture(message: fixture.messageAsString) }
        
        assertLostEventRecorded(category: .error, reason: .eventProcessor)
    }
    
    func testTransactionDroppedByEventProcessor_RecordsLostEvent() {
        SentryGlobalEventProcessor.shared().add { _ in return nil }
        
        beforeSendReturnsNil { $0.capture(event: fixture.transaction) }
        
        assertLostEventRecorded(category: .transaction, reason: .eventProcessor)
    }
    
    func testNoDsn_UserFeedbackNotSent() {
        let sut = fixture.getSutWithNoDsn()
        sut.capture(userFeedback: UserFeedback(eventId: SentryId()))
        assertNothingSent()
    }
    
    func testDisabled_UserFeedbackNotSent() {
        let sut = fixture.getSutDisabledSdk()
        sut.capture(userFeedback: UserFeedback(eventId: SentryId()))
        assertNothingSent()
    }
    
    func testCaptureUserFeedback_WithEmptyEventId() {
        let sut = fixture.getSut()
        sut.capture(userFeedback: UserFeedback(eventId: SentryId.empty))
        assertNothingSent()
    }

    func testDistIsSet() {
        let dist = "dist"
        let eventId = fixture.getSut(configureOptions: { options in
            options.dist = dist
        }).capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(dist, actual.dist)
        }
    }
    
    func testEnvironmentDefaultToProduction() {
        let eventId = fixture.getSut().capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual("production", actual.environment)
        }
    }
    
    func testEnvironmentIsSetViaOptions() {
        let environment = "environment"
        let eventId = fixture.getSut(configureOptions: { options in
            options.environment = environment
        }).capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual(environment, actual.environment)
        }
    }
    
    func testEnvironmentIsSetInEventTakesPrecedenceOverOptions() {
        let optionsEnvironment = "environment"
        let event = Event()
        event.environment = "event"
        let scope = fixture.scope
        scope.setEnvironment("scope")
        let eventId = fixture.getSut(configureOptions: { options in
            options.environment = optionsEnvironment
        }).capture(event: event, scope: scope)

        eventId.assertIsNotEmpty()
        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual("event", actual.environment)
        }
    }
    
    func testEnvironmentIsSetInEventTakesPrecedenceOverScope() {
        let optionsEnvironment = "environment"
        let event = Event()
        event.environment = "event"
        let eventId = fixture.getSut(configureOptions: { options in
            options.environment = optionsEnvironment
        }).capture(event: event)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            XCTAssertEqual("event", actual.environment)
        }
    }
    
    func testSetSDKIntegrations() {
        SentrySDK.start(options: Options())

        let eventId = fixture.getSut().capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            assertArrayEquals(
                expected: ["AutoBreadcrumbTracking", "AutoSessionTracking", "Crash", "NetworkTracking"],
                actual: actual.sdk?["integrations"] as? [String]
            )
        }
    }
    
    func testSetSDKIntegrations_NoIntegrations() {
        let expected: [String] = []
        
        let eventId = fixture.getSut(configureOptions: { options in
            options.integrations = expected
        }).capture(message: fixture.messageAsString)

        eventId.assertIsNotEmpty()
        assertLastSentEvent { actual in
            assertArrayEquals(expected: expected, actual: actual.sdk?["integrations"] as? [String])
        }
    }
    
    func testFileManagerCantBeInit() {
        SentryFileManager.prepareInitError()
        
        let options = Options()
        options.dsn = SentryClientTest.dsn
        let client = Client(options: options, permissionsObserver: TestSentryPermissionsObserver())
        
        XCTAssertNil(client)
        
        SentryFileManager.tearDownInitError()
    }
    
    func testInstallationIdSetWhenNoUserId() {
        fixture.getSut().capture(message: "any message")
        
        assertLastSentEvent { actual in
            XCTAssertEqual(SentryInstallation.id(), actual.user?.userId)
        }
    }
    
    func testInstallationIdNotSetWhenUserIsSetWithoutId() {
        let scope = fixture.scope
        scope.setUser(fixture.user)
        fixture.getSut().capture(message: "any message", scope: scope)
        
        assertLastSentEventWithAttachment { actual in
            XCTAssertEqual(fixture.user.userId, actual.user?.userId)
            XCTAssertEqual(fixture.user.email, actual.user?.email)
        }
    }
    
    func testInstallationIdNotSetWhenUserIsSetWithId() {
        let scope = Scope()
        let user = fixture.user
        user.userId = "id"
        scope.setUser(user)
        fixture.getSut().capture(message: "any message", scope: scope)
        
        assertLastSentEvent { actual in
            XCTAssertEqual(user.userId, actual.user?.userId)
            XCTAssertEqual(fixture.user.email, actual.user?.email)
        }
    }
    
    func testSendDefaultPiiEnabled_GivenNoIP_AutoIsSet() {
        fixture.getSut(configureOptions: { options in
            options.sendDefaultPii = true
        }).capture(message: "any")
        
        assertLastSentEvent { actual in
            XCTAssertEqual("{{auto}}", actual.user?.ipAddress)
        }
    }
    
    func testSendDefaultPiiEnabled_GivenIP_IPAddressNotChanged() {
        let scope = Scope()
        scope.setUser(fixture.user)
        
        fixture.getSut(configureOptions: { options in
            options.sendDefaultPii = true
        }).capture(message: "any", scope: scope)
        
        assertLastSentEvent { actual in
            XCTAssertEqual(fixture.user.ipAddress, actual.user?.ipAddress)
        }
    }
    
    func testSendDefaultPiiDisabled_GivenIP_IPAddressNotChanged() {
        let scope = Scope()
        scope.setUser(fixture.user)
        
        fixture.getSut().capture(message: "any", scope: scope)
        
        assertLastSentEvent { actual in
            XCTAssertEqual(fixture.user.ipAddress, actual.user?.ipAddress)
        }
    }
    
    func testStoreEnvelope_StoresEnvelopeToDisk() {
        fixture.getSut().store(SentryEnvelope(event: Event()))
        XCTAssertEqual(1, fixture.fileManager.getAllEnvelopes().count)
    }
    
    func testOnCrashedLastRun_OnCaptureCrashWithSession() {
        let event = TestData.event
        
        var onCrashedLastRunCalled = false
        fixture.getSut(configureOptions: { options in
            options.onCrashedLastRun = { _ in
                onCrashedLastRunCalled = true
            }
        }).captureCrash(event, with: fixture.session, with: fixture.scope)
        
        XCTAssertTrue(onCrashedLastRunCalled)
    }
    
    func testOnCrashedLastRun_WithTwoCrashes_OnlyInvokeCallbackOnce() {
        let event = TestData.event
        
        var onCrashedLastRunCalled = false
        let client = fixture.getSut(configureOptions: { options in
            options.onCrashedLastRun = { crashEvent in
                onCrashedLastRunCalled = true
                XCTAssertEqual(event.eventId, crashEvent.eventId)
            }
        })
        
        client.captureCrash(event, with: fixture.scope)
        client.captureCrash(TestData.event, with: fixture.scope)
        
        XCTAssertTrue(onCrashedLastRunCalled)
    }
    
    func testOnCrashedLastRun_WithoutCallback_DoesNothing() {
        let client = fixture.getSut()
        client.captureCrash(TestData.event, with: fixture.scope)
    }
    
    func testOnCrashedLastRun_CallingCaptureCrash_OnlyInvokeCallbackOnce() {
        let event = TestData.event
        let callbackExpectation = expectation(description: "onCrashedLastRun called")
        
        var captureCrash: (() -> Void)?
        
        let client = fixture.getSut(configureOptions: { options in
            options.onCrashedLastRun = { crashEvent in
                callbackExpectation.fulfill()
                XCTAssertEqual(event.eventId, crashEvent.eventId)
                captureCrash!()
            }
        })
        captureCrash = { client.captureCrash(event, with: self.fixture.scope) }
        
        client.captureCrash(event, with: fixture.scope)
        
        wait(for: [callbackExpectation], timeout: 0.1)
    }
    
    func testCaptureTransactionEvent_sendTraceState() {
        let transaction = fixture.transaction
        let client = fixture.getSut()
        client.capture(event: transaction)
        
        XCTAssertNotNil(fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.traceContext)
    }
    
    func testCaptureEvent_traceInScope_sendTraceState() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        let scope = Scope()
        scope.span = fixture.trace
        
        let client = fixture.getSut()
        client.capture(event: event, scope: scope)
        
        client.capture(event: event)
        
        XCTAssertNotNil(fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.traceContext)
    }
    
    func testCaptureEvent_traceInScope_dontSendTraceState() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        let scope = Scope()
        scope.span = SentryTracer()
        
        let client = fixture.getSut()
        client.capture(event: event, scope: scope)
        
        client.capture(event: event)
        
        XCTAssertNil(fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.traceContext)
    }
    
    func testCaptureEvent_withAdditionalEnvelopeItem() {
        let event = Event(level: SentryLevel.warning)
        event.message = fixture.message
        
        let attachment = "{}"
        let data = attachment.data(using: .utf8)!
        let itemHeader = SentryEnvelopeItemHeader(type: "attachment", length: UInt(data.count))
        let item = SentryEnvelopeItem(header: itemHeader, data: data)
        
        let client = fixture.getSut()
        client.capture(event: event, scope: Scope(), additionalEnvelopeItems: [item])
        
        XCTAssertEqual(item, fixture.transportAdapter.sendEventWithTraceStateInvocations.first?.additionalEnvelopeItems.first)
    }
    
    private func givenEventWithDebugMeta() -> Event {
        let event = Event(level: SentryLevel.fatal)
        let debugMeta = DebugMeta()
        debugMeta.name = "Me"
        let debugMetas = [debugMeta]
        event.debugMeta = debugMetas
        return event
    }
    
    private func givenEventWithThreads() -> Event {
        let event = Event(level: SentryLevel.fatal)
        let thread = Sentry.Thread(threadId: 1)
        thread.crashed = true
        let threads = [thread]
        event.threads = threads
        return event
    }
    
    private func beforeSendReturnsNil(capture: (Client) -> Void) {
        capture(fixture.getSut(configureOptions: { options in
            options.beforeSend = { _ in
                nil
            }
        }))
    }
    
    private func assertNoEventSent() {
        XCTAssertEqual(0, fixture.transportAdapter.sendEventWithTraceStateInvocations.count, "No events should have been sent.")
    }
    
    private func assertEventNotSent(eventId: SentryId?) {
        let eventWasSent = fixture.transportAdapter.sendEventWithTraceStateInvocations.invocations.contains { eventArguments in
            eventArguments.event.eventId == eventId
        }
        XCTAssertFalse(eventWasSent)
    }

    private func assertLastSentEvent(assert: (Event) -> Void) {
        XCTAssertNotNil(fixture.transportAdapter.sendEventWithTraceStateInvocations.last)
        if let lastSentEventArguments = fixture.transportAdapter.sendEventWithTraceStateInvocations.last {
            assert(lastSentEventArguments.event)
        }
    }
    
    private func assertLastSentEventWithAttachment(assert: (Event) -> Void) {
        XCTAssertNotNil(fixture.transportAdapter.sendEventWithTraceStateInvocations.last)
        if let lastSentEventArguments = fixture.transportAdapter.sendEventWithTraceStateInvocations.last {
            assert(lastSentEventArguments.event)
            
            XCTAssertEqual([TestData.dataAttachment], lastSentEventArguments.attachments)
        }
    }
    
    private func assertLastSentEventWithSession(assert: (Event, SentrySession, SentryTraceContext?) -> Void) {
        XCTAssertNotNil(fixture.transportAdapter.sentEventsWithSessionTraceState.last)
        if let args = fixture.transportAdapter.sentEventsWithSessionTraceState.last {
            assert(args.event, args.session, args.traceContext)
        }
    }
    
    private func assertValidErrorEvent(_ event: Event, _ error: NSError) {
        XCTAssertEqual(SentryLevel.error, event.level)
        XCTAssertEqual(error, event.error as NSError?)
        
        guard let exceptions = event.exceptions else {
            XCTFail("Event should contain one exception"); return
        }
        XCTAssertEqual(1, exceptions.count)
        let exception = exceptions[0]
        XCTAssertEqual(error.domain, exception.type)
        
        XCTAssertEqual("Code: \(error.code)", exception.value)
        
        XCTAssertNil(exception.threadId)
        XCTAssertNil(exception.stacktrace)
        
        guard let mechanism = exception.mechanism else {
            XCTFail("Exception doesn't contain a mechanism"); return
        }
        XCTAssertEqual("NSError", mechanism.type)
        XCTAssertNotNil(mechanism.meta?.error)
        XCTAssertEqual(error.domain, mechanism.meta?.error?.domain)
        XCTAssertEqual(error.code, mechanism.meta?.error?.code)
        
        assertValidDebugMeta(actual: event.debugMeta, forThreads: event.threads)
        assertValidThreads(actual: event.threads)
    }
    
    private func assertValidExceptionEvent(_ event: Event) {
        XCTAssertEqual(SentryLevel.error, event.level)
        XCTAssertEqual(exception.reason, event.exceptions!.first!.value)
        XCTAssertEqual(exception.name.rawValue, event.exceptions!.first!.type)
        assertValidDebugMeta(actual: event.debugMeta, forThreads: event.threads)
        assertValidThreads(actual: event.threads)
    }
    
    private func assertLastSentEnvelope(assert: (SentryEnvelope) -> Void) {
        XCTAssertNotNil(fixture.transport.sentEnvelopes)
        if let lastSentEnvelope = fixture.transport.sentEnvelopes.last {
            assert(lastSentEnvelope)
        }
    }
    
    private func assertLastSentEnvelopeIsASession() {
        assertLastSentEnvelope { actual in
            XCTAssertEqual(1, actual.items.count)
            XCTAssertEqual("session", actual.items[0].header.type)
        }
    }
    
    private func assertValidDebugMeta(actual: [DebugMeta]?, forThreads threads: [Sentry.Thread]?) {
        let debugMetas = fixture.debugImageBuilder.getDebugImages(for: threads ?? [])
        
        XCTAssertEqual(debugMetas, actual ?? [])
    }
    
    private func assertValidThreads(actual: [Sentry.Thread]?) {
        let expected = fixture.threadInspector.getCurrentThreads()
        XCTAssertEqual(expected.count, actual?.count)
        XCTAssertEqual(expected, actual)
    }
    
    private func shortenIntegrations(_ integrations: [String]?) -> [String]? {
        return integrations?.map { $0.replacingOccurrences(of: "Sentry", with: "").replacingOccurrences(of: "Integration", with: "") }
    }

    private func assertNothingSent() {
        XCTAssertTrue(fixture.transport.sentEnvelopes.isEmpty)
        XCTAssertEqual(0, fixture.transportAdapter.sentEventsWithSessionTraceState.count)
        XCTAssertEqual(0, fixture.transportAdapter.sendEventWithTraceStateInvocations.count)
        XCTAssertEqual(0, fixture.transportAdapter.userFeedbackInvocations.count)
    }
    
    private func assertLostEventRecorded(category: SentryDataCategory, reason: SentryDiscardReason) {
        XCTAssertEqual(1, fixture.transport.recordLostEvents.count)
        let lostEvent = fixture.transport.recordLostEvents.first
        XCTAssertEqual(category, lostEvent?.category)
        XCTAssertEqual(reason, lostEvent?.reason)
    }

    private enum TestError: Error {
        case invalidTest
        case testIsFailing
        case somethingElse
    }
    
    class TestAttachmentProcessor: NSObject, SentryClientAttachmentProcessor {
        
        var callback: (([Attachment]?, Event) -> [Attachment]?)
        
        init(callback: @escaping ([Attachment]?, Event) -> [Attachment]?) {
            self.callback = callback
        }
        
        func processAttachments(_ attachments: [Attachment]?, for event: Event) -> [Attachment]? {
            return callback(attachments, event)
        }
    }
    
}

// swiftlint:enable file_length
