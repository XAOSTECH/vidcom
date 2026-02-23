/*
 * highlight_detector.c - YOLO-based gaming highlight detection implementation
 * 
 * Uses ONNX Runtime C API with YOLOv8/v11 models for real-time
 * detection of gaming highlights (kills, headshots, etc.)
 */

#include "highlight_detector.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ONNX Runtime API (shared with classifier.c) */
static const OrtApi* g_ort = NULL;

/* Class names for highlight types */
static const char* HIGHLIGHT_TYPE_NAMES[] = {
    "NONE",
    "KILL",
    "HEADSHOT", 
    "ASSIST",
    "DOWN",
    "MULTI_KILL",
    "CLUTCH",
    "ACTION"
};

/* Game-specific ROIs (normalized coordinates) */
static const vidcom_roi_t GAME_ROIS[] = {
    /* VIDCOM_GAME_GENERIC */   {0.0f, 0.0f, 1.0f, 1.0f},
    /* VIDCOM_GAME_FORTNITE */  {0.35f, 0.4f, 0.3f, 0.2f},    /* Center kill feed */
    /* VIDCOM_GAME_VALORANT */  {0.03f, 0.74f, 0.07f, 0.06f}, /* Bottom-left kill indicator */
    /* VIDCOM_GAME_CSGO2 */     {0.0f, 0.0f, 0.2f, 0.3f},     /* Top-right killfeed */
    /* VIDCOM_GAME_OVERWATCH */ {0.35f, 0.4f, 0.3f, 0.2f},    /* Center elimination */
    /* VIDCOM_GAME_APEX */      {0.0f, 0.7f, 0.25f, 0.2f}     /* Bottom-left kill feed */
};

/* Detector structure */
struct vidcom_highlight_detector {
    OrtEnv* env;
    OrtSession* session;
    OrtSessionOptions* session_opts;
    OrtMemoryInfo* memory_info;
    
    /* Model info */
    char* input_name;
    char* output_name;
    int64_t input_shape[4];     /* NCHW: 1, 3, H, W */
    int input_height;
    int input_width;
    int num_classes;
    
    /* Configuration */
    vidcom_detector_config_t config;
    vidcom_roi_t active_roi;
    
    /* Error handling */
    char error_msg[512];
};

/* Initialize ONNX Runtime API */
static int init_ort_api(void) {
    if (g_ort == NULL) {
        g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
        if (g_ort == NULL) {
            return -1;
        }
    }
    return 0;
}

static void set_error(vidcom_highlight_detector_t* d, const char* msg) {
    if (d && msg) {
        strncpy(d->error_msg, msg, sizeof(d->error_msg) - 1);
        d->error_msg[sizeof(d->error_msg) - 1] = '\0';
    }
}

static int check_status(vidcom_highlight_detector_t* d, OrtStatus* status) {
    if (status != NULL) {
        const char* msg = g_ort->GetErrorMessage(status);
        set_error(d, msg);
        g_ort->ReleaseStatus(status);
        return -1;
    }
    return 0;
}

/* YOLO preprocessing: resize, normalize, convert to CHW float tensor */
static float* preprocess_yolo(
    const uint8_t* rgb_data,
    int src_width, int src_height,
    const vidcom_roi_t* roi,
    int dst_width, int dst_height,
    float* scale_x, float* scale_y,
    int* offset_x, int* offset_y
) {
    size_t tensor_size = 3 * dst_width * dst_height;
    float* tensor = calloc(tensor_size, sizeof(float));
    if (tensor == NULL) return NULL;
    
    /* Calculate ROI in pixels */
    int roi_x = (int)(roi->x * src_width);
    int roi_y = (int)(roi->y * src_height);
    int roi_w = (int)(roi->width * src_width);
    int roi_h = (int)(roi->height * src_height);
    
    /* Clamp to image bounds */
    if (roi_x < 0) roi_x = 0;
    if (roi_y < 0) roi_y = 0;
    if (roi_x + roi_w > src_width) roi_w = src_width - roi_x;
    if (roi_y + roi_h > src_height) roi_h = src_height - roi_y;
    
    /* Letterbox scaling (preserve aspect ratio) */
    float scale = fminf((float)dst_width / roi_w, (float)dst_height / roi_h);
    int new_w = (int)(roi_w * scale);
    int new_h = (int)(roi_h * scale);
    int pad_x = (dst_width - new_w) / 2;
    int pad_y = (dst_height - new_h) / 2;
    
    *scale_x = scale;
    *scale_y = scale;
    *offset_x = pad_x - (int)(roi_x * scale);
    *offset_y = pad_y - (int)(roi_y * scale);
    
    /* Bilinear resize + normalize (YOLO uses 0-1 range) */
    float x_ratio = (float)(roi_w - 1) / (new_w - 1);
    float y_ratio = (float)(roi_h - 1) / (new_h - 1);
    
    for (int y = 0; y < new_h; y++) {
        for (int x = 0; x < new_w; x++) {
            /* Source coordinates (in ROI) */
            float src_x = x * x_ratio;
            float src_y = y * y_ratio;
            int x0 = (int)src_x;
            int y0 = (int)src_y;
            int x1 = (x0 + 1 < roi_w) ? x0 + 1 : x0;
            int y1 = (y0 + 1 < roi_h) ? y0 + 1 : y0;
            float x_frac = src_x - x0;
            float y_frac = src_y - y0;
            
            /* Destination pixel (with padding) */
            int dst_x = x + pad_x;
            int dst_y = y + pad_y;
            
            for (int c = 0; c < 3; c++) {
                /* Bilinear interpolation from source ROI */
                int s00 = ((roi_y + y0) * src_width + (roi_x + x0)) * 3 + c;
                int s01 = ((roi_y + y0) * src_width + (roi_x + x1)) * 3 + c;
                int s10 = ((roi_y + y1) * src_width + (roi_x + x0)) * 3 + c;
                int s11 = ((roi_y + y1) * src_width + (roi_x + x1)) * 3 + c;
                
                float v00 = rgb_data[s00] / 255.0f;
                float v01 = rgb_data[s01] / 255.0f;
                float v10 = rgb_data[s10] / 255.0f;
                float v11 = rgb_data[s11] / 255.0f;
                
                float v0 = v00 * (1 - x_frac) + v01 * x_frac;
                float v1 = v10 * (1 - x_frac) + v11 * x_frac;
                float value = v0 * (1 - y_frac) + v1 * y_frac;
                
                /* Store in CHW format (YOLO input) */
                tensor[c * dst_height * dst_width + dst_y * dst_width + dst_x] = value;
            }
        }
    }
    
    return tensor;
}

/* Non-Maximum Suppression */
static float iou(float* box1, float* box2) {
    float x1 = fmaxf(box1[0], box2[0]);
    float y1 = fmaxf(box1[1], box2[1]);
    float x2 = fminf(box1[0] + box1[2], box2[0] + box2[2]);
    float y2 = fminf(box1[1] + box1[3], box2[1] + box2[3]);
    
    float inter_area = fmaxf(0, x2 - x1) * fmaxf(0, y2 - y1);
    float box1_area = box1[2] * box1[3];
    float box2_area = box2[2] * box2[3];
    float union_area = box1_area + box2_area - inter_area;
    
    return (union_area > 0) ? inter_area / union_area : 0;
}

/* Comparator for sorting detections by confidence (descending) */
static int compare_detections(const void* a, const void* b) {
    const vidcom_detection_t* da = (const vidcom_detection_t*)a;
    const vidcom_detection_t* db = (const vidcom_detection_t*)b;
    if (db->confidence > da->confidence) return 1;
    if (db->confidence < da->confidence) return -1;
    return 0;
}

vidcom_highlight_detector_t* vidcom_detector_create(const vidcom_detector_config_t* config) {
    if (config == NULL || config->model_path == NULL) {
        fprintf(stderr, "[DEBUG] Config or model_path is NULL\n");
        return NULL;
    }
    
    fprintf(stderr, "[DEBUG] Initializing ORT API...\n");
    if (init_ort_api() != 0) {
        fprintf(stderr, "[DEBUG] Failed to initialize ORT API\n");
        return NULL;
    }
    
    fprintf(stderr, "[DEBUG] Allocating detector structure...\n");
    vidcom_highlight_detector_t* d = calloc(1, sizeof(vidcom_highlight_detector_t));
    if (d == NULL) {
        fprintf(stderr, "[DEBUG] Failed to allocate detector\n");
        return NULL;
    }
    
    /* Store configuration */
    d->config = *config;
    
    /* Set active ROI */
    fprintf(stderr, "[DEBUG] Game type: %d, VIDCOM_GAME_COUNT: %d\n", config->game, VIDCOM_GAME_COUNT);
    if (config->custom_roi != NULL) {
        fprintf(stderr, "[DEBUG] Using custom ROI\n");
        d->active_roi = *config->custom_roi;
    } else if (config->game < VIDCOM_GAME_COUNT) {
        fprintf(stderr, "[DEBUG] Using game ROI for game type %d\n", config->game);
        d->active_roi = GAME_ROIS[config->game];
        fprintf(stderr, "[DEBUG] ROI: x=%.2f, y=%.2f, w=%.2f, h=%.2f\n", 
                d->active_roi.x, d->active_roi.y, d->active_roi.width, d->active_roi.height);
    } else {
        fprintf(stderr, "[DEBUG] Using generic ROI\n");
        d->active_roi = GAME_ROIS[VIDCOM_GAME_GENERIC];
    }
    
    OrtStatus* status = NULL;
    
    /* Create environment */
    fprintf(stderr, "[DEBUG] Creating ORT environment...\n");
    fprintf(stderr, "[DEBUG] g_ort pointer: %p\n", (void*)g_ort);
    fprintf(stderr, "[DEBUG] g_ort->CreateEnv pointer: %p\n", (void*)g_ort->CreateEnv);
    fprintf(stderr, "[DEBUG] About to call CreateEnv...\n");
    fflush(stderr);
    status = g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "vidcom_detector", &d->env);
    fprintf(stderr, "[DEBUG] CreateEnv returned\n");
    if (check_status(d, status) != 0) goto cleanup;
    
    /* Create session options */
    fprintf(stderr, "[DEBUG] Creating session options...\n");
    status = g_ort->CreateSessionOptions(&d->session_opts);
    fprintf(stderr, "[DEBUG] Session options created\n");
    if (check_status(d, status) != 0) goto cleanup;
    
    /* Enable optimization */
    fprintf(stderr, "[DEBUG] Setting graph optimization...\n");
    g_ort->SetSessionGraphOptimizationLevel(d->session_opts, ORT_ENABLE_ALL);
    fprintf(stderr, "[DEBUG] Graph optimization set\n");
    
    /* Add CUDA execution provider if requested */
    if (config->use_gpu) {
        fprintf(stderr, "[DEBUG] Adding CUDA provider...\n");
        OrtCUDAProviderOptions cuda_opts;
        memset(&cuda_opts, 0, sizeof(cuda_opts));
        cuda_opts.device_id = config->device_id;
        status = g_ort->SessionOptionsAppendExecutionProvider_CUDA(
            d->session_opts, &cuda_opts);
        if (status != NULL) {
            fprintf(stderr, "[vidcom] CUDA not available for detector, using CPU\n");
            g_ort->ReleaseStatus(status);
        } else {
            fprintf(stderr, "[DEBUG] CUDA provider added\n");
        }
    }
    
    /* Create session */
    fprintf(stderr, "[DEBUG] Creating session with model: %s\n", config->model_path);
    status = g_ort->CreateSession(d->env, config->model_path, 
                                   d->session_opts, &d->session);
    fprintf(stderr, "[DEBUG] Session created\n");
    if (check_status(d, status) != 0) goto cleanup;
    
    /* Create memory info */
    fprintf(stderr, "[DEBUG] Creating CPU memory info...\n");
    status = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, 
                                         &d->memory_info);
    fprintf(stderr, "[DEBUG] CPU memory info created\n");
    if (check_status(d, status) != 0) goto cleanup;
    
    /* Get input info */
    OrtAllocator* allocator;
    status = g_ort->GetAllocatorWithDefaultOptions(&allocator);
    if (check_status(d, status) != 0) goto cleanup;
    
    status = g_ort->SessionGetInputName(d->session, 0, allocator, &d->input_name);
    if (check_status(d, status) != 0) goto cleanup;
    
    OrtTypeInfo* input_type_info;
    status = g_ort->SessionGetInputTypeInfo(d->session, 0, &input_type_info);
    if (check_status(d, status) != 0) goto cleanup;
    
    const OrtTensorTypeAndShapeInfo* input_tensor_info;
    status = g_ort->CastTypeInfoToTensorInfo(input_type_info, &input_tensor_info);
    if (check_status(d, status) != 0) {
        g_ort->ReleaseTypeInfo(input_type_info);
        goto cleanup;
    }
    
    size_t num_dims;
    g_ort->GetDimensionsCount(input_tensor_info, &num_dims);
    g_ort->GetDimensions(input_tensor_info, d->input_shape, num_dims);
    g_ort->ReleaseTypeInfo(input_type_info);
    
    /* YOLO input is NCHW */
    d->input_height = (d->input_shape[2] > 0) ? (int)d->input_shape[2] : 640;
    d->input_width = (d->input_shape[3] > 0) ? (int)d->input_shape[3] : 640;
    d->input_shape[0] = 1;  /* Batch size */
    d->input_shape[1] = 3;  /* Channels */
    d->input_shape[2] = d->input_height;
    d->input_shape[3] = d->input_width;
    
    /* Get output info */
    status = g_ort->SessionGetOutputName(d->session, 0, allocator, &d->output_name);
    if (check_status(d, status) != 0) goto cleanup;
    
    /* Determine number of classes from output shape */
    OrtTypeInfo* output_type_info;
    status = g_ort->SessionGetOutputTypeInfo(d->session, 0, &output_type_info);
    if (check_status(d, status) != 0) goto cleanup;
    
    const OrtTensorTypeAndShapeInfo* output_tensor_info;
    status = g_ort->CastTypeInfoToTensorInfo(output_type_info, &output_tensor_info);
    if (status == NULL) {
        int64_t output_shape[4];
        size_t out_dims;
        g_ort->GetDimensionsCount(output_tensor_info, &out_dims);
        g_ort->GetDimensions(output_tensor_info, output_shape, out_dims);
        
        /* YOLOv8 output: [1, num_classes+4, num_detections] */
        if (out_dims >= 2) {
            d->num_classes = (int)(output_shape[1] - 4);
            if (d->num_classes < 1) d->num_classes = VIDCOM_HIGHLIGHT_COUNT - 1;
        }
    }
    g_ort->ReleaseTypeInfo(output_type_info);
    
    printf("[vidcom] Highlight detector loaded: %s\n", config->model_path);
    printf("[vidcom]   Input: %dx%d, Classes: %d, GPU: %s\n",
           d->input_width, d->input_height, d->num_classes,
           config->use_gpu ? "yes" : "no");
    
    return d;
    
cleanup:
    vidcom_detector_destroy(d);
    return NULL;
}

void vidcom_detector_destroy(vidcom_highlight_detector_t* d) {
    if (d == NULL) return;
    
    if (d->session) g_ort->ReleaseSession(d->session);
    if (d->session_opts) g_ort->ReleaseSessionOptions(d->session_opts);
    if (d->memory_info) g_ort->ReleaseMemoryInfo(d->memory_info);
    if (d->env) g_ort->ReleaseEnv(d->env);
    
    free(d);
}

int vidcom_detector_detect(
    vidcom_highlight_detector_t* d,
    const uint8_t* rgb_data,
    int width, int height,
    double timestamp,
    int frame_number,
    vidcom_detection_t* detections,
    int max_detections
) {
    if (d == NULL || rgb_data == NULL || detections == NULL || max_detections <= 0) {
        return -1;
    }
    
    /* Preprocess image (crop ROI, resize, normalize) */
    float scale_x, scale_y;
    int offset_x, offset_y;
    float* input_tensor = preprocess_yolo(
        rgb_data, width, height,
        &d->active_roi,
        d->input_width, d->input_height,
        &scale_x, &scale_y, &offset_x, &offset_y
    );
    
    if (input_tensor == NULL) {
        set_error(d, "Failed to preprocess image");
        return -1;
    }
    
    /* Create input tensor */
    size_t input_size = 3 * d->input_height * d->input_width;
    OrtValue* input_value = NULL;
    OrtStatus* status = g_ort->CreateTensorWithDataAsOrtValue(
        d->memory_info,
        input_tensor, input_size * sizeof(float),
        d->input_shape, 4,
        ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_value
    );
    
    if (check_status(d, status) != 0) {
        free(input_tensor);
        return -1;
    }
    
    /* Run inference */
    const char* input_names[] = {d->input_name};
    const char* output_names[] = {d->output_name};
    OrtValue* output_value = NULL;
    
    status = g_ort->Run(d->session, NULL,
                         input_names, &input_value, 1,
                         output_names, 1, &output_value);
    
    g_ort->ReleaseValue(input_value);
    free(input_tensor);
    
    if (check_status(d, status) != 0) {
        return -1;
    }
    
    /* Get output tensor data */
    float* output_data;
    status = g_ort->GetTensorMutableData(output_value, (void**)&output_data);
    if (check_status(d, status) != 0) {
        g_ort->ReleaseValue(output_value);
        return -1;
    }
    
    /* Get output shape */
    OrtTensorTypeAndShapeInfo* output_info;
    g_ort->GetTensorTypeAndShape(output_value, &output_info);
    
    int64_t output_shape[4];
    size_t num_dims;
    g_ort->GetDimensionsCount(output_info, &num_dims);
    g_ort->GetDimensions(output_info, output_shape, num_dims);
    g_ort->ReleaseTensorTypeAndShapeInfo(output_info);
    
    /* YOLOv8 output format: [1, 4+num_classes, num_boxes]
     * Need to transpose to [num_boxes, 4+num_classes] */
    int num_boxes = (int)output_shape[2];
    int num_features = (int)output_shape[1];  /* 4 + num_classes */
    int num_classes = num_features - 4;
    
    /* Collect detections above confidence threshold */
    vidcom_detection_t* raw_detections = malloc(sizeof(vidcom_detection_t) * num_boxes);
    int num_raw = 0;
    
    for (int i = 0; i < num_boxes && num_raw < num_boxes; i++) {
        /* Find best class */
        int best_class = 0;
        float best_conf = 0;
        
        for (int c = 0; c < num_classes && c < (int)VIDCOM_HIGHLIGHT_COUNT - 1; c++) {
            float conf = output_data[(4 + c) * num_boxes + i];
            if (conf > best_conf) {
                best_conf = conf;
                best_class = c + 1;  /* +1 because class 0 is NONE */
            }
        }
        
        if (best_conf >= d->config.confidence_threshold) {
            /* Extract bounding box (center x, center y, width, height) */
            float cx = output_data[0 * num_boxes + i];
            float cy = output_data[1 * num_boxes + i];
            float w = output_data[2 * num_boxes + i];
            float h = output_data[3 * num_boxes + i];
            
            /* Convert to corner format and normalize */
            raw_detections[num_raw].x = (cx - w / 2) / d->input_width;
            raw_detections[num_raw].y = (cy - h / 2) / d->input_height;
            raw_detections[num_raw].w = w / d->input_width;
            raw_detections[num_raw].h = h / d->input_height;
            raw_detections[num_raw].confidence = best_conf;
            raw_detections[num_raw].type = (vidcom_highlight_type_t)best_class;
            raw_detections[num_raw].timestamp = timestamp;
            raw_detections[num_raw].frame_number = frame_number;
            num_raw++;
        }
    }
    
    g_ort->ReleaseValue(output_value);
    
    /* Apply NMS */
    qsort(raw_detections, num_raw, sizeof(vidcom_detection_t), compare_detections);
    
    int* keep = calloc(num_raw, sizeof(int));
    for (int i = 0; i < num_raw; i++) keep[i] = 1;
    
    for (int i = 0; i < num_raw; i++) {
        if (!keep[i]) continue;
        for (int j = i + 1; j < num_raw; j++) {
            if (!keep[j]) continue;
            if (raw_detections[i].type == raw_detections[j].type) {
                float box1[4] = {raw_detections[i].x, raw_detections[i].y,
                                 raw_detections[i].w, raw_detections[i].h};
                float box2[4] = {raw_detections[j].x, raw_detections[j].y,
                                 raw_detections[j].w, raw_detections[j].h};
                if (iou(box1, box2) > d->config.nms_threshold) {
                    keep[j] = 0;
                }
            }
        }
    }
    
    /* Copy kept detections to output */
    int num_final = 0;
    for (int i = 0; i < num_raw && num_final < max_detections; i++) {
        if (keep[i]) {
            detections[num_final++] = raw_detections[i];
        }
    }
    
    free(keep);
    free(raw_detections);
    
    return num_final;
}

int vidcom_detector_merge_segments(
    vidcom_highlight_detector_t* d,
    const vidcom_detection_t* detections,
    int num_detections,
    vidcom_highlight_segment_t* segments,
    int max_segments
) {
    if (d == NULL || detections == NULL || segments == NULL || 
        num_detections <= 0 || max_segments <= 0) {
        return 0;
    }
    
    float merge_gap = d->config.merge_threshold;
    float pad_before = d->config.padding_before;
    float pad_after = d->config.padding_after;
    
    /* Sort detections by timestamp (assuming they're already sorted, but be safe) */
    vidcom_detection_t* sorted = malloc(sizeof(vidcom_detection_t) * num_detections);
    memcpy(sorted, detections, sizeof(vidcom_detection_t) * num_detections);
    
    /* Simple bubble sort by timestamp (detections are usually already ordered) */
    for (int i = 0; i < num_detections - 1; i++) {
        for (int j = 0; j < num_detections - i - 1; j++) {
            if (sorted[j].timestamp > sorted[j + 1].timestamp) {
                vidcom_detection_t tmp = sorted[j];
                sorted[j] = sorted[j + 1];
                sorted[j + 1] = tmp;
            }
        }
    }
    
    int num_segments = 0;
    int i = 0;
    
    while (i < num_detections && num_segments < max_segments) {
        /* Start new segment */
        vidcom_highlight_segment_t* seg = &segments[num_segments];
        seg->start_time = sorted[i].timestamp - pad_before;
        if (seg->start_time < 0) seg->start_time = 0;
        seg->end_time = sorted[i].timestamp + pad_after;
        seg->primary_type = sorted[i].type;
        seg->detection_count = 1;
        seg->max_confidence = sorted[i].confidence;
        float conf_sum = sorted[i].confidence;
        
        /* Type vote counts */
        int type_votes[VIDCOM_HIGHLIGHT_COUNT] = {0};
        type_votes[sorted[i].type]++;
        
        i++;
        
        /* Merge consecutive detections within gap threshold */
        while (i < num_detections) {
            double gap = sorted[i].timestamp - (seg->end_time - pad_after);
            if (gap <= merge_gap) {
                seg->end_time = sorted[i].timestamp + pad_after;
                seg->detection_count++;
                if (sorted[i].confidence > seg->max_confidence) {
                    seg->max_confidence = sorted[i].confidence;
                }
                conf_sum += sorted[i].confidence;
                type_votes[sorted[i].type]++;
                i++;
            } else {
                break;
            }
        }
        
        /* Determine primary type by majority vote */
        int max_votes = 0;
        for (int t = 1; t < VIDCOM_HIGHLIGHT_COUNT; t++) {
            if (type_votes[t] > max_votes) {
                max_votes = type_votes[t];
                seg->primary_type = (vidcom_highlight_type_t)t;
            }
        }
        
        seg->avg_confidence = conf_sum / seg->detection_count;
        num_segments++;
    }
    
    free(sorted);
    return num_segments;
}

int vidcom_detector_get_game_roi(vidcom_game_type_t game, vidcom_roi_t* roi) {
    if (roi == NULL || game >= VIDCOM_GAME_COUNT) {
        return -1;
    }
    *roi = GAME_ROIS[game];
    return 0;
}

const char* vidcom_highlight_type_name(vidcom_highlight_type_t type) {
    if (type >= VIDCOM_HIGHLIGHT_COUNT) {
        return "UNKNOWN";
    }
    return HIGHLIGHT_TYPE_NAMES[type];
}

const char* vidcom_detector_get_error(vidcom_highlight_detector_t* d) {
    if (d == NULL) return "Detector is NULL";
    return d->error_msg;
}
