#import "ApiLocalProxy.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString * const kLocalHost = @"127.0.0.1";
static const uint16_t kLocalPort = 17891;
static NSString * const kUpstreamBase = @"https://api-alfa-l4.hasu-link.club";

static void show_status(NSString *status) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIWindow *window = nil;

        if (window == nil) {
            window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            window.windowLevel = UIWindowLevelAlert + 1;

            UIViewController *controller = [UIViewController new];
            controller.view.backgroundColor = UIColor.clearColor;
            window.rootViewController = controller;
        }

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 42, 359, 78)];
        label.text = status ?: @"";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 3;
        label.font = [UIFont boldSystemFontOfSize:13.0];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:0.92];
        label.layer.cornerRadius = 10.0;
        label.clipsToBounds = YES;

        [window.rootViewController.view addSubview:label];
        window.hidden = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [label removeFromSuperview];
            if (window.rootViewController.view.subviews.count == 0) {
                window.hidden = YES;
            }
        });
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

static BOOL is_hop_header(NSString *key) {
    static NSSet<NSString *> *hopHeaders;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        hopHeaders = [NSSet setWithArray:@[
            @"connection",
            @"proxy-connection",
            @"keep-alive",
            @"transfer-encoding",
            @"upgrade",
            @"host",
            @"content-length"
        ]];
    });

    return [hopHeaders containsObject:key.lowercaseString];
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

static void send_http_response(int fd,
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

    (void)send(fd, headerData.bytes, headerData.length, 0);

    if (body.length > 0) {
        (void)send(fd, body.bytes, body.length, 0);
    }
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

    return request;
}

static void proxy_request(int clientFD,
                          NSString *requestLine,
                          NSDictionary<NSString *, NSString *> *headers,
                          NSData *body) {
    NSMutableURLRequest *upstream =
        build_upstream_request(requestLine, headers, body);

    if (upstream == nil) {
        send_json_error(clientFD, 400, @"bad_request");
        return;
    }

    NSString *path = upstream.URL.path ?: @"/";

    show_status(
        [NSString stringWithFormat:@"LLL API LOCAL HIT\n%@", path]
    );

    NSLog(@"[LLLLOffline][API] LOCAL -> %@", upstream.URL.absoluteString);

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration defaultSessionConfiguration];

    configuration.requestCachePolicy =
        NSURLRequestReloadIgnoringLocalCacheData;

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

    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:
        ^(id key, id value, BOOL *stop) {
            (void)stop;

            NSString *keyString = [key description];
            NSString *valueString = [value description];

            if (is_hop_header(keyString)) {
                return;
            }

            responseHeaders[keyString] = valueString;
        }];

    responseHeaders[@"X-LLL-API-LOCAL"] = @"1";

    send_http_response(
        clientFD,
        response.statusCode,
        @"Upstream",
        responseData,
        responseHeaders
    );

    show_status(
        [NSString stringWithFormat:@"LLL API UPSTREAM %ld\n%@",
         (long)response.statusCode,
         path]
    );

    NSLog(@"[LLLLOffline][API] PRIVATE -> GAME status=%ld bytes=%lu",
          (long)response.statusCode,
          (unsigned long)responseData.length);
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
        close(serverFD);
        return NULL;
    }

    NSLog(@"[LLLLOffline][API] listening on 127.0.0.1:%u",
          (unsigned)kLocalPort);

    for (;;) {
        int clientFD = accept(serverFD, NULL, NULL);

        if (clientFD < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        NSString *requestLine = nil;
        NSDictionary<NSString *, NSString *> *headers = nil;

        NSData *received =
            read_request(clientFD, &requestLine, &headers);

        if (received == nil || requestLine == nil || headers == nil) {
            send_json_error(clientFD, 400, @"malformed_http");
            close(clientFD);
            continue;
        }

        NSUInteger headerEnd =
            find_header_end(received.bytes, received.length);

        if (headerEnd == NSNotFound ||
            headerEnd > received.length) {
            send_json_error(clientFD, 400, @"missing_headers");
            close(clientFD);
            continue;
        }

        NSData *body =
            headerEnd < received.length
            ? [received subdataWithRange:
                   NSMakeRange(headerEnd,
                               received.length - headerEnd)]
            : [NSData data];

        proxy_request(clientFD, requestLine, headers, body);
        close(clientFD);
    }

    close(serverFD);
    return NULL;
}

static void start_proxy_once(void) {
    pthread_t thread;

    if (pthread_create(&thread, NULL, server_thread, NULL) == 0) {
        (void)pthread_detach(thread);
        show_status(@"LLL API LOCAL PROXY READY");
    } else {
        show_status(@"LLL API PROXY START FAIL");
    }
}

void LLLStartApiLocalProxy(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_proxy_once);
}
