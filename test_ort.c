#include <stdio.h>
#include <onnxruntime_c_api.h>

int main() {
    printf("Getting ORT API base...\n");
    const OrtApiBase* api_base = OrtGetApiBase();
    if (!api_base) {
        fprintf(stderr, "Failed to get API base\n");
        return 1;
    }
    
    printf("Getting API version 20...\n");
    const OrtApi* api = api_base->GetApi(20);
    if (!api) {
        fprintf(stderr, "Failed to get API\n");
        return 1;
    }
    
    printf("Creating environment...\n");
    OrtEnv* env = NULL;
    OrtStatus* status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "test", &env);
    
    if (status) {
        const char* msg = api->GetErrorMessage(status);
        fprintf(stderr, "CreateEnv failed: %s\n", msg);
        api->ReleaseStatus(status);
        return 1;
    }
    
    printf("SUCCESS: Environment created\n");
    
    if (env) {
        api->ReleaseEnv(env);
    }
    
    return 0;
}
