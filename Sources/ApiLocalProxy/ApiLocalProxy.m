#import "ApiLocalProxy.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString * const kLocalHost = @"127.0.0.1";
static const uint16_t kLocalPort = 17891;
static NSString * const kUpstreamBase = @"https://api-alfa-l4.hasu-link.club";

static UIWindow *gDiagWindow = nil;
static UILabel *gDiagLabel = nil;
static BOOL gBindPass = NO;
static BOOL gSelfTestPass = NO;
static BOOL gRewritePass = NO;
static NSUInteger gGameHitCount = 0;
static NSString *gLastPath = @"-";
static NSString *gLastEvent = @"STARTING";

static void diag_refresh_main(void) {
    if (gDiagWindow == nil) {
        gDiagWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        gDiagWindow.windowLevel = UIWindowLevelAlert + 1;
        gDiagWindow.userInteractionEnabled = NO;

        UIViewController *controller = [UIViewController new];
        controller.view.backgroundColor = UIColor.clearColor;
        gDiagWindow.rootViewController = controller;
    }

    if (gDiagLabel == nil) {
        gDiagLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 36, 359, 144)];
        gDiagLabel.textAlignment = NSTextAlignmentLeft;
        gDiagLabel.numberOfLines = 0;
        gDiagLabel.font = [UIFont boldSystemFontOfSize:12.0];
        gDiagLabel.textColor = UIColor.whiteColor;
        gDiagLabel.backgroundColor =
            [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:0.94];
        gDiagLabel.layer.cornerRadius = 10.0;
        gDiagLabel.clipsToBounds = YES;
        [gDiagWindow.rootViewController.view addSubview:gDiagLabel];
    }

    NSString *bind = gBindPass ? @"PASS" : @"WAIT";
    NSString *selfTest = gSelfTestPass ? @"PASS" : @"WAIT";
    NSString *rewrite = gRewritePass ? @"N/A" : @"WAIT";

    gDiagLabel.text =
        [NSString stringWithFormat:
            @"LLL API LOCAL DIAGNOSTIC\n"
             @"BIND     %@   127.0.0.1:17891\n"
             @"SELFTEST %@   /__LLL_SELFTEST__\n"
             @"HOOK     %@   metadata → localhost\n"
             @"GAME HIT %lu\n"
             @"LAST     %@\n"
             @"EVENT    %@",
            bind, selfTest, rewrite,
            (unsigned long)gGameHitCount,
            gLastPath ?: @"-",
            gLastEvent ?: @"-"];

    gDiagWindow.hidden = NO;
}

static void diag_set_event(NSString *event) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gLastEvent = [event copy] ?: @"-";
        diag_refresh_main();
    });
}

static void diag_set_bind(BOOL pass, NSString *event) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gBindPass = pass;
        gLastEvent = [event copy] ?: @"-";
        diag_refresh_main();
    });
}

static void diag_set_selftest(BOOL pass, NSString *event) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gSelfTestPass = pass;
        gLastEvent = [event copy] ?: @"-";
        diag_refresh_main();
    });
}

static void diag_set_rewrite(BOOL pass, NSString *event) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gRewritePass = pass;
        gLastEvent = [event copy] ?: @"-";
        diag_refresh_main();
    });
}

static void diag_record_game_hit(NSString *path) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gGameHitCount += 1;
        gLastPath = [path copy] ?: @"/";
        gLastEvent = [NSString stringWithFormat:@"GAME HIT %@", gLastPath];
        diag_refresh_main();
    });
}

static NSUInteger find_header_end(const uint8_t *bytes, NSUInteger length) {
    static const uint8_t marker[] = {0x0d, 0x0a, 0x0d, 0x0a};

    if (length < sizeof(marker)) {
        return NSNotFound;
    }

    for (NSUInteger i = 0; i + sizeof(marker) <= length; i++) {
        if (memcmp(bytes + i, marker, sizeof(marker)) == 0) {
            return i + sizeof(marker);
        }
    }

    return NSNotFound;
}

static NSString *header_value(NSDictionary<NSString *, NSString *> *headers,
                              NSString *wantedKey) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:wantedKey] == NSOrderedSame) {
            return headers[key];
        }
    }

    return nil;
}

static NSDictionary<NSString *, NSString *> *parse_headers(NSString *headerText) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];

    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];

        if (line.length == 0) {
            break;
        }

        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }

        NSString *key = [[line substringToIndex:colon.location]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

        NSString *value = [[line substringFromIndex:colon.location + 1]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

        if (key.length > 0) {
            result[key] = value;
        }
    }

    return result;
}

static BOOL is_hop_header(id key) {
    if (key == nil || ![key isKindOfClass:NSString.class]) {
        NSLog(@"[LLLLOffline][API] unexpected header-key object class=%@ ptr=%p",
              key ? NSStringFromClass(object_getClass(key)) : @"<nil>",
              key);
        return NO;
    }

    NSString *value = (NSString *)key;

    return [value caseInsensitiveCompare:@"connection"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"proxy-connection"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"keep-alive"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"transfer-encoding"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"upgrade"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"host"] == NSOrderedSame ||
           [value caseInsensitiveCompare:@"content-length"] == NSOrderedSame;
}

static NSData *read_request(int fd,
                            NSString **requestLineOut,
                            NSDictionary<NSString *, NSString *> **headersOut) {
    NSMutableData *received = [NSMutableData data];
    NSUInteger headerEnd = NSNotFound;

    for (;;) {
        uint8_t buffer[16384];
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);

        if (count <= 0) {
            return nil;
        }

        [received appendBytes:buffer length:(NSUInteger)count];

        headerEnd = find_header_end(received.bytes, received.length);

        if (headerEnd != NSNotFound) {
            NSString *headerText = [[NSString alloc]
                                    initWithBytes:received.bytes
                                    length:headerEnd
                                    encoding:NSUTF8StringEncoding];

            if (headerText == nil) {
                return nil;
            }

            NSArray<NSString *> *lines =
                [headerText componentsSeparatedByString:@"\r\n"];

            *requestLineOut = lines.firstObject ?: @"";
            *headersOut = parse_headers(headerText);
            break;
        }

        if (received.length > 1024 * 1024) {
            return nil;
        }
    }

    NSString *contentLengthString =
        header_value(*headersOut, @"Content-Length");

    NSUInteger contentLength =
        contentLengthString.length > 0
        ? (NSUInteger)MAX(0, contentLengthString.longLongValue)
        : 0;

    while (received.length - headerEnd < contentLength) {
        uint8_t buffer[16384];
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);

        if (count <= 0) {
            return nil;
        }

        [received appendBytes:buffer length:(NSUInteger)count];

        if (received.length > headerEnd + 32 * 1024 * 1024) {
            return nil;
        }
    }

    return received;
}

static BOOL is_localhost_target(NSURL *url) {
    if (url == nil) {
        return NO;
    }

    return [url.host.lowercaseString isEqualToString:@"127.0.0.1"] &&
           url.port.integerValue == kLocalPort;
}

static void run_api_hook_rewrite_diagnostic(void) {
    diag_set_rewrite(YES, @"HOOK TEST N/A - metadata redirect build");
}


static BOOL send_all(int fd, const void *buffer, size_t length) {
    const uint8_t *cursor = (const uint8_t *)buffer;
    size_t remaining = length;

    while (remaining > 0) {
        ssize_t sent = send(fd, cursor, remaining, 0);

        if (sent < 0) {
            if (errno == EINTR) {
                continue;
            }

            NSLog(@"[LLLLOffline][API] send failed fd=%d errno=%d (%s)",
                  fd, errno, strerror(errno));
            return NO;
        }

        if (sent == 0) {
            NSLog(@"[LLLLOffline][API] send returned 0 fd=%d", fd);
            return NO;
        }

        cursor += (size_t)sent;
        remaining -= (size_t)sent;
    }

    return YES;
}

static BOOL send_http_response(int fd,
                               NSInteger status,
                               NSString *reason,
                               NSData *body,
                               NSDictionary<NSString *, NSString *> *headers) {
    if (body == nil) {
        body = [NSData data];
    }

    NSMutableString *header =
        [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n",
         (long)status,
         reason ?: @"OK"];

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                                 NSString *value,
                                                 BOOL *stop) {
        (void)stop;

        if (is_hop_header(key)) {
            return;
        }

        [header appendFormat:@"%@: %@\r\n", key, value];
    }];

    [header appendFormat:@"Content-Length: %lu\r\n",
                         (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n\r\n"];

    NSData *headerData =
        [header dataUsingEncoding:NSUTF8StringEncoding];

    if (!send_all(fd, headerData.bytes, headerData.length)) {
        return NO;
    }

    if (body.length > 0 &&
        !send_all(fd, body.bytes, body.length)) {
        return NO;
    }

    return YES;
}

static void send_json_error(int fd, NSInteger status, NSString *message) {
    NSData *body =
        [[NSJSONSerialization dataWithJSONObject:@{
            @"offline_poc_error": message ?: @"unknown"
        } options:0 error:nil] copy];

    send_http_response(
        fd,
        status,
        @"Error",
        body,
        @{@"Content-Type": @"application/json; charset=utf-8"}
    );
}

static NSMutableURLRequest *build_upstream_request(
    NSString *requestLine,
    NSDictionary<NSString *, NSString *> *headers,
    NSData *body
) {
    NSArray<NSString *> *parts =
        [requestLine componentsSeparatedByString:@" "];

    if (parts.count < 2) {
        return nil;
    }

    NSString *method = parts[0];
    NSString *target = parts[1];

    if (method.length == 0 || target.length == 0) {
        return nil;
    }

    if (![target hasPrefix:@"/"]) {
        return nil;
    }

    NSURL *url =
        [NSURL URLWithString:
            [kUpstreamBase stringByAppendingString:target]];

    if (url == nil) {
        return nil;
    }

    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:url];

    request.HTTPMethod = method;
    request.HTTPBody = body;

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key,
                                                 NSString *value,
                                                 BOOL *stop) {
        (void)stop;

        if (is_hop_header(key)) {
            return;
        }

        [request setValue:value forHTTPHeaderField:key];
    }];

    // Ask the private server for an identity response so NSURLSession's
    // transparent content decoding cannot leave us with a stale Content-Encoding
    // header describing a body that has already been decoded.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    return request;
}

static void proxy_request(int clientFD,
                          NSString *requestLine,
                          NSDictionary<NSString *, NSString *> *headers,
                          NSData *body) {
    NSString *earlyPath = @"/";
    NSArray<NSString *> *earlyParts =
        [requestLine componentsSeparatedByString:@" "];
    if (earlyParts.count >= 2) {
        earlyPath = earlyParts[1] ?: @"/";
    }
    diag_record_game_hit(earlyPath);

    NSMutableURLRequest *upstream =
        build_upstream_request(requestLine, headers, body);

    if (upstream == nil) {
        send_json_error(clientFD, 400, @"bad_request");
        return;
    }

    NSString *path = upstream.URL.path ?: @"/";

    diag_record_game_hit(path);

    NSLog(@"[LLLLOffline][API] LOCAL -> %@ method=%@ bytes=%lu",
          upstream.URL.absoluteString,
          upstream.HTTPMethod ?: @"<nil>",
          (unsigned long)body.length);

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration defaultSessionConfiguration];

    configuration.requestCachePolicy =
        NSURLRequestReloadIgnoringLocalCacheData;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;

    NSURLSession *session =
        [NSURLSession sessionWithConfiguration:configuration];

    dispatch_semaphore_t semaphore =
        dispatch_semaphore_create(0);

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *response = nil;
    __block NSError *responseError = nil;

    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:upstream
                   completionHandler:^(NSData *data,
                                       NSURLResponse *urlResponse,
                                       NSError *error) {
        responseData = data ?: [NSData data];

        if ([urlResponse isKindOfClass:NSHTTPURLResponse.class]) {
            response = (NSHTTPURLResponse *)urlResponse;
        }

        responseError = error;

        dispatch_semaphore_signal(semaphore);
    }];

    [task resume];

    long waitResult =
        dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(45.0 * NSEC_PER_SEC)));

    [session finishTasksAndInvalidate];

    if (waitResult != 0) {
        [task cancel];
        send_json_error(clientFD, 504, @"upstream_timeout");
        return;
    }

    if (responseError != nil || response == nil) {
        NSLog(@"[LLLLOffline][API] upstream error: %@", responseError);
        send_json_error(clientFD, 502, @"upstream_error");
        return;
    }

    NSMutableDictionary *responseHeaders = [NSMutableDictionary dictionary];

    __block NSString *contentType = nil;
    __block NSString *contentEncoding = nil;
    __block NSString *setCookieSummary = nil;

    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:
        ^(id key, id value, BOOL *stop) {
            (void)stop;

            if (key == nil) {
                return;
            }

            NSString *keyString = [key description];
            NSString *valueString = [value description];

            if ([keyString caseInsensitiveCompare:@"content-type"] == NSOrderedSame) {
                contentType = valueString;
            } else if ([keyString caseInsensitiveCompare:@"content-encoding"] == NSOrderedSame) {
                contentEncoding = valueString;
            } else if ([keyString caseInsensitiveCompare:@"set-cookie"] == NSOrderedSame) {
                setCookieSummary = valueString;
            }

            // These are regenerated from the actual body/socket.
            if ([keyString caseInsensitiveCompare:@"content-length"] == NSOrderedSame ||
                [keyString caseInsensitiveCompare:@"transfer-encoding"] == NSOrderedSame ||
                [keyString caseInsensitiveCompare:@"content-encoding"] == NSOrderedSame ||
                is_hop_header(keyString)) {
                return;
            }

            responseHeaders[keyString] = valueString;
        }];

    // Preserve a single Set-Cookie header when Foundation exposes it as a
    // scalar. Multiple Set-Cookie values may be collapsed by Foundation; the
    // summary is still useful for diagnostics.
    if (setCookieSummary.length > 0) {
        responseHeaders[@"Set-Cookie"] = setCookieSummary;
    }

    responseHeaders[@"X-LLL-API-LOCAL"] = @"1";

    BOOL forwardOK = send_http_response(
        clientFD,
        response.statusCode,
        @"Upstream",
        responseData,
        responseHeaders
    );

    NSString *diagEncoding = contentEncoding.length > 0 ? contentEncoding : @"none";
    NSString *diagType = contentType.length > 0 ? contentType : @"unknown";
    diag_set_event(
        [NSString stringWithFormat:@"UPSTREAM %ld %@\\n%lu bytes; CE=%@; CT=%@; FWD=%@",
         (long)response.statusCode,
         path,
         (unsigned long)responseData.length,
         diagEncoding,
         diagType,
         forwardOK ? @"OK" : @"FAIL"]
    );

    NSLog(@"[LLLLOffline][API] PRIVATE -> GAME status=%ld bytes=%lu",
          (long)response.statusCode,
          (unsigned long)responseData.length);
}

static void handle_client(int clientFD) {
    NSString *requestLine = nil;
    NSDictionary<NSString *, NSString *> *headers = nil;

    NSData *received =
        read_request(clientFD, &requestLine, &headers);

    if (received == nil || requestLine == nil || headers == nil) {
        send_json_error(clientFD, 400, @"malformed_http");
        close(clientFD);
        return;
    }

    NSLog(@"[LLLLOffline][API] INBOUND %@", requestLine);

    NSArray<NSString *> *parts =
        [requestLine componentsSeparatedByString:@" "];

    BOOL selfTestRequest =
        parts.count >= 2 &&
        [parts[0] isEqualToString:@"GET"] &&
        [parts[1] isEqualToString:@"/__LLL_SELFTEST__"];

    if (selfTestRequest) {
        NSData *selfTestBody =
            [@"LLL_SELFTEST_OK\n"
             dataUsingEncoding:NSUTF8StringEncoding];

        (void)send_http_response(
            clientFD,
            200,
            @"OK",
            selfTestBody,
            @{@"Content-Type": @"text/plain; charset=utf-8"}
        );

        close(clientFD);
        return;
    }

    NSUInteger headerEnd =
        find_header_end(received.bytes, received.length);

    if (headerEnd == NSNotFound ||
        headerEnd > received.length) {
        send_json_error(clientFD, 400, @"missing_headers");
        close(clientFD);
        return;
    }

    NSData *body =
        headerEnd < received.length
        ? [received subdataWithRange:
               NSMakeRange(headerEnd,
                           received.length - headerEnd)]
        : [NSData data];

    NSArray<NSString *> *requestParts =
        [requestLine componentsSeparatedByString:@" "];

    NSString *gamePath =
        requestParts.count >= 2 ? requestParts[1] : @"/";

    diag_record_game_hit(gamePath);
    proxy_request(clientFD, requestLine, headers, body);
    close(clientFD);
}

static void *client_thread(void *context) {
    int clientFD = *(int *)context;
    free(context);

    @autoreleasepool {
        handle_client(clientFD);
    }

    return NULL;
}

static void run_local_selftest(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        diag_set_selftest(NO, @"SELFTEST SOCKET FAIL");
        return;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(kLocalPort);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        diag_set_selftest(
            NO,
            [NSString stringWithFormat:@"SELFTEST CONNECT FAIL (%s)", strerror(errno)]
        );
        close(fd);
        return;
    }

    const char request[] =
        "GET /__LLL_SELFTEST__ HTTP/1.1\r\n"
        "Host: 127.0.0.1:17891\r\n"
        "Connection: close\r\n"
        "\r\n";

    ssize_t sent = send(fd, request, sizeof(request) - 1, 0);
    if (sent <= 0) {
        diag_set_selftest(NO, @"SELFTEST SEND FAIL");
        close(fd);
        return;
    }

    char response[1024];
    memset(response, 0, sizeof(response));
    ssize_t received = recv(fd, response, sizeof(response) - 1, 0);
    close(fd);

    if (received > 0 &&
        strstr(response, "HTTP/1.1 200") != NULL &&
        strstr(response, "LLL_SELFTEST_OK") != NULL) {
        diag_set_selftest(YES, @"SELFTEST PASS");
    } else {
        NSString *snippet =
            received > 0
            ? [[NSString alloc] initWithBytes:response
                                       length:(NSUInteger)received
                                     encoding:NSUTF8StringEncoding]
            : @"<no response>";
        diag_set_selftest(
            NO,
            [NSString stringWithFormat:@"SELFTEST RESP FAIL %@", snippet ?: @"<invalid>"]
        );
    }
}

static void *server_thread(void *unused) {
    (void)unused;

    int serverFD = socket(AF_INET, SOCK_STREAM, 0);

    if (serverFD < 0) {
        NSLog(@"[LLLLOffline][API] socket failed: %s", strerror(errno));
        return NULL;
    }

    int reuse = 1;
    (void)setsockopt(serverFD,
                     SOL_SOCKET,
                     SO_REUSEADDR,
                     &reuse,
                     sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));

    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(kLocalPort);

    if (bind(serverFD,
             (struct sockaddr *)&address,
             sizeof(address)) != 0) {
        NSLog(@"[LLLLOffline][API] bind failed: %s", strerror(errno));
        close(serverFD);
        return NULL;
    }

    if (listen(serverFD, 16) != 0) {
        NSLog(@"[LLLLOffline][API] listen failed: %s", strerror(errno));
        diag_set_bind(NO, @"LISTEN FAIL");
        close(serverFD);
        return NULL;
    }

    NSLog(@"[LLLLOffline][API] listening on 127.0.0.1:%u",
          (unsigned)kLocalPort);
    diag_set_bind(YES, @"BIND PASS");

    for (;;) {
        int clientFD = accept(serverFD, NULL, NULL);

        if (clientFD < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        int *clientArg = (int *)malloc(sizeof(int));
        if (clientArg == NULL) {
            close(clientFD);
            continue;
        }

        *clientArg = clientFD;

        pthread_t worker;
        int createResult = pthread_create(
            &worker,
            NULL,
            client_thread,
            clientArg
        );

        if (createResult != 0) {
            NSLog(@"[LLLLOffline][API] pthread_create failed: %d", createResult);
            close(clientFD);
            free(clientArg);
            continue;
        }

        pthread_detach(worker);
    }

    close(serverFD);
    return NULL;
}

static void start_proxy_once(void) {
    pthread_t thread;

    if (pthread_create(&thread, NULL, server_thread, NULL) == 0) {
        (void)pthread_detach(thread);

        dispatch_async(dispatch_get_main_queue(), ^{
            diag_refresh_main();
        });

        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                run_local_selftest();
                run_api_hook_rewrite_diagnostic();
            });
    } else {
        diag_set_event(@"PROXY START FAIL");
    }
}

void LLLStartApiLocalProxy(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_proxy_once);
}
