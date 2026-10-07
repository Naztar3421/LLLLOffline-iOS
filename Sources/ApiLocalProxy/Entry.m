#import "ApiLocalProxy.h"

__attribute__((constructor))
static void LLLApiLocalProxyInit(void) {
    LLLStartApiLocalProxy();
}
