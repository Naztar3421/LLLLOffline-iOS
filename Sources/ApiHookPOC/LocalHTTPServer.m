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

static unsigned long g_apiCount = 0;
static unsigned long g_hookInstallCount = 0;
static NSString *g_lastAPIURL = nil;
static NSObject *g_observeLock = nil;

typedef NSURLSessionDataTask *(*LLLDataTaskURLFn)(id, SEL, NSURL *);
typedef NSURLSessionDataTask *(*LLLDataTaskURLBlockFn)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*LLLDataTaskRequestFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*LLLDataTaskRequestBlockFn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef void (*LLLSetURLFn)(id, SEL, NSURL *);
typedef NSURL *(*LLLURLWithStringFn)(id, SEL, NSString *);
typedef NSURL *(*LLLURLWithStringRelativeFn)(id, SEL, NSString *, NSURL *);
typedef NSURL *(*LLLURLWithStringEncodingFn)(id, SEL, NSString *, BOOL);

static LLLDataTaskURLFn g_origDataTaskURL = NULL;
static LLLDataTaskURLBlockFn g_origDataTaskURLBlock = NULL;
static LLLDataTaskRequestFn g_origDataTaskRequest = NULL;
static LLLDataTaskRequestBlockFn g_origDataTaskRequestBlock = NULL;
static LLLSetURLFn g_origSetURL = NULL;
static LLLURLWithStringFn g_origURLWithString = NULL;
static LLLURLWithStringRelativeFn g_origURLWithStringRelative = NULL;
static LLLURLWithStringEncodingFn g_origURLWithStringEncoding = NULL;

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

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12, 44, 350, 64)];
        label.text = status ?: @"";
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 2;
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
        g_lastAPIURL = url.absoluteString;
    }

    NSLog(@"[LLLLOffline][OBSERVE] %@ %@", source ?: @"URL", url.absoluteString);
    show_status([NSString stringWithFormat:@"LLL API #%lu\n%@", count, path], YES);
}

static void install_instance_method_if_needed(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *originalOut
) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);

    if (method == NULL) {
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
    @synchronized (g_observeLock) {
        g_hookInstallCount += 1;
    }

    NSLog(@"[LLLLOffline][OBSERVE] rehook instance %@ current=%p replacement=%p",
          selectorName, current, replacement);
}

static void install_class_method_if_needed(
    Class cls,
    NSString *selectorName,
    IMP replacement,
    IMP *originalOut
) {
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getClassMethod(cls, selector);

    if (method == NULL) {
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
    __atomic_add_fetch(&g_hookInstallCount, 1, __ATOMIC_RELAXED);

    NSLog(@"[LLLLOffline][OBSERVE] rehook class %@ current=%p replacement=%p",
          selectorName, current, replacement);
}

static NSURLSessionDataTask *hook_dataTaskWithURL(id self, SEL _cmd, NSURL *url) {
    observe_api_url(url, @"dataTaskWithURL");
    if (g_origDataTaskURL != NULL) {
        return g_origDataTaskURL(self, _cmd, url);
    }
    return nil;
}

static NSURLSessionDataTask *hook_dataTaskWithURL_block(
    id self,
    SEL _cmd,
    NSURL *url,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_api_url(url, @"dataTaskWithURL:block");
    if (g_origDataTaskURLBlock != NULL) {
        return g_origDataTaskURLBlock(self, _cmd, url, completionHandler);
    }
    return nil;
}

static NSURLSessionDataTask *hook_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    observe_api_url(request.URL, @"dataTaskWithRequest");
    if (g_origDataTaskRequest != NULL) {
        return g_origDataTaskRequest(self, _cmd, request);
    }
    return nil;
}

static NSURLSessionDataTask *hook_dataTaskWithRequest_block(
    id self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)
) {
    observe_api_url(request.URL, @"dataTaskWithRequest:block");
    if (g_origDataTaskRequestBlock != NULL) {
        return g_origDataTaskRequestBlock(self, _cmd, request, completionHandler);
    }
    return nil;
}

static void hook_setURL(id self, SEL _cmd, NSURL *url) {
    observe_api_url(url, @"NSMutableURLRequest.setURL");
    if (g_origSetURL != NULL) {
        g_origSetURL(self, _cmd, url);
    }
}

static NSURL *hook_URLWithString(id self, SEL _cmd, NSString *string) {
    NSURL *url = g_origURLWithString != NULL
        ? g_origURLWithString(self, _cmd, string)
        : nil;

    observe_api_url(url, @"NSURL.URLWithString");
    return url;
}

static NSURL *hook_URLWithStringRelative(id self, SEL _cmd, NSString *string, NSURL *baseURL) {
    NSURL *url = g_origURLWithStringRelative != NULL
        ? g_origURLWithStringRelative(self, _cmd, string, baseURL)
        : nil;

    observe_api_url(url, @"NSURL.URLWithString:relative");
    return url;
}

static NSURL *hook_URLWithStringEncoding(id self, SEL _cmd, NSString *string, BOOL encodingInvalidCharacters) {
    NSURL *url = g_origURLWithStringEncoding != NULL
        ? g_origURLWithStringEncoding(self, _cmd, string, encodingInvalidCharacters)
        : nil;

    observe_api_url(url, @"NSURL.URLWithString:encoding");
    return url;
}

static void install_all_observer_hooks(void) {
    Class session = NSClassFromString(@"NSURLSession");
    Class request = NSClassFromString(@"NSMutableURLRequest");
    Class url = NSClassFromString(@"NSURL");

    if (session != Nil) {
        install_instance_method_if_needed(session, @"dataTaskWithURL:", (IMP)hook_dataTaskWithURL, (IMP *)&g_origDataTaskURL);
        install_instance_method_if_needed(session, @"dataTaskWithURL:completionHandler:", (IMP)hook_dataTaskWithURL_block, (IMP *)&g_origDataTaskURLBlock);
        install_instance_method_if_needed(session, @"dataTaskWithRequest:", (IMP)hook_dataTaskWithRequest, (IMP *)&g_origDataTaskRequest);
        install_instance_method_if_needed(session, @"dataTaskWithRequest:completionHandler:", (IMP)hook_dataTaskWithRequest_block, (IMP *)&g_origDataTaskRequestBlock);
    }

    if (request != Nil) {
        install_instance_method_if_needed(request, @"setURL:", (IMP)hook_setURL, (IMP *)&g_origSetURL);
    }

    if (url != Nil) {
        install_class_method_if_needed(url, @"URLWithString:", (IMP)hook_URLWithString, (IMP *)&g_origURLWithString);
        install_class_method_if_needed(url, @"URLWithString:relativeToURL:", (IMP)hook_URLWithStringRelative, (IMP *)&g_origURLWithStringRelative);
        install_class_method_if_needed(url, @"URLWithString:encodingInvalidCharacters:", (IMP)hook_URLWithStringEncoding, (IMP *)&g_origURLWithStringEncoding);
    }

    unsigned long installs = 0;
    @synchronized (g_observeLock) {
        installs = g_hookInstallCount;
    }
    NSLog(@"[LLLLOffline][OBSERVE] hook sweep complete installs=%lu", installs);
}

static void send_test_response(int fd) {
    const char *body = "{\"offline\":true,\"service\":\"LLLLOffline-iOS-OBSERVER\"}";
    char response[512];

    int n = snprintf(
        response,
        sizeof(response),
        "HTTP/1.1 200 OK\\r\\n"
        "Content-Type: application/json; charset=utf-8\\r\\n"
        "Content-Length: %zu\\r\\n"
        "Connection: close\\r\\n"
        "\\r\\n"
        "%s",
        strlen(body),
        body
    );

    if (n > 0) {
        (void)send(fd, response, (size_t)n, 0);
    }
}

static void *server_thread(void *unused) {
    (void)unused;

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
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

    if (bind(server_fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(server_fd, 8) != 0) {
        close(server_fd);
        return NULL;
    }

    NSLog(@"[LLLLOffline][OBSERVE] localhost server listening on 127.0.0.1:17891");

    for (;;) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        char request[2048];
        ssize_t received = recv(client_fd, request, sizeof(request) - 1, 0);

        if (received > 0) {
            request[received] = '\\0';

            if (strncmp(request, "GET /test ", 10) == 0) {
                send_test_response(client_fd);
            } else {
                const char *body = "{\"error\":\"not_found\"}";
                char response[512];
                int n = snprintf(
                    response,
                    sizeof(response),
                    "HTTP/1.1 404 Not Found\\r\\n"
                    "Content-Type: application/json; charset=utf-8\\r\\n"
                    "Content-Length: %zu\\r\\n"
                    "Connection: close\\r\\n"
                    "\\r\\n"
                    "%s",
                    strlen(body),
                    body
                );
                if (n > 0) {
                    (void)send(client_fd, response, (size_t)n, 0);
                }
            }
        }

        close(client_fd);
    }

    close(server_fd);
    return NULL;
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
    g_observeLock = [NSObject new];

    pthread_t thread;
    if (pthread_create(&thread, NULL, server_thread, NULL) == 0) {
        (void)pthread_detach(thread);
    }

    install_all_observer_hooks();
    show_status(@"LLL NET HOOK READY", YES);

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);

    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);

    dispatch_source_set_event_handler(timer, ^{
        install_all_observer_hooks();
    });

    dispatch_resume(timer);

    NSLog(@"[LLLLOffline][OBSERVE] API observer started");
}


void LLLStartLocalHTTPServer(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_server_once);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        run_self_test();
    });
}
