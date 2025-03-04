//
//  SentryCrashCachedData_Tests.m
//
//  Copyright (c) 2012 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#import <XCTest/XCTest.h>

#import "SentryCrashCachedData.h"
#import "TestThread.h"

@interface SentryCrashCachedData_Tests : XCTestCase
@end

@implementation SentryCrashCachedData_Tests

- (void)testGetThreadName
{
    sentrycrashccd_close();

    NSString *expectedName = @"This is a test thread";
    TestThread *thread = [TestThread new];
    thread.name = expectedName;
    [thread start];
    [NSThread sleepForTimeInterval:0.1];
    sentrycrashccd_init(10);
    [NSThread sleepForTimeInterval:0.1];
    [thread cancel];
    sentrycrashccd_freeze();
    const char *cName = sentrycrashccd_getThreadName(thread.thread);
    XCTAssertTrue(cName != NULL);
    NSString *name = [NSString stringWithUTF8String:cName];
    XCTAssertEqualObjects(name, expectedName);
    sentrycrashccd_unfreeze();
}

@end
