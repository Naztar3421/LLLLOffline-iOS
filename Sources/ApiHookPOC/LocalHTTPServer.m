#import "LocalHTTPServer.h"

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

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24, 48, 300, 48)];
        label.text = status;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont boldSystemFontOfSize:18.0];
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
            window.hidden = YES;
        });
    });
}

static void send_response(int fd, int status, const char *status_text, const char *body) {
    char response[1024];
    const size_t body_length = strlen(body);

    const int n = snprintf(
        response,
        sizeof(response),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        status,
        status_text,
        body_length,
        body
    );

    if (n > 0 && (size_t)n < sizeof(response)) {
        (void)send(fd, response, (size_t)n, 0);
    }
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

    for (;;) {
        const int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        char request[4096];
        const ssize_t received = recv(client_fd, request, sizeof(request) - 1, 0);

        if (received > 0) {
            request[received] = '\0';

            if (strncmp(request, "GET /test ", 10) == 0) {
                send_response(
                    client_fd,
                    200,
                    "OK",
                    "{\"offline\":true,\"service\":\"LLLLOffline-iOS-POC\"}"
                );
            } else {
                send_response(
                    client_fd,
                    404,
                    "Not Found",
                    "{\"error\":\"not_found\"}"
                );
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
