#import "LocalHTTPServer.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

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
            if (errno == EINTR) {
                continue;
            }
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

static void start_server_once(void) {
    pthread_t thread;

    if (pthread_create(&thread, NULL, server_thread, NULL) == 0) {
        (void)pthread_detach(thread);
    }
}

void LLLStartLocalHTTPServer(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    (void)pthread_once(&once, start_server_once);
}
