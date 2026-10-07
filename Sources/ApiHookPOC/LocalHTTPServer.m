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

static NSString * const kOfficialHost = @"api.link-like-lovelive.app";
static NSString * const kPrivateHost = @"api-alfa-l4.hasu-link.club";

static NSObject *g_observeLock = nil;
static unsigned long g_apiCount = 0;

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

            UIViewController *controller = [UIViewController new];
            controller.view.backgroundColor = UIColor.clearColor;
            window.rootViewController = controller;
        }

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 44, 355, 70)];
        label.text = status ?: @"";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 3;
        label.font = [UIFont boldSystemFontOfSize:14.0];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = success
            ? [UIColor colorWithRed:0.1 green:0.6 blue:0.2 alpha:0.92]
            : [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:0.92];
        label.layer.cornerRadius = 10.0;
        label.clipsToBounds = YES;

        [window.rootViewController.view addSubview:label];
        window.hidden = NO;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [label removeFromSuperview];
            if (window.rootViewController.view.subviews.count == 0) {
                window.hidden = YES;
            }
        });
    });
}

static BOOL is_api_host(NSString *host) {
    if (host.length == 0) {
        return NO;
    }

    NSString *lower = host.lowercaseString;
    return [lower isEqualToString:kOfficialHost] ||
           [lower isEqualToString:kPrivateHost];
}

static NSString *display_path_for_url(NSURL *url) {
    if (url == nil) {
        return @"<nil>";
    }

    NSString *path = url.path.length > 0 ? url.path : @"/";
    if (url.query.length > 0) {
        path = [path stringByAppendingFormat:@"?%@", url.query];
    }

    return path;
}

static void observe_api_url(NSURL *url, NSString *source) {
    if (url == nil || !is_api_host(url.host)) {
        return;
    }

    unsigned long count = 0;
    NSString *path = display_path_for_url(url);

    @synchronized (g_observeLock) {
        g_apiCount += 1;
        count = g_apiCount;
    }

    NSLog(@"[LLLLOffline][OBSERVE] API #%lu %@ %@",
          count,
          source ?: @"URL",
          url.absoluteString);

    show_status([NSString stringWithFormat:@"LLL API #%lu\n%@", count, path], YES);
}

static void install_instance_hook_once(Class cls,
                                        NSString *selectorName,
                                        IMP replacement,
                                        IMP *originalOut) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        NSLog(@"[LLLLOffline][OBSERVE] missing %@", selectorName);
        return;
    }

    IMP current = method_getImplementation(method);
    if (current == replacement) {
        return;
    }

    if (originalOut != NULL) {
        *originalOut = current;
    }

    method_setImplementation(method, replacement);

    NSLog(@"[LLLLOffline][OBSERVE] installed %@ current=%p replacement=%p",
          selectorName,
          current,
          replacement);
}

static NSURLSessionDataTask *hook_dataTaskWithURL(id self, SEL _cmd, NSURL *url) {
    observe_api_url(url, @"dataTaskWithURL");

    return g_origDataTaskURL != NULL
        ? g_origDataTaskURL(self, _cmd, url)
        : nil;
}

static NSURLSessionDataTask *hook_dataTaskWithURL_block(
    id self,
    SEL _cmd,
    NSURL *url,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_api_url(url, @"dataTaskWithURL:block");

    return g_origDataTaskURLBlock != NULL
        ? g_origDataTaskURLBlock(self, _cmd, url, completionHandler)
        : nil;
}

static NSURLSessionDataTask *hook_dataTaskWithRequest(id self,
                                                      SEL _cmd,
                                                      NSURLRequest *request) {
    observe_api_url(request.URL, @"dataTaskWithRequest");

    return g_origDataTaskRequest != NULL
        ? g_origDataTaskRequest(self, _cmd, request)
        : nil;
}

static NSURLSessionDataTask *hook_dataTaskWithRequest_block(
    id self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_api_url(request.URL, @"dataTaskWithRequest:block");

    return g_origDataTaskRequestBlock != NULL
        ? g_origDataTaskRequestBlock(self, _cmd, request, completionHandler)
        : nil;
}

static void install_session_hooks(void) {
    Class session = NSClassFromString(@"NSURLSession");
    if (session == Nil) {
        NSLog(@"[LLLLOffline][OBSERVE] NSURLSession class missing");
        return;
    }

    install_instance_hook_once(session,
                               @"dataTaskWithURL:",
                               (IMP)hook_dataTaskWithURL,
                               (IMP *)&g_origDataTaskURL);

    install_instance_hook_once(session,
                               @"dataTaskWithURL:completionHandler:",
                               (IMP)hook_dataTaskWithURL_block,
                               (IMP *)&g_origDataTaskURLBlock);

    install_instance_hook_once(session,
                               @"dataTaskWithRequest:",
                               (IMP)hook_dataTaskWithRequest,
                               (IMP *)&g_origDataTaskRequest);

    install_instance_hook_once(session,
                               @"dataTaskWithRequest:completionHandler:",
                               (IMP)hook_dataTaskWithRequest_block,
                               (IMP *)&g_origDataTaskRequestBlock);

    show_status(@"LLL NET OBSERVER READY", YES);
}

static void send_simple_response(int fd,
                                 int status,
                                 const char *reason,
                                 const char *body) {
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
        NSLog(@"[LLLLOffline][OBSERVE] server socket failed: %s", strerror(errno));
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
        NSLog(@"[LLLLOffline][OBSERVE] bind failed: %s", strerror(errno));
        close(serverFD);
        return NULL;
    }

    if (listen(serverFD, 8) != 0) {
        NSLog(@"[LLLLOffline][OBSERVE] listen failed: %s", strerror(errno));
        close(serverFD);
        return NULL;
    }

    NSLog(@"[LLLLOffline][OBSERVE] localhost server listening");

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
                send_simple_response(
                    clientFD,
                    200,
                    "OK",
                    "{\"offline\":true,\"service\":\"LLLLOffline-iOS-observer\"}"
                );
            } else {
                send_simple_response(
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

static BOOL localhost_raw_self_test(void) {
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

static void run_self_test(void) {
    BOOL ok = localhost_raw_self_test();

    NSLog(@"[LLLLOffline] localhost raw self-test: %@",
          ok ? @"OK" : @"FAIL");

    show_status(ok ? @"LLL LOCALHOST OK" : @"LLL LOCALHOST FAIL", ok);
}

static void start_once(void) {
    g_observeLock = [NSObject new];

    pthread_t serverThread;
    if (pthread_create(&serverThread, NULL, localhost_server_thread, NULL) == 0) {
        (void)pthread_detach(serverThread);
    } else {
        NSLog(@"[LLLLOffline][OBSERVE] pthread_create failed");
    }

    /*
     * Give the already-loaded private ApiHook a chance to finish its
     * constructor, then install our observer over the same NSURLSession
     * methods. We do this only a small number of times; we never replace
     * our saved original with our own replacement.
     */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        install_session_hooks();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        install_session_hooks();
        run_self_test();
    });

    NSLog(@"[LLLLOffline][OBSERVE] clean observer started");
}

void LLLStartLocalHTTPServer(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_once);
}
