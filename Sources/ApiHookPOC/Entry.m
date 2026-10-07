#import "LocalHTTPServer.h"

__attribute__((constructor))
static void LLLApiHookPOCInit(void) {
    LLLStartLocalHTTPServer();
}
