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

static NSObject *g_observeLock = nil;
static unsigned long g_hitCount = 0;

typedef NSURLSessionDataTask *(*TaskURLFn)(id, SEL, NSURL *);
typedef NSURLSessionDataTask *(*TaskURLBlockFn)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*TaskRequestFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*TaskRequestBlockFn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*UploadRequestDataFn)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*UploadRequestFileFn)(id, SEL, NSURLRequest *, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*UploadRequestStreamFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionDownloadTask *(*DownloadRequestBlockFn)(id, SEL, NSURLRequest *, void (^)(NSURL *, NSURLResponse *, NSError *));
typedef NSURLSessionDownloadTask *(*DownloadURLBlockFn)(id, SEL, NSURL *, void (^)(NSURL *, NSURLResponse *, NSError *));

typedef id (*ReqWithURLFn)(id, SEL, NSURL *);
typedef id (*ReqInitURLFn)(id, SEL, NSURL *);
typedef id (*ReqInitURLPolicyFn)(id, SEL, NSURL *, NSURLRequestCachePolicy, NSTimeInterval);
typedef void (*SetURLFn)(id, SEL, NSURL *);

typedef NSURL *(*URLWithStringFn)(id, SEL, NSString *);
typedef NSURL *(*URLWithStringRelativeFn)(id, SEL, NSString *, NSURL *);
typedef NSURL *(*URLWithStringEncodingFn)(id, SEL, NSString *, BOOL);
typedef NSURLSession *(*SessionWithConfigFn)(id, SEL, NSURLSessionConfiguration *);
typedef NSURLSession *(*SessionWithConfigDelegateFn)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);
typedef id (*SessionInitWithConfigFn)(id, SEL, NSURLSessionConfiguration *);
typedef id (*SessionInitWithConfigDelegateFn)(id, SEL, NSURLSessionConfiguration *, id, NSOperationQueue *);


static TaskURLFn g_forwardTaskURL = NULL;
static TaskURLBlockFn g_forwardTaskURLBlock = NULL;
static TaskRequestFn g_forwardTaskRequest = NULL;
static TaskRequestBlockFn g_forwardTaskRequestBlock = NULL;
static UploadRequestDataFn g_forwardUploadRequestData = NULL;
static UploadRequestFileFn g_forwardUploadRequestFile = NULL;
static UploadRequestStreamFn g_forwardUploadRequestStream = NULL;
static DownloadRequestBlockFn g_forwardDownloadRequestBlock = NULL;
static DownloadURLBlockFn g_forwardDownloadURLBlock = NULL;

static ReqWithURLFn g_forwardReqWithURL = NULL;
static ReqInitURLFn g_forwardReqInitURL = NULL;
static ReqInitURLPolicyFn g_forwardReqInitURLPolicy = NULL;
static SetURLFn g_forwardSetURL = NULL;

static URLWithStringFn g_forwardURLWithString = NULL;
static URLWithStringRelativeFn g_forwardURLWithStringRelative = NULL;
static URLWithStringEncodingFn g_forwardURLWithStringEncoding = NULL;
static SessionWithConfigFn g_forwardSessionWithConfig = NULL;
static SessionWithConfigDelegateFn g_forwardSessionWithConfigDelegate = NULL;
static SessionInitWithConfigFn g_forwardSessionInitWithConfig = NULL;
static SessionInitWithConfigDelegateFn g_forwardSessionInitWithConfigDelegate = NULL;
static Class g_trackedSessionClass = Nil;


static void show_status(NSString *status, BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIWindow *window = nil;

        if (window == nil) {
            window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            window.windowLevel = UIWindowLevelAlert + 1;

            UIViewController *controller = [UIViewController new];
            controller.view.backgroundColor = UIColor.clearColor;
            window.rootViewController = controller;
        }

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 42, 359, 76)];
        label.text = status ?: @"";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 3;
        label.font = [UIFont boldSystemFontOfSize:13.0];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = success
            ? [UIColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:0.92]
            : [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:0.92];
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

static NSString *compactURL(NSURL *url) {
    if (url == nil) {
        return @"<nil>";
    }

    NSString *host = url.host ?: @"<no-host>";
    NSString *path = url.path.length > 0 ? url.path : @"/";

    NSString *text = [NSString stringWithFormat:@"%@%@", host, path];

    if (url.query.length > 0) {
        text = [text stringByAppendingFormat:@"?%@", url.query];
    }

    if (text.length > 145) {
        text = [[text substringToIndex:142] stringByAppendingString:@"..."];
    }

    return text;
}

static void observe_url(NSURL *url, NSString *source) {
    if (url == nil) {
        return;
    }

    NSString *shown = compactURL(url);
    unsigned long count;

    @synchronized (g_observeLock) {
        if (g_hitCount >= 30) {
            return;
        }

        g_hitCount += 1;
        count = g_hitCount;
    }

    NSLog(@"[LLLLOffline][OBSERVE] HIT #%lu %@ %@", count, source, url.absoluteString);

    show_status(
        [NSString stringWithFormat:@"LLL URL HIT #%lu\n%@\n%@", count, source, shown],
        YES
    );
}

/*
 * NSURLSession
 */

static NSURLSessionDataTask *hookTaskURL(id self, SEL _cmd, NSURL *url) {
    observe_url(url, @"NSURLSession.URL");

    return g_forwardTaskURL != NULL
        ? g_forwardTaskURL(self, _cmd, url)
        : nil;
}

static NSURLSessionDataTask *hookTaskURLBlock(
    id self, SEL _cmd, NSURL *url,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_url(url, @"NSURLSession.URL:block");

    return g_forwardTaskURLBlock != NULL
        ? g_forwardTaskURLBlock(self, _cmd, url, completionHandler)
        : nil;
}

static NSURLSessionDataTask *hookTaskRequest(id self, SEL _cmd, NSURLRequest *request) {
    observe_url(request.URL, @"NSURLSession.request");

    return g_forwardTaskRequest != NULL
        ? g_forwardTaskRequest(self, _cmd, request)
        : nil;
}

static NSURLSessionDataTask *hookTaskRequestBlock(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_url(request.URL, @"NSURLSession.request:block");

    return g_forwardTaskRequestBlock != NULL
        ? g_forwardTaskRequestBlock(self, _cmd, request, completionHandler)
        : nil;
}

static NSURLSessionUploadTask *hookUploadRequestData(
    id self, SEL _cmd, NSURLRequest *request, NSData *bodyData,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_url(request.URL, @"NSURLSession.uploadRequest:data");
    return g_forwardUploadRequestData != NULL
        ? g_forwardUploadRequestData(self, _cmd, request, bodyData, completionHandler)
        : nil;
}

static NSURLSessionUploadTask *hookUploadRequestFile(
    id self, SEL _cmd, NSURLRequest *request, NSURL *fileURL,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_url(request.URL, @"NSURLSession.uploadRequest:file");
    return g_forwardUploadRequestFile != NULL
        ? g_forwardUploadRequestFile(self, _cmd, request, fileURL, completionHandler)
        : nil;
}

static NSURLSessionUploadTask *hookUploadRequestStream(id self, SEL _cmd, NSURLRequest *request) {
    observe_url(request.URL, @"NSURLSession.uploadRequest:stream");
    return g_forwardUploadRequestStream != NULL
        ? g_forwardUploadRequestStream(self, _cmd, request)
        : nil;
}

static NSURLSessionDownloadTask *hookDownloadRequestBlock(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSURL *, NSURLResponse *, NSError *)
) {
    observe_url(request.URL, @"NSURLSession.downloadRequest:block");
    return g_forwardDownloadRequestBlock != NULL
        ? g_forwardDownloadRequestBlock(self, _cmd, request, completionHandler)
        : nil;
}

static NSURLSessionDownloadTask *hookDownloadURLBlock(
    id self, SEL _cmd, NSURL *url,
    void (^completionHandler)(NSURL *, NSURLResponse *, NSError *)
) {
    observe_url(url, @"NSURLSession.downloadURL:block");
    return g_forwardDownloadURLBlock != NULL
        ? g_forwardDownloadURLBlock(self, _cmd, url, completionHandler)
        : nil;
}

static void install_tracked_session_instance_hooks(NSURLSession *session) {
    if (session == nil) {
        return;
    }

    Class cls = object_getClass(session);
    if (cls == Nil) {
        return;
    }

    if (g_trackedSessionClass == cls) {
        return;
    }

    g_trackedSessionClass = cls;

    NSLog(@"[LLLLOffline][OBSERVE] TRACK SESSION CLASS %@", NSStringFromClass(cls));

    install_concrete_override(cls,
                              @"dataTaskWithURL:",
                              (IMP)hookTaskURL,
                              (IMP *)&g_forwardTaskURL);

    install_concrete_override(cls,
                              @"dataTaskWithURL:completionHandler:",
                              (IMP)hookTaskURLBlock,
                              (IMP *)&g_forwardTaskURLBlock);

    install_concrete_override(cls,
                              @"dataTaskWithRequest:",
                              (IMP)hookTaskRequest,
                              (IMP *)&g_forwardTaskRequest);

    install_concrete_override(cls,
                              @"dataTaskWithRequest:completionHandler:",
                              (IMP)hookTaskRequestBlock,
                              (IMP *)&g_forwardTaskRequestBlock);

    install_concrete_override(cls,
                              @"uploadTaskWithRequest:fromData:completionHandler:",
                              (IMP)hookUploadRequestData,
                              (IMP *)&g_forwardUploadRequestData);

    install_concrete_override(cls,
                              @"uploadTaskWithRequest:fromFile:completionHandler:",
                              (IMP)hookUploadRequestFile,
                              (IMP *)&g_forwardUploadRequestFile);

    install_concrete_override(cls,
                              @"uploadTaskWithStreamedRequest:",
                              (IMP)hookUploadRequestStream,
                              (IMP *)&g_forwardUploadRequestStream);

    install_concrete_override(cls,
                              @"downloadTaskWithRequest:completionHandler:",
                              (IMP)hookDownloadRequestBlock,
                              (IMP *)&g_forwardDownloadRequestBlock);

    install_concrete_override(cls,
                              @"downloadTaskWithURL:completionHandler:",
                              (IMP)hookDownloadURLBlock,
                              (IMP *)&g_forwardDownloadURLBlock);
}

static void install_instance(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *forward
) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName));

    if (method == NULL) {
        NSLog(@"[LLLLOffline][OBSERVE] MISSING instance %@", selectorName);
        return;
    }

    IMP current = method_getImplementation(method);

    if (current == replacement) {
        return;
    }

    if (forward != NULL) {
        *forward = current;
    }

    method_setImplementation(method, replacement);

    NSLog(@"[LLLLOffline][OBSERVE] INSTALLED instance %@ current=%p replacement=%p",
          selectorName, current, replacement);
}

static void install_concrete_override(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *forward
) {
    if (cls == Nil) {
        return;
    }

    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);

    if (method == NULL) {
        NSLog(@"[LLLLOffline][OBSERVE] MISSING concrete %@", selectorName);
        return;
    }

    IMP current = method_getImplementation(method);

    if (current == replacement) {
        return;
    }

    const char *types = method_getTypeEncoding(method);

    if (forward != NULL) {
        *forward = current;
    }

    if (!class_addMethod(cls, selector, replacement, types)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        if (ownMethod != NULL) {
            method_setImplementation(ownMethod, replacement);
        }
    }

    NSLog(@"[LLLLOffline][OBSERVE] OVERRIDE concrete %@ current=%p replacement=%p",
          selectorName, current, replacement);
}

static void install_class(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *forward
) {
    Method method = class_getClassMethod(cls, NSSelectorFromString(selectorName));

    if (method == NULL) {
        NSLog(@"[LLLLOffline][OBSERVE] MISSING class %@", selectorName);
        return;
    }

    IMP current = method_getImplementation(method);

    if (current == replacement) {
        return;
    }

    if (forward != NULL) {
        *forward = current;
    }

    method_setImplementation(method, replacement);

    NSLog(@"[LLLLOffline][OBSERVE] INSTALLED class %@ current=%p replacement=%p",
          selectorName, current, replacement);
}

static void install_all_hooks(void) {
    Class session = NSClassFromString(@"NSURLSession");
    Class request = NSClassFromString(@"NSURLRequest");
    Class mutableRequest = NSClassFromString(@"NSMutableURLRequest");
    Class url = NSClassFromString(@"NSURL");

    if (session != Nil) {
        install_class(session,
                      @"sessionWithConfiguration:",
                      (IMP)hookSessionWithConfig,
                      (IMP *)&g_forwardSessionWithConfig);

        install_class(session,
                      @"sessionWithConfiguration:delegate:delegateQueue:",
                      (IMP)hookSessionWithConfigDelegate,
                      (IMP *)&g_forwardSessionWithConfigDelegate);

        install_instance(session,
                         @"initWithConfiguration:",
                         (IMP)hookSessionInitWithConfig,
                         (IMP *)&g_forwardSessionInitWithConfig);

        install_instance(session,
                         @"initWithConfiguration:delegate:delegateQueue:",
                         (IMP)hookSessionInitWithConfigDelegate,
                         (IMP *)&g_forwardSessionInitWithConfigDelegate);

        NSURLSession *shared = [NSURLSession sharedSession];
        observe_session(shared, @"sharedSession");
    }

    if (request != Nil) {
        install_class(request,
                      @"requestWithURL:",
                      (IMP)hookRequestWithURL,
                      (IMP *)&g_forwardReqWithURL);

        install_instance(request,
                         @"initWithURL:",
                         (IMP)hookRequestInitURL,
                         (IMP *)&g_forwardReqInitURL);

        install_instance(request,
                         @"initWithURL:cachePolicy:timeoutInterval:",
                         (IMP)hookRequestInitURLPolicy,
                         (IMP *)&g_forwardReqInitURLPolicy);
    }

    if (mutableRequest != Nil) {
        install_instance(mutableRequest,
                         @"setURL:",
                         (IMP)hookSetURL,
                         (IMP *)&g_forwardSetURL);
    }

    if (url != Nil) {
        install_class(url,
                      @"URLWithString:",
                      (IMP)hookURLWithString,
                      (IMP *)&g_forwardURLWithString);

        install_class(url,
                      @"URLWithString:relativeToURL:",
                      (IMP)hookURLWithStringRelative,
                      (IMP *)&g_forwardURLWithStringRelative);

        install_class(url,
                      @"URLWithString:encodingInvalidCharacters:",
                      (IMP)hookURLWithStringEncoding,
                      (IMP *)&g_forwardURLWithStringEncoding);
    }

    show_status(@"LLL NET OBSERVER READY", YES);
}

/*
 * Independent raw localhost test. This deliberately does not use
 * NSURLSession, so our observation hooks cannot break the baseline.
 */

static void send_response(int fd, int status, const char *reason, const char *body) {
    size_t bodyLength = strlen(body);

    char response[512];

    int n = snprintf(
        response,
        sizeof(response),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        status,
        reason,
        bodyLength,
        body
    );

    if (n > 0) {
        (void)send(fd, response, (size_t)n, 0);
    }
}

static void *localhost_server_thread(void *unused) {
    (void)unused;

    int serverFD = socket(AF_INET, SOCK_STREAM, 0);
    if (serverFD < 0) {
        return NULL;
    }

    int reuse = 1;
    (void)setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(17891);

    if (bind(serverFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(serverFD);
        return NULL;
    }

    if (listen(serverFD, 8) != 0) {
        close(serverFD);
        return NULL;
    }

    for (;;) {
        int clientFD = accept(serverFD, NULL, NULL);

        if (clientFD < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        char request[2048];
        ssize_t received = recv(clientFD, request, sizeof(request) - 1, 0);

        if (received > 0) {
            request[received] = '\\0';

            if (strncmp(request, "GET /test ", 10) == 0) {
                send_response(
                    clientFD,
                    200,
                    "OK",
                    "{\"offline\":true,\"service\":\"LLLLOffline-iOS-observer-v5\"}"
                );
            } else {
                send_response(
                    clientFD,
                    404,
                    "Not Found",
                    "{\"error\":\"not_found\"}"
                );
            }
        }

        close(clientFD);
    }

    close(serverFD);
    return NULL;
}

static BOOL localhost_self_test(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0) {
        return NO;
    }

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(17891);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return NO;
    }

    const char *request =
        "GET /test HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Connection: close\r\n"
        "\r\n";

    (void)send(fd, request, strlen(request), 0);

    char response[2048];
    ssize_t received = recv(fd, response, sizeof(response) - 1, 0);

    close(fd);

    if (received <= 0) {
        return NO;
    }

    response[received] = '\\0';

    return strstr(response, "200 OK") != NULL &&
           strstr(response, "\"offline\":true") != NULL;
}

static void start_once(void) {
    g_observeLock = [NSObject new];

    pthread_t serverThread;
    if (pthread_create(&serverThread, NULL, localhost_server_thread, NULL) == 0) {
        (void)pthread_detach(serverThread);
    }

    /*
     * ApiHook.dylib is loaded before this dylib in the current IPA.
     * Installing after a short delay means our forwarding pointers normally
     * point at ApiHook's existing swizzled implementations.
     */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        install_all_hooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        install_all_hooks();

        BOOL ok = localhost_self_test();
        NSLog(@"[LLLLOffline] localhost self-test: %@",
              ok ? @"OK" : @"FAIL");

        show_status(ok ? @"LLL LOCALHOST OK" : @"LLL LOCALHOST FAIL", ok);
    });
}

void LLLStartLocalHTTPServer(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_once);
}
