/*
 * classifier.c - ONNX Runtime C API wrapper implementation
 */

#include "classifier.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ONNX Runtime API */
static const OrtApi* g_ort = NULL;

/* Classifier structure */
struct vidcom_classifier {
    OrtEnv* env;
    OrtSession* session;
    OrtSessionOptions* session_opts;
    OrtMemoryInfo* memory_info;
    
    /* Model info */
    char* input_name;
    char* output_name;
    int64_t input_shape[4];     /* NCHW */
    int64_t output_shape[2];    /* NC */
    
    /* Error handling */
    char error_msg[512];
};

/* ImageNet preprocessing constants (mean/std from torchvision) */
static const float IMAGENET_MEAN[] = {0.485f, 0.456f, 0.406f};
static const float IMAGENET_STD[]  = {0.229f, 0.224f, 0.225f};

/*
 * Initialize ONNX Runtime API (thread-safe, idempotent)
 */
static int init_ort_api(void) {
    if (g_ort == NULL) {
        g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
        if (g_ort == NULL) {
            return -1;
        }
    }
    return 0;
}

/*
 * Set error message
 */
static void set_error(vidcom_classifier_t* c, const char* msg) {
    if (c && msg) {
        strncpy(c->error_msg, msg, sizeof(c->error_msg) - 1);
        c->error_msg[sizeof(c->error_msg) - 1] = '\0';
    }
}

/*
 * Check ORT status and set error
 */
static int check_status(vidcom_classifier_t* c, OrtStatus* status) {
    if (status != NULL) {
        const char* msg = g_ort->GetErrorMessage(status);
        set_error(c, msg);
        g_ort->ReleaseStatus(status);
        return -1;
    }
    return 0;
}

vidcom_classifier_t* vidcom_classifier_create(const vidcom_classifier_config_t* config) {
    if (config == NULL || config->model_path == NULL) {
        return NULL;
    }
    
    if (init_ort_api() != 0) {
        return NULL;
    }
    
    vidcom_classifier_t* c = calloc(1, sizeof(vidcom_classifier_t));
    if (c == NULL) {
        return NULL;
    }
    
    OrtStatus* status = NULL;
    
    /* Create environment */
    status = g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "vidcom", &c->env);
    if (check_status(c, status) != 0) goto cleanup;
    
    /* Create session options */
    status = g_ort->CreateSessionOptions(&c->session_opts);
    if (check_status(c, status) != 0) goto cleanup;
    
    /* Set thread count */
    if (config->num_threads > 0) {
        g_ort->SetIntraOpNumThreads(c->session_opts, config->num_threads);
    }
    
    /* Enable optimization */
    g_ort->SetSessionGraphOptimizationLevel(c->session_opts, ORT_ENABLE_ALL);
    
    /* Add execution provider based on config */
    switch (config->provider) {
        case VIDCOM_EP_CUDA: {
            OrtCUDAProviderOptions cuda_opts;
            memset(&cuda_opts, 0, sizeof(cuda_opts));
            cuda_opts.device_id = config->device_id;
            status = g_ort->SessionOptionsAppendExecutionProvider_CUDA(
                c->session_opts, &cuda_opts);
            if (status != NULL) {
                /* CUDA not available, fall back to CPU */
                fprintf(stderr, "[vidcom] CUDA not available, using CPU\n");
                g_ort->ReleaseStatus(status);
            }
            break;
        }
        case VIDCOM_EP_TENSORRT: {
            OrtTensorRTProviderOptions trt_opts;
            memset(&trt_opts, 0, sizeof(trt_opts));
            trt_opts.device_id = config->device_id;
            status = g_ort->SessionOptionsAppendExecutionProvider_TensorRT(
                c->session_opts, &trt_opts);
            if (status != NULL) {
                /* TensorRT not available, try CUDA */
                fprintf(stderr, "[vidcom] TensorRT not available, trying CUDA\n");
                g_ort->ReleaseStatus(status);
                
                OrtCUDAProviderOptions cuda_opts;
                memset(&cuda_opts, 0, sizeof(cuda_opts));
                cuda_opts.device_id = config->device_id;
                g_ort->SessionOptionsAppendExecutionProvider_CUDA(
                    c->session_opts, &cuda_opts);
            }
            break;
        }
        case VIDCOM_EP_CPU:
        default:
            /* CPU is always available as fallback */
            break;
    }
    
    /* Create session */
    status = g_ort->CreateSession(c->env, config->model_path, 
                                   c->session_opts, &c->session);
    if (check_status(c, status) != 0) goto cleanup;
    
    /* Create memory info */
    status = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, 
                                         &c->memory_info);
    if (check_status(c, status) != 0) goto cleanup;
    
    /* Get input info */
    OrtAllocator* allocator;
    g_ort->GetAllocatorWithDefaultOptions(&allocator);
    
    status = g_ort->SessionGetInputName(c->session, 0, allocator, &c->input_name);
    if (check_status(c, status) != 0) goto cleanup;
    
    status = g_ort->SessionGetOutputName(c->session, 0, allocator, &c->output_name);
    if (check_status(c, status) != 0) goto cleanup;
    
    /* Get input shape */
    OrtTypeInfo* type_info;
    status = g_ort->SessionGetInputTypeInfo(c->session, 0, &type_info);
    if (check_status(c, status) != 0) goto cleanup;
    
    const OrtTensorTypeAndShapeInfo* tensor_info;
    g_ort->CastTypeInfoToTensorInfo(type_info, &tensor_info);
    
    size_t num_dims;
    g_ort->GetDimensionsCount(tensor_info, &num_dims);
    g_ort->GetDimensions(tensor_info, c->input_shape, num_dims);
    g_ort->ReleaseTypeInfo(type_info);
    
    /* Handle dynamic batch size */
    if (c->input_shape[0] <= 0) {
        c->input_shape[0] = 1;
    }
    
    printf("[vidcom] Model loaded: %s\n", config->model_path);
    printf("[vidcom] Input shape: %ldx%ldx%ldx%ld\n", 
           c->input_shape[0], c->input_shape[1], 
           c->input_shape[2], c->input_shape[3]);
    
    return c;
    
cleanup:
    vidcom_classifier_destroy(c);
    return NULL;
}

void vidcom_classifier_destroy(vidcom_classifier_t* c) {
    if (c == NULL) return;
    
    if (c->memory_info) g_ort->ReleaseMemoryInfo(c->memory_info);
    if (c->session) g_ort->ReleaseSession(c->session);
    if (c->session_opts) g_ort->ReleaseSessionOptions(c->session_opts);
    if (c->env) g_ort->ReleaseEnv(c->env);
    
    /* Note: input_name and output_name are freed by allocator */
    
    free(c);
}

/*
 * Preprocess image: resize, normalize, convert to CHW float tensor
 */
static float* preprocess_image(
    const uint8_t* rgb_data,
    int src_width, int src_height,
    int dst_width, int dst_height
) {
    size_t tensor_size = 3 * dst_width * dst_height;
    float* tensor = malloc(tensor_size * sizeof(float));
    if (tensor == NULL) return NULL;
    
    /* Simple bilinear resize + normalize */
    float x_ratio = (float)(src_width - 1) / (dst_width - 1);
    float y_ratio = (float)(src_height - 1) / (dst_height - 1);
    
    for (int y = 0; y < dst_height; y++) {
        for (int x = 0; x < dst_width; x++) {
            /* Source coordinates */
            float src_x = x * x_ratio;
            float src_y = y * y_ratio;
            int x0 = (int)src_x;
            int y0 = (int)src_y;
            int x1 = (x0 + 1 < src_width) ? x0 + 1 : x0;
            int y1 = (y0 + 1 < src_height) ? y0 + 1 : y0;
            float x_frac = src_x - x0;
            float y_frac = src_y - y0;
            
            for (int c = 0; c < 3; c++) {
                /* Bilinear interpolation */
                float v00 = rgb_data[(y0 * src_width + x0) * 3 + c] / 255.0f;
                float v01 = rgb_data[(y0 * src_width + x1) * 3 + c] / 255.0f;
                float v10 = rgb_data[(y1 * src_width + x0) * 3 + c] / 255.0f;
                float v11 = rgb_data[(y1 * src_width + x1) * 3 + c] / 255.0f;
                
                float v0 = v00 * (1 - x_frac) + v01 * x_frac;
                float v1 = v10 * (1 - x_frac) + v11 * x_frac;
                float value = v0 * (1 - y_frac) + v1 * y_frac;
                
                /* ImageNet normalization */
                value = (value - IMAGENET_MEAN[c]) / IMAGENET_STD[c];
                
                /* Store in CHW format */
                tensor[c * dst_height * dst_width + y * dst_width + x] = value;
            }
        }
    }
    
    return tensor;
}

int vidcom_classifier_predict(
    vidcom_classifier_t* c,
    const uint8_t* rgb_data,
    int width, int height,
    vidcom_class_result_t* results,
    int max_results
) {
    if (c == NULL || rgb_data == NULL || results == NULL || max_results <= 0) {
        return -1;
    }
    
    /* Get model input dimensions (NCHW) */
    int model_height = (int)c->input_shape[2];
    int model_width = (int)c->input_shape[3];
    
    /* Preprocess image */
    float* input_tensor = preprocess_image(rgb_data, width, height, 
                                            model_width, model_height);
    if (input_tensor == NULL) {
        set_error(c, "Failed to preprocess image");
        return -1;
    }
    
    /* Create input tensor */
    size_t input_size = 3 * model_height * model_width;
    OrtValue* input_value = NULL;
    OrtStatus* status = g_ort->CreateTensorWithDataAsOrtValue(
        c->memory_info,
        input_tensor, input_size * sizeof(float),
        c->input_shape, 4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_value
    );
    
    if (check_status(c, status) != 0) {
        free(input_tensor);
        return -1;
    }
    
    /* Run inference */
    const char* input_names[] = {c->input_name};
    const char* output_names[] = {c->output_name};
    OrtValue* output_value = NULL;
    
    status = g_ort->Run(c->session, NULL,
                        input_names, (const OrtValue* const*)&input_value, 1,
                        output_names, 1, &output_value);
    
    g_ort->ReleaseValue(input_value);
    free(input_tensor);
    
    if (check_status(c, status) != 0) {
        return -1;
    }
    
    /* Get output */
    float* output_data;
    status = g_ort->GetTensorMutableData(output_value, (void**)&output_data);
    if (check_status(c, status) != 0) {
        g_ort->ReleaseValue(output_value);
        return -1;
    }
    
    /* Get output shape to determine number of classes */
    OrtTensorTypeAndShapeInfo* output_info;
    g_ort->GetTensorTypeAndShape(output_value, &output_info);
    
    size_t num_dims;
    g_ort->GetDimensionsCount(output_info, &num_dims);
    
    int64_t output_shape[2] = {1, 1000};  /* Default */
    g_ort->GetDimensions(output_info, output_shape, num_dims);
    g_ort->ReleaseTensorTypeAndShapeInfo(output_info);
    
    int num_classes = (int)output_shape[num_dims - 1];
    
    /* Apply softmax and find top-k */
    float max_val = output_data[0];
    for (int i = 1; i < num_classes; i++) {
        if (output_data[i] > max_val) max_val = output_data[i];
    }
    
    float sum = 0;
    float* probs = malloc(num_classes * sizeof(float));
    for (int i = 0; i < num_classes; i++) {
        probs[i] = expf(output_data[i] - max_val);
        sum += probs[i];
    }
    for (int i = 0; i < num_classes; i++) {
        probs[i] /= sum;
    }
    
    /* Find top-k results */
    int num_results = (max_results < num_classes) ? max_results : num_classes;
    for (int k = 0; k < num_results; k++) {
        int best_idx = 0;
        float best_prob = -1;
        
        for (int i = 0; i < num_classes; i++) {
            if (probs[i] > best_prob) {
                /* Check not already selected */
                int already = 0;
                for (int j = 0; j < k; j++) {
                    if (results[j].class_id == i) {
                        already = 1;
                        break;
                    }
                }
                if (!already) {
                    best_prob = probs[i];
                    best_idx = i;
                }
            }
        }
        
        results[k].class_id = best_idx;
        results[k].confidence = best_prob;
        results[k].label = NULL;  /* Labels could be loaded from file */
    }
    
    free(probs);
    g_ort->ReleaseValue(output_value);
    
    return num_results;
}

int vidcom_classifier_predict_file(
    vidcom_classifier_t* c,
    const char* image_path,
    vidcom_class_result_t* results,
    int max_results
) {
    /* TODO: Implement using stb_image or similar */
    (void)c;
    (void)image_path;
    (void)results;
    (void)max_results;
    set_error(c, "Not implemented: use vidcom_classifier_predict with raw RGB data");
    return -1;
}

int vidcom_classifier_extract_features(
    vidcom_classifier_t* c,
    const uint8_t* rgb_data,
    int width, int height,
    vidcom_features_t* features
) {
    /* For feature extraction, we need to modify the model or use
     * intermediate layer output. For now, use classification output
     * as a simple embedding (not ideal but works for proof of concept) */
    
    /* TODO: Implement proper feature extraction from penultimate layer */
    (void)c;
    (void)rgb_data;
    (void)width;
    (void)height;
    (void)features;
    set_error(c, "Feature extraction not yet implemented");
    return -1;
}

void vidcom_features_free(vidcom_features_t* features) {
    if (features && features->data) {
        free(features->data);
        features->data = NULL;
        features->length = 0;
    }
}

float vidcom_features_similarity(
    const vidcom_features_t* a,
    const vidcom_features_t* b
) {
    if (a == NULL || b == NULL || a->length != b->length || a->length == 0) {
        return NAN;
    }
    
    /* Cosine similarity */
    double dot = 0, norm_a = 0, norm_b = 0;
    for (size_t i = 0; i < a->length; i++) {
        dot += a->data[i] * b->data[i];
        norm_a += a->data[i] * a->data[i];
        norm_b += b->data[i] * b->data[i];
    }
    
    if (norm_a == 0 || norm_b == 0) {
        return 0;
    }
    
    return (float)(dot / (sqrt(norm_a) * sqrt(norm_b)));
}

const char* vidcom_classifier_get_error(vidcom_classifier_t* c) {
    return (c != NULL) ? c->error_msg : "Invalid classifier";
}
