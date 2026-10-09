#import "ApiLocalProxy.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netdb.h>
#include <sys/time.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdint.h>

static NSString * const kLocalHost = @"127.0.0.1";
static const uint16_t kLocalPort = 17891;
static NSString * const kUpstreamBase = @"https://api-alfa-l4.hasu-link.club";

/*
 * Optional Info.plist override for LAN integration testing.
 * Set LLLAPIUpstreamBaseURL to e.g. http://192.168.1.100:9527
 * when packaging a test IPA. If absent, retain the proven private-server
 * upstream. Plain HTTP uses a raw socket below, avoiding NSURLSession ATS.
 */
static NSString *upstream_base_url(void) {
    id candidate = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"LLLAPIUpstreamBaseURL"];
    if ([candidate isKindOfClass:NSString.class]) {
        NSString *value = [(NSString *)candidate stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSURL *url = [NSURL URLWithString:value];
        if (value.length > 0 &&
            ( [url.scheme.lowercaseString isEqualToString:@"http"] ||
              [url.scheme.lowercaseString isEqualToString:@"https"] ) &&
            url.host.length > 0) {
            while ([value hasSuffix:@"/"]) {
                value = [value substringToIndex:value.length - 1];
            }
            return value;
        }
    }
    return kUpstreamBase;
}

static UIWindow *gDiagWindow = nil;
static UILabel *gDiagLabel = nil;
static BOOL gBindPass = NO;
static BOOL gSelfTestPass = NO;
static BOOL gRewritePass = NO;
static NSUInteger gGameHitCount = 0;
static NSString *gLastPath = @"-";
static NSString *gLastEvent = @"STARTING";
static uint64_t gCaptureCount = 0;
static uint64_t gCaptureWriteOK = 0;
static uint64_t gCaptureWriteFail = 0;
static uint64_t gLastCaptureID = 0;
static NSString *gLastCapturePath = @"-";
static BOOL gCaptureRootReady = NO;

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
        gDiagLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 36, 359, 176)];
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
             @"GAME HIT %lu   CAPTURE %llu\n"
             @"WRITES   %llu OK / %llu FAIL\n"
             @"ROOT     %@\n"
             @"LAST     #%llu %@\n"
             @"EVENT    %@",
            bind, selfTest, rewrite,
            (unsigned long)gGameHitCount,
            (unsigned long long)gCaptureCount,
            (unsigned long long)gCaptureWriteOK,
            (unsigned long long)gCaptureWriteFail,
            gCaptureRootReady ? @"OK" : @"FAIL",
            (unsigned long long)gLastCaptureID,
            gLastCapturePath ?: @"-",
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

static void diag_record_capture_start(uint64_t captureID, NSString *path) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCaptureCount += 1;
        gLastCaptureID = captureID;
        gLastCapturePath = [path copy] ?: @"/";
        gLastEvent = [NSString stringWithFormat:@"CAPTURE #%llu START %@",
                       (unsigned long long)captureID,
                       gLastCapturePath];
        diag_refresh_main();
    });
}

static void diag_record_capture_write(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (success) {
            gCaptureWriteOK += 1;
        } else {
            gCaptureWriteFail += 1;
        }
        diag_refresh_main();
    });
}

static void diag_record_capture_root(BOOL ready) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gCaptureRootReady = ready;
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
            [upstream_base_url() stringByAppendingString:target]];

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

static uint64_t gCaptureSequence = 0;

static NSString *capture_root_directory(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            YES
        );

    NSString *documents =
        paths.count > 0 ? paths[0] : nil;

    if (documents.length == 0) {
        return nil;
    }

    return [documents stringByAppendingPathComponent:@"LLLL_API_Capture"];
}

static NSString *capture_file_path(uint64_t captureID,
                                   NSString *suffix) {
    NSString *root = capture_root_directory();
    if (root.length == 0) {
        return nil;
    }

    NSError *directoryError = nil;
    BOOL created = [[NSFileManager defaultManager]
        createDirectoryAtPath:root
        withIntermediateDirectories:YES
        attributes:nil
        error:&directoryError];

    if (!created && directoryError != nil) {
        NSLog(@"[LLLLOffline][CAPTURE] mkdir failed: %@",
              directoryError);
        diag_record_capture_root(NO);
        return nil;
    }

    diag_record_capture_root(YES);

    return [root stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%06llu_%@",
         (unsigned long long)captureID,
         suffix ?: @"data"]];
}

static void capture_write_json(uint64_t captureID,
                               NSString *suffix,
                               NSDictionary *object) {
    NSString *path = capture_file_path(captureID, suffix);
    if (path.length == 0) {
        diag_record_capture_write(NO);
        return;
    }

    NSData *json =
        [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                         options:NSJSONWritingPrettyPrinted
                                           error:nil];

    if (json == nil) {
        diag_record_capture_write(NO);
        return;
    }

    BOOL ok = [json writeToFile:path atomically:YES];
    diag_record_capture_write(ok);

    if (!ok) {
        NSLog(@"[LLLLOffline][CAPTURE] JSON write failed: %@",
              path);
    }
}

static void capture_write_data(uint64_t captureID,
                               NSString *suffix,
                               NSData *data) {
    NSString *path = capture_file_path(captureID, suffix);
    if (path.length == 0) {
        diag_record_capture_write(NO);
        return;
    }

    BOOL ok = [(data ?: [NSData data]) writeToFile:path atomically:YES];
    diag_record_capture_write(ok);

    if (!ok) {
        NSLog(@"[LLLLOffline][CAPTURE] data write failed: %@",
              path);
    }
}

static uint64_t capture_request(NSString *requestLine,
                                NSDictionary<NSString *, NSString *> *headers,
                                NSData *body) {
    uint64_t captureID =
        __sync_add_and_fetch(&gCaptureSequence, 1);

    NSString *path = @"/";
    NSArray<NSString *> *parts =
        [requestLine componentsSeparatedByString:@" "];

    if (parts.count >= 2) {
        path = parts[1] ?: @"/";
    }

    diag_record_capture_start(captureID, path);

    capture_write_json(
        captureID,
        @"request.json",
        @{
            @"capture_id": @(captureID),
            @"request_line": requestLine ?: @"",
            @"path": path ?: @"/",
            @"headers": headers ?: @{},
            @"request_bytes": @((unsigned long long)(body.length))
        }
    );

    capture_write_data(captureID, @"request.bin", body);

    return captureID;
}

static void capture_response(uint64_t captureID,
                             NSHTTPURLResponse *response,
                             NSData *body,
                             NSDictionary<NSString *, NSString *> *headers,
                             NSError *error) {
    NSMutableDictionary *result = [@{
        @"capture_id": @(captureID),
        @"status": response ? @(response.statusCode) : [NSNull null],
        @"headers": headers ?: @{},
        @"response_bytes": @((unsigned long long)(body.length))
    } mutableCopy];

    if (error != nil) {
        result[@"error"] = error.localizedDescription ?: @"unknown";
    }

    capture_write_json(captureID, @"response.json", result);
    capture_write_data(captureID, @"response.bin", body);
}


static NSUInteger find_crlf_from(const uint8_t *bytes,
                                 NSUInteger start,
                                 NSUInteger length) {
    if (length < 2 || start >= length) {
        return NSNotFound;
    }
    for (NSUInteger i = start; i + 1 < length; i++) {
        if (bytes[i] == 0x0d && bytes[i + 1] == 0x0a) {
            return i;
        }
    }
    return NSNotFound;
}

static NSData *decode_chunked_body(NSData *chunked, BOOL *validOut) {
    if (validOut) {
        *validOut = NO;
    }

    NSMutableData *decoded = [NSMutableData data];
    const uint8_t *bytes = chunked.bytes;
    NSUInteger length = chunked.length;
    NSUInteger cursor = 0;

    while (cursor < length) {
        NSUInteger lineEnd = find_crlf_from(bytes, cursor, length);
        if (lineEnd == NSNotFound) {
            return nil;
        }

        NSString *line = [[NSString alloc] initWithBytes:bytes + cursor
                                                 length:lineEnd - cursor
                                               encoding:NSASCIIStringEncoding];
        if (line == nil) {
            return nil;
        }

        NSRange semicolon = [line rangeOfString:@";"];
        NSString *sizeText = semicolon.location == NSNotFound
            ? line
            : [line substringToIndex:semicolon.location];
        sizeText = [sizeText stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceCharacterSet];

        char *endPtr = NULL;
        unsigned long long chunkSize = strtoull(sizeText.UTF8String, &endPtr, 16);
        if (endPtr == sizeText.UTF8String || endPtr == NULL || *endPtr != '\0') {
            return nil;
        }

        cursor = lineEnd + 2;

        if (chunkSize == 0) {
            if (validOut) {
                *validOut = YES;
            }
            return [decoded copy];
        }

        if (chunkSize > (unsigned long long)(length - cursor) ||
            length - cursor - (NSUInteger)chunkSize < 2) {
            return nil;
        }

        [decoded appendBytes:bytes + cursor length:(NSUInteger)chunkSize];
        cursor += (NSUInteger)chunkSize;

        if (bytes[cursor] != 0x0d || bytes[cursor + 1] != 0x0a) {
            return nil;
        }
        cursor += 2;
    }

    return nil;
}

static void raw_http_set_error(NSError **errorOut,
                               NSInteger code,
                               NSString *message) {
    if (errorOut) {
        *errorOut = [NSError errorWithDomain:@"LLLLRawHTTP"
                                        code:code
                                    userInfo:@{
            NSLocalizedDescriptionKey: message ?: @"raw HTTP request failed"
        }];
    }
}

static BOOL raw_http_request(NSURLRequest *request,
                             NSInteger *statusOut,
                             NSDictionary<NSString *, NSString *> **headersOut,
                             NSData **bodyOut,
                             NSError **errorOut) {
    NSURL *url = request.URL;
    if (url == nil ||
        ![url.scheme.lowercaseString isEqualToString:@"http"] ||
        url.host.length == 0) {
        raw_http_set_error(errorOut, 1, @"invalid_http_upstream_url");
        return NO;
    }

    NSString *portString = url.port ? url.port.stringValue : @"80";

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *addresses = NULL;
    int gaiResult = getaddrinfo(url.host.UTF8String,
                                portString.UTF8String,
                                &hints,
                                &addresses);
    if (gaiResult != 0) {
        raw_http_set_error(errorOut, 2,
            [NSString stringWithFormat:@"getaddrinfo: %s", gai_strerror(gaiResult)]);
        return NO;
    }

    int upstreamFD = -1;
    int connectError = 0;

    for (struct addrinfo *item = addresses; item != NULL; item = item->ai_next) {
        upstreamFD = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (upstreamFD < 0) {
            connectError = errno;
            continue;
        }

        struct timeval timeout;
        timeout.tv_sec = 45;
        timeout.tv_usec = 0;
        (void)setsockopt(upstreamFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        (void)setsockopt(upstreamFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

        if (connect(upstreamFD, item->ai_addr, item->ai_addrlen) == 0) {
            break;
        }

        connectError = errno;
        close(upstreamFD);
        upstreamFD = -1;
    }
    freeaddrinfo(addresses);

    if (upstreamFD < 0) {
        raw_http_set_error(errorOut, 3,
            [NSString stringWithFormat:@"upstream connect failed: %s",
             strerror(connectError ?: ECONNREFUSED)]);
        return NO;
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *target = components.percentEncodedPath.length > 0
        ? components.percentEncodedPath
        : @"/";
    if (components.percentEncodedQuery.length > 0) {
        target = [target stringByAppendingFormat:@"?%@", components.percentEncodedQuery];
    }

    NSString *method = request.HTTPMethod.length > 0 ? request.HTTPMethod : @"GET";
    NSMutableString *head =
        [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", method, target];

    NSString *hostHeader = url.host;
    if (url.port && url.port.integerValue != 80) {
        hostHeader = [NSString stringWithFormat:@"%@:%@", url.host, portString];
    }
    [head appendFormat:@"Host: %@\r\n", hostHeader];

    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSString *value, BOOL *stop) {
            (void)stop;
            if (key.length == 0 || value == nil ||
                is_hop_header(key) ||
                [key caseInsensitiveCompare:@"host"] == NSOrderedSame ||
                [key caseInsensitiveCompare:@"content-length"] == NSOrderedSame) {
                return;
            }
            [head appendFormat:@"%@: %@\r\n", key, value];
        }];

    NSData *body = request.HTTPBody ?: [NSData data];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [head appendString:@"Connection: close\r\n\r\n"];

    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    BOOL sentHead = send_all(upstreamFD, headData.bytes, headData.length);
    BOOL sentBody = !sentHead || body.length == 0
        ? sentHead
        : send_all(upstreamFD, body.bytes, body.length);

    if (!sentHead || !sentBody) {
        int savedErrno = errno;
        close(upstreamFD);
        raw_http_set_error(errorOut, 4,
            [NSString stringWithFormat:@"upstream send failed: %s",
             strerror(savedErrno)]);
        return NO;
    }

    NSMutableData *received = [NSMutableData data];
    NSUInteger headerEnd = NSNotFound;
    uint8_t buffer[16384];

    while (headerEnd == NSNotFound) {
        ssize_t count = recv(upstreamFD, buffer, sizeof(buffer), 0);
        if (count <= 0) {
            int savedErrno = errno;
            close(upstreamFD);
            raw_http_set_error(errorOut, 5,
                [NSString stringWithFormat:@"upstream closed before headers: %s",
                 count < 0 ? strerror(savedErrno) : "EOF"]);
            return NO;
        }
        [received appendBytes:buffer length:(NSUInteger)count];
        if (received.length > 1024 * 1024) {
            close(upstreamFD);
            raw_http_set_error(errorOut, 6, @"upstream_headers_too_large");
            return NO;
        }
        headerEnd = find_header_end(received.bytes, received.length);
    }

    NSString *headerText = [[NSString alloc] initWithBytes:received.bytes
                                                   length:headerEnd
                                                 encoding:NSUTF8StringEncoding];
    if (headerText == nil) {
        close(upstreamFD);
        raw_http_set_error(errorOut, 7, @"upstream_headers_not_utf8");
        return NO;
    }

    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSArray<NSString *> *statusParts =
        [lines.firstObject componentsSeparatedByString:@" "];
    if (statusParts.count < 2) {
        close(upstreamFD);
        raw_http_set_error(errorOut, 8, @"upstream_invalid_status_line");
        return NO;
    }

    NSInteger statusCode = statusParts[1].integerValue;
    if (statusCode < 100 || statusCode > 599) {
        close(upstreamFD);
        raw_http_set_error(errorOut, 9, @"upstream_invalid_status_code");
        return NO;
    }

    NSDictionary<NSString *, NSString *> *responseHeaders = parse_headers(headerText);
    NSString *transferEncoding = header_value(responseHeaders, @"Transfer-Encoding");
    NSString *contentLengthText = header_value(responseHeaders, @"Content-Length");
    BOOL chunked = [transferEncoding.lowercaseString containsString:@"chunked"];
    unsigned long long contentLength = contentLengthText.length > 0
        ? strtoull(contentLengthText.UTF8String, NULL, 10)
        : 0;

    if (contentLength > 64ULL * 1024ULL * 1024ULL) {
        close(upstreamFD);
        raw_http_set_error(errorOut, 10, @"upstream_body_too_large");
        return NO;
    }

    NSUInteger initialBodyOffset = headerEnd;
    NSUInteger initialBodyLength = received.length - initialBodyOffset;

    if (chunked || contentLengthText.length == 0) {
        for (;;) {
            ssize_t count = recv(upstreamFD, buffer, sizeof(buffer), 0);
            if (count < 0) {
                if (errno == EINTR) {
                    continue;
                }
                int savedErrno = errno;
                close(upstreamFD);
                raw_http_set_error(errorOut, 11,
                    [NSString stringWithFormat:@"upstream body read failed: %s",
                     strerror(savedErrno)]);
                return NO;
            }
            if (count == 0) {
                break;
            }
            [received appendBytes:buffer length:(NSUInteger)count];
            if (received.length > 65 * 1024 * 1024) {
                close(upstreamFD);
                raw_http_set_error(errorOut, 12, @"upstream_body_too_large");
                return NO;
            }
        }
    } else {
        while (initialBodyLength < (NSUInteger)contentLength) {
            ssize_t count = recv(upstreamFD, buffer, sizeof(buffer), 0);
            if (count <= 0) {
                int savedErrno = errno;
                close(upstreamFD);
                raw_http_set_error(errorOut, 13,
                    [NSString stringWithFormat:@"incomplete upstream body: %s",
                     count < 0 ? strerror(savedErrno) : "EOF"]);
                return NO;
            }
            [received appendBytes:buffer length:(NSUInteger)count];
            initialBodyLength = received.length - initialBodyOffset;
            if (initialBodyLength > 65 * 1024 * 1024) {
                close(upstreamFD);
                raw_http_set_error(errorOut, 14, @"upstream_body_too_large");
                return NO;
            }
        }
    }

    close(upstreamFD);

    NSData *wireBody = [received subdataWithRange:
        NSMakeRange(initialBodyOffset, received.length - initialBodyOffset)];
    NSData *responseBody = wireBody;

    if (chunked) {
        BOOL validChunked = NO;
        responseBody = decode_chunked_body(wireBody, &validChunked);
        if (!validChunked || responseBody == nil) {
            raw_http_set_error(errorOut, 15, @"invalid_chunked_response");
            return NO;
        }
    } else if (contentLengthText.length > 0 &&
               responseBody.length > (NSUInteger)contentLength) {
        responseBody = [responseBody subdataWithRange:
            NSMakeRange(0, (NSUInteger)contentLength)];
    }

    if (statusOut) {
        *statusOut = statusCode;
    }
    if (headersOut) {
        *headersOut = responseHeaders;
    }
    if (bodyOut) {
        *bodyOut = responseBody ?: [NSData data];
    }
    if (errorOut) {
        *errorOut = nil;
    }
    return YES;
}

static void proxy_request(int clientFD,
                          NSString *requestLine,
                          NSDictionary<NSString *, NSString *> *headers,
                          NSData *body) {
    uint64_t captureID =
        capture_request(requestLine, headers, body);

    NSMutableURLRequest *upstream =
        build_upstream_request(requestLine, headers, body);

    if (upstream == nil) {
        capture_write_json(
            captureID,
            @"response.json",
            @{
                @"capture_id": @(captureID),
                @"status": @400,
                @"error": @"bad_request"
            }
        );
        send_json_error(clientFD, 400, @"bad_request");
        return;
    }

    NSString *path = upstream.URL.path ?: @"/";

    NSLog(@"[LLLLOffline][API] LOCAL -> %@ method=%@ bytes=%lu",
          upstream.URL.absoluteString,
          upstream.HTTPMethod ?: @"<nil>",
          (unsigned long)body.length);

    NSData *responseData = nil;
    NSHTTPURLResponse *response = nil;
    NSError *responseError = nil;
    long waitResult = 0;
    NSURLSessionDataTask *task = nil;

    if ([upstream.URL.scheme.lowercaseString isEqualToString:@"http"]) {
        NSInteger rawStatus = 0;
        NSDictionary<NSString *, NSString *> *rawHeaders = nil;
        NSData *rawBody = nil;

        BOOL rawOK = raw_http_request(upstream,
                                      &rawStatus,
                                      &rawHeaders,
                                      &rawBody,
                                      &responseError);
        if (rawOK) {
            responseData = rawBody ?: [NSData data];
            response = [[NSHTTPURLResponse alloc]
                initWithURL:upstream.URL
                statusCode:rawStatus
                HTTPVersion:@"HTTP/1.1"
                headerFields:rawHeaders ?: @{}];
        }
    } else {
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

        __block NSData *sessionResponseData = nil;
        __block NSHTTPURLResponse *sessionResponse = nil;
        __block NSError *sessionError = nil;

        task =
            [session dataTaskWithRequest:upstream
                       completionHandler:^(NSData *data,
                                           NSURLResponse *urlResponse,
                                           NSError *error) {
            sessionResponseData = data ?: [NSData data];

            if ([urlResponse isKindOfClass:NSHTTPURLResponse.class]) {
                sessionResponse = (NSHTTPURLResponse *)urlResponse;
            }

            sessionError = error;
            dispatch_semaphore_signal(semaphore);
        }];

        [task resume];

        waitResult =
            dispatch_semaphore_wait(
                semaphore,
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(45.0 * NSEC_PER_SEC)));

        [session finishTasksAndInvalidate];
        responseData = sessionResponseData;
        response = sessionResponse;
        responseError = sessionError;
    }

    if (waitResult != 0) {
        [task cancel];
        capture_write_json(
            captureID,
            @"response.json",
            @{
                @"capture_id": @(captureID),
                @"status": @504,
                @"error": @"upstream_timeout"
            }
        );
        send_json_error(clientFD, 504, @"upstream_timeout");
        return;
    }

    if (responseError != nil || response == nil) {
        NSLog(@"[LLLLOffline][API] upstream error: %@", responseError);
        capture_response(
            captureID,
            response,
            responseData,
            @{},
            responseError
        );
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

    capture_response(
        captureID,
        response,
        responseData,
        responseHeaders,
        nil
    );

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
    NSString *root = capture_root_directory();

    if (root.length > 0) {
        NSError *error = nil;
        BOOL ok = [[NSFileManager defaultManager]
            createDirectoryAtPath:root
            withIntermediateDirectories:YES
            attributes:nil
            error:&error];

        diag_record_capture_root(ok || error == nil);

        if (!ok && error != nil) {
            NSLog(@"[LLLLOffline][CAPTURE] startup mkdir failed: %@", error);
        }
    } else {
        diag_record_capture_root(NO);
    }

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
