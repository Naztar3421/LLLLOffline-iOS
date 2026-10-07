#import "LocalHTTPServer.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static NSString * const kLocalBase = @"http://127.0.0.1:17891";
static NSString * const kPrivateBase = @"https://api-alfa-l4.hasu-link.club";
static NSString * const kOfficialHost = @"api.link-like-lovelive.app";
static NSString * const kPrivateHost = @"api-alfa-l4.hasu-link.club";
static NSString * const kTargetPath = @"/v1/profile/get_info";

static _Thread_local BOOL g_proxyForwarding = NO;

typedef NSURLSessionDataTask *(*LLLDataTaskURLFn)(id, SEL, NSURL *);
typedef NSURLSessionDataTask *(*LLLDataTaskURLBlockFn)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*LLLDataTaskRequestFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*LLLDataTaskRequestBlockFn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static LLLDataTaskURLFn g_origDataTaskURL = NULL;
static LLLDataTaskURLBlockFn g_origDataTaskURLBlock = NULL;
static LLLDataTaskRequestFn g_origDataTaskRequest = NULL;
static LLLDataTaskRequestBlockFn g_origDataTaskRequestBlock = NULL;

static void show_status(NSString *status, BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIWindow *window = nil;

        if (window == nil) {
            window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            window.windowLevel = UIWindowLevelAlert + 1;
            UIViewController *viewController = [UIViewController new];
            viewController.view.backgroundColor = UIColor.clearColor;
            window.rootViewController = viewController;
        }

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 48, 330, 52)];
        label.text = status;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:17.0];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = success
            ? [UIColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:0.92]
            : [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:0.92];
        label.layer.cornerRadius = 10.0;
        label.clipsToBounds = YES;
        [window.rootViewController.view addSubview:label];
        window.hidden = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [label removeFromSuperview];
            if (window.rootViewController.view.subviews.count == 0) {
                window.hidden = YES;
            }
        });
    });
}

static void send_response_data(
    int fd,
    NSInteger status,
    NSString *reason,
    NSData *body,
    NSDictionary<NSString *, NSString *> *headers
) {
    if (body == nil) {
        body = [NSData data];
    }

    NSMutableString *header = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n",
                                (long)status, reason ?: @"OK"];

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        [header appendFormat:@"%@: %@\r\n", key, value];
    }];

    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendString:@"Connection: close\r\n\r\n"];

    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    (void)send(fd, headerData.bytes, headerData.length, 0);
    if (body.length > 0) {
        (void)send(fd, body.bytes, body.length, 0);
    }
}

static void send_json(int fd, NSInteger status, NSString *body, BOOL success) {
    NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
    send_response_data(
        fd,
        status,
        success ? @"OK" : @"Error",
        data,
        @{@"Content-Type": @"application/json; charset=utf-8"}
    );
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

static NSDictionary<NSString *, NSString *> *parse_headers(NSString *headerText) {
    NSMutableDictionary<NSString *, NSString *> *headers = [NSMutableDictionary dictionary];
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
            headers[key] = value;
        }
    }

    return headers;
}

static NSString *header_value_case_insensitive(NSDictionary<NSString *, NSString *> *headers,
                                                NSString *wantedKey) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:wantedKey] == NSOrderedSame) {
            return headers[key];
        }
    }
    return nil;
}

static NSData *read_full_request(int fd, NSString **requestLineOut,
                                 NSDictionary<NSString *, NSString *> **headersOut) {
    NSMutableData *data = [NSMutableData data];
    NSUInteger headerEnd = NSNotFound;
    NSUInteger contentLength = 0;

    for (;;) {
        uint8_t chunk[16384];
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            return nil;
        }

        [data appendBytes:chunk length:(NSUInteger)n];

        headerEnd = find_header_end(data.bytes, data.length);
        if (headerEnd != NSNotFound) {
            NSString *headerText = [[NSString alloc]
                initWithBytes:data.bytes
                length:headerEnd
                encoding:NSUTF8StringEncoding];

            if (headerText == nil) {
                return nil;
            }

            NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
            *requestLineOut = lines.firstObject ?: @"";
            NSDictionary *headers = parse_headers(headerText);
            *headersOut = headers;

            NSString *lengthString = header_value_case_insensitive(headers, @"Content-Length");
            if (lengthString.length > 0) {
                contentLength = (NSUInteger)MAX(0, lengthString.longLongValue);
            }
            break;
        }

        if (data.length > 512 * 1024) {
            return nil;
        }
    }

    NSUInteger bodyAlreadyRead = data.length - headerEnd;
    while (bodyAlreadyRead < contentLength) {
        uint8_t chunk[16384];
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            return nil;
        }

        [data appendBytes:chunk length:(NSUInteger)n];
        bodyAlreadyRead += (NSUInteger)n;

        if (data.length > headerEnd + 8 * 1024 * 1024) {
            return nil;
        }
    }

    return data;
}

static BOOL is_hop_by_hop_header(NSString *key) {
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

static NSString *target_from_request_line(NSString *requestLine) {
    NSArray<NSString *> *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        return nil;
    }
    return parts[1];
}

static NSString *path_from_target(NSString *target) {
    if (target.length == 0) {
        return nil;
    }

    NSString *urlString = [target hasPrefix:@"http://"] || [target hasPrefix:@"https://"]
        ? target
        : [@"http://127.0.0.1" stringByAppendingString:target];

    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    return components.path.length > 0 ? components.path : @"/";
}

static NSMutableURLRequest *build_forward_request(
    NSString *requestLine,
    NSDictionary<NSString *, NSString *> *headers,
    NSData *body
) {
    NSString *target = target_from_request_line(requestLine);
    NSString *method = [[requestLine componentsSeparatedByString:@" "] firstObject];
    if (target.length == 0 || method.length == 0) {
        return nil;
    }

    NSURL *baseURL = [NSURL URLWithString:kPrivateBase];
    NSURL *targetURL = nil;

    if ([target hasPrefix:@"http://"] || [target hasPrefix:@"https://"]) {
        targetURL = [NSURL URLWithString:target];
    } else {
        targetURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                          baseURL.absoluteString, target]];
    }

    if (targetURL == nil) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:targetURL];
    request.HTTPMethod = method;
    request.HTTPBody = body;

    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        if (is_hop_by_hop_header(key)) {
            return;
        }
        [request setValue:value forHTTPHeaderField:key];
    }];

    return request;
}

static void forward_to_private_server(
    int clientFD,
    NSString *requestLine,
    NSDictionary<NSString *, NSString *> *headers,
    NSData *body
) {
    NSMutableURLRequest *request = build_forward_request(requestLine, headers, body);
    if (request == nil) {
        send_json(clientFD, 400, @"{\"error\":\"bad_request\"}", NO);
        return;
    }

    NSLog(@"[LLLLOffline][POC2] LOCAL -> PRIVATE %@", request.URL.absoluteString);

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    __block NSData *responseData = nil;
    __block NSHTTPURLResponse *response = nil;
    __block NSError *responseError = nil;

    g_proxyForwarding = YES;
    NSURLSessionDataTask *task = [session
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *urlResponse, NSError *error) {
            responseData = data ?: [NSData data];
            response = [urlResponse isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)urlResponse
                : nil;
            responseError = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];

    if (dispatch_semaphore_wait(
            sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC))) != 0) {
        g_proxyForwarding = NO;
        [task cancel];
        [session invalidateAndCancel];
        send_json(clientFD, 504, @"{\"error\":\"upstream_timeout\"}", NO);
        return;
    }
    g_proxyForwarding = NO;

    [session finishTasksAndInvalidate];

    if (responseError != nil || response == nil) {
        NSLog(@"[LLLLOffline][POC2] upstream error: %@", responseError);
        send_json(clientFD, 502, @"{\"error\":\"upstream_error\"}", NO);
        return;
    }

    NSMutableDictionary<NSString *, NSString *> *responseHeaders = [NSMutableDictionary dictionary];

    [response.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        NSString *keyString = [key description];
        NSString *valueString = [value description];

        if (is_hop_by_hop_header(keyString)) {
            return;
        }
        responseHeaders[keyString] = valueString;
    }];

    responseHeaders[@"X-LLL-Offline-POC"] = @"localhost-proxy";
    send_response_data(
        clientFD,
        response.statusCode,
        @"Upstream",
        responseData,
        responseHeaders
    );

    NSLog(@"[LLLLOffline][POC2] PRIVATE -> LOCAL -> GAME status=%ld bytes=%lu",
          (long)response.statusCode, (unsigned long)responseData.length);

    dispatch_async(dispatch_get_main_queue(), ^{
        show_status(@"LLL POC2 API HIT", YES);
    });
}

static void *server_thread(void *unused) {
    (void)unused;

    const int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        return NULL;
    }

    int reuse = 1;
    (void)setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(17891);

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(server_fd);
        return NULL;
    }

    if (listen(server_fd, 8) != 0) {
        close(server_fd);
        return NULL;
    }

    NSLog(@"[LLLLOffline][POC2] localhost API server listening on 127.0.0.1:17891");

    for (;;) {
        const int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        NSString *requestLine = nil;
        NSDictionary<NSString *, NSString *> *headers = nil;
        NSData *fullRequest = read_full_request(client_fd, &requestLine, &headers);

        if (fullRequest == nil || requestLine == nil || headers == nil) {
            send_json(client_fd, 400, @"{\"error\":\"malformed_http\"}", NO);
            close(client_fd);
            continue;
        }

        NSUInteger headerEnd = find_header_end(fullRequest.bytes, fullRequest.length);
        if (headerEnd == NSNotFound || headerEnd > fullRequest.length) {
            send_json(client_fd, 400, @"{\"error\":\"missing_headers\"}", NO);
            close(client_fd);
            continue;
        }

        NSData *body = headerEnd < fullRequest.length
            ? [fullRequest subdataWithRange:NSMakeRange(headerEnd, fullRequest.length - headerEnd)]
            : [NSData data];

        NSString *path = path_from_target(target_from_request_line(requestLine) ?: @"");

        NSLog(@"[LLLLOffline][POC2] LOCAL request %@ %@", requestLine, path);

        if ([path isEqualToString:kTargetPath]) {
            forward_to_private_server(client_fd, requestLine, headers, body);
        } else if ([[requestLine componentsSeparatedByString:@" "] firstObject].length > 0 &&
                   [[requestLine componentsSeparatedByString:@" "] firstObject]
                       .caseInsensitiveCompare:@"GET"] == NSOrderedSame &&
                   [path isEqualToString:@"/test"]) {
            send_json(
                client_fd,
                200,
                @"{\"offline\":true,\"service\":\"LLLLOffline-iOS-POC2\"}",
                YES
            );
        } else {
            send_json(client_fd, 404, @"{\"error\":\"not_found\"}", NO);
        }

        close(client_fd);
    }

    close(server_fd);
    return NULL;
}

static NSString *url_host(NSURL *url) {
    return url.host.lowercaseString;
}

static BOOL is_target_url(NSURL *url) {
    if (g_proxyForwarding || url == nil) {
        return NO;
    }

    if (![url.path isEqualToString:kTargetPath]) {
        return NO;
    }

    NSString *host = url_host(url);
    return [host isEqualToString:kOfficialHost] || [host isEqualToString:kPrivateHost];
}

static NSURL *local_url_for(NSURL *url) {
    NSString *pathAndQuery = url.path ?: @"/";
    if (url.query.length > 0) {
        pathAndQuery = [pathAndQuery stringByAppendingFormat:@"?%@", url.query];
    }

    return [NSURL URLWithString:[kLocalBase stringByAppendingString:pathAndQuery]];
}

static NSURLRequest *rewrite_request_if_needed(NSURLRequest *request, BOOL *didRewrite) {
    if (didRewrite != NULL) {
        *didRewrite = NO;
    }

    if (g_proxyForwarding || request == nil || !is_target_url(request.URL)) {
        return request;
    }

    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    NSURL *originalURL = mutableRequest.URL;
    NSURL *localURL = local_url_for(originalURL);
    mutableRequest.URL = localURL;

    if (didRewrite != NULL) {
        *didRewrite = YES;
    }

    NSLog(@"[LLLLOffline][POC2] REDIRECT %@ -> %@", originalURL.absoluteString, localURL.absoluteString);
    return mutableRequest;
}

static NSURL *rewrite_url_if_needed(NSURL *url, BOOL *didRewrite) {
    if (didRewrite != NULL) {
        *didRewrite = NO;
    }

    if (g_proxyForwarding || !is_target_url(url)) {
        return url;
    }

    NSURL *localURL = local_url_for(url);
    if (didRewrite != NULL) {
        *didRewrite = YES;
    }

    NSLog(@"[LLLLOffline][POC2] REDIRECT %@ -> %@", url.absoluteString, localURL.absoluteString);
    return localURL;
}

static NSURLSessionDataTask *hook_dataTaskWithURL(
    id self, SEL _cmd, NSURL *url
) {
    BOOL didRewrite = NO;
    NSURL *rewrittenURL = rewrite_url_if_needed(url, &didRewrite);
    if (didRewrite) {
        dispatch_async(dispatch_get_main_queue(), ^{
            show_status(@"LLL POC2 REDIRECT", YES);
        });
    }
    return g_origDataTaskURL(self, _cmd, rewrittenURL);
}

static NSURLSessionDataTask *hook_dataTaskWithURL_block(
    id self, SEL _cmd, NSURL *url,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    BOOL didRewrite = NO;
    NSURL *rewrittenURL = rewrite_url_if_needed(url, &didRewrite);
    if (didRewrite) {
        dispatch_async(dispatch_get_main_queue(), ^{
            show_status(@"LLL POC2 REDIRECT", YES);
        });
    }
    return g_origDataTaskURLBlock(self, _cmd, rewrittenURL, completionHandler);
}

static NSURLSessionDataTask *hook_dataTaskWithRequest(
    id self, SEL _cmd, NSURLRequest *request
) {
    BOOL didRewrite = NO;
    NSURLRequest *rewrittenRequest = rewrite_request_if_needed(request, &didRewrite);
    if (didRewrite) {
        dispatch_async(dispatch_get_main_queue(), ^{
            show_status(@"LLL POC2 REDIRECT", YES);
        });
    }
    return g_origDataTaskRequest(self, _cmd, rewrittenRequest);
}

static NSURLSessionDataTask *hook_dataTaskWithRequest_block(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    BOOL didRewrite = NO;
    NSURLRequest *rewrittenRequest = rewrite_request_if_needed(request, &didRewrite);
    if (didRewrite) {
        dispatch_async(dispatch_get_main_queue(), ^{
            show_status(@"LLL POC2 REDIRECT", YES);
        });
    }
    return g_origDataTaskRequestBlock(self, _cmd, rewrittenRequest, completionHandler);
}

static void install_poc2_hook(NSString *selectorName, IMP replacement, IMP *originalOut) {
    Class cls = NSClassFromString(@"NSURLSession");
    SEL selector = NSSelectorFromString(selectorName);

    if (cls == Nil) {
        NSLog(@"[LLLLOffline][POC2] NSURLSession class missing");
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        NSLog(@"[LLLLOffline][POC2] missing %@", selectorName);
        return;
    }

    IMP original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    *originalOut = original;

    NSLog(@"[LLLLOffline][POC2] installed %@ old=%p new=%p",
          selectorName, original, replacement);
}

static void install_poc2_hooks(void) {
    install_poc2_hook(@"dataTaskWithURL:",
                      (IMP)hook_dataTaskWithURL,
                      (IMP *)&g_origDataTaskURL);

    install_poc2_hook(@"dataTaskWithURL:completionHandler:",
                      (IMP)hook_dataTaskWithURL_block,
                      (IMP *)&g_origDataTaskURLBlock);

    install_poc2_hook(@"dataTaskWithRequest:",
                      (IMP)hook_dataTaskWithRequest,
                      (IMP *)&g_origDataTaskRequest);

    install_poc2_hook(@"dataTaskWithRequest:completionHandler:",
                      (IMP)hook_dataTaskWithRequest_block,
                      (IMP *)&g_origDataTaskRequestBlock);
}

static void run_self_test(void) {
    NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:17891/test"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            BOOL ok = NO;

            if (error == nil && [response isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger status = [(NSHTTPURLResponse *)response statusCode];
                NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                ok = status == 200 && [body containsString:@"\"offline\":true"];
            }

            NSLog(@"[LLLLOffline] localhost self-test: %@", ok ? @"OK" : @"FAIL");
            show_status(ok ? @"LLL LOCALHOST OK" : @"LLL LOCALHOST FAIL", ok);
        }];

    [task resume];
}

static void start_server_once(void) {
    install_poc2_hooks();

    pthread_t thread;
    if (pthread_create(&thread, NULL, server_thread, NULL) == 0) {
        (void)pthread_detach(thread);
    }
}

void LLLStartLocalHTTPServer(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_server_once);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        run_self_test();
    });
}
