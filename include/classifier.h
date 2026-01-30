/*
 * classifier.h - ONNX Runtime C API wrapper for game classification
 * 
 * Provides image classification using pre-trained ONNX models with
 * CUDA/TensorRT acceleration.
 */

#ifndef VIDCOM_CLASSIFIER_H
#define VIDCOM_CLASSIFIER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque classifier handle */
typedef struct vidcom_classifier vidcom_classifier_t;

/* Classification result */
typedef struct {
    int class_id;           /* ImageNet class ID (0-999) */
    float confidence;       /* Confidence score (0.0-1.0) */
    const char* label;      /* Human-readable label (may be NULL) */
} vidcom_class_result_t;

/* Feature vector for similarity matching */
typedef struct {
    float* data;            /* Feature embedding */
    size_t length;          /* Vector dimension (e.g., 2048 for ResNet) */
} vidcom_features_t;

/* Execution provider */
typedef enum {
    VIDCOM_EP_CPU = 0,      /* CPU execution (fallback) */
    VIDCOM_EP_CUDA,         /* NVIDIA CUDA */
    VIDCOM_EP_TENSORRT      /* NVIDIA TensorRT (fastest) */
} vidcom_execution_provider_t;

/* Configuration */
typedef struct {
    const char* model_path;                 /* Path to ONNX model file */
    vidcom_execution_provider_t provider;   /* Execution provider */
    int device_id;                          /* GPU device ID (for CUDA/TRT) */
    int num_threads;                        /* CPU threads (0 = auto) */
} vidcom_classifier_config_t;

/* Default configuration */
#define VIDCOM_CLASSIFIER_CONFIG_DEFAULT { \
    .model_path = NULL, \
    .provider = VIDCOM_EP_CUDA, \
    .device_id = 0, \
    .num_threads = 0 \
}

/*
 * Initialize classifier with ONNX model
 * 
 * @param config Configuration options
 * @return Classifier handle, or NULL on error
 */
vidcom_classifier_t* vidcom_classifier_create(const vidcom_classifier_config_t* config);

/*
 * Free classifier resources
 */
void vidcom_classifier_destroy(vidcom_classifier_t* classifier);

/*
 * Classify an image from raw RGB data
 * 
 * @param classifier Classifier handle
 * @param rgb_data Raw RGB pixel data (HWC format, uint8)
 * @param width Image width
 * @param height Image height
 * @param results Output array for top-k results
 * @param max_results Maximum results to return
 * @return Number of results, or negative on error
 */
int vidcom_classifier_predict(
    vidcom_classifier_t* classifier,
    const uint8_t* rgb_data,
    int width,
    int height,
    vidcom_class_result_t* results,
    int max_results
);

/*
 * Classify an image from file
 * 
 * @param classifier Classifier handle
 * @param image_path Path to image file (JPEG, PNG)
 * @param results Output array for top-k results
 * @param max_results Maximum results to return
 * @return Number of results, or negative on error
 */
int vidcom_classifier_predict_file(
    vidcom_classifier_t* classifier,
    const char* image_path,
    vidcom_class_result_t* results,
    int max_results
);

/*
 * Extract feature embedding from image (for similarity matching)
 * 
 * @param classifier Classifier handle
 * @param rgb_data Raw RGB pixel data
 * @param width Image width
 * @param height Image height
 * @param features Output feature vector (caller must free with vidcom_features_free)
 * @return 0 on success, negative on error
 */
int vidcom_classifier_extract_features(
    vidcom_classifier_t* classifier,
    const uint8_t* rgb_data,
    int width,
    int height,
    vidcom_features_t* features
);

/*
 * Free feature vector memory
 */
void vidcom_features_free(vidcom_features_t* features);

/*
 * Compute cosine similarity between two feature vectors
 * 
 * @param a First feature vector
 * @param b Second feature vector
 * @return Similarity score (-1.0 to 1.0), or NaN on error
 */
float vidcom_features_similarity(
    const vidcom_features_t* a,
    const vidcom_features_t* b
);

/*
 * Get last error message
 */
const char* vidcom_classifier_get_error(vidcom_classifier_t* classifier);

#ifdef __cplusplus
}
#endif

#endif /* VIDCOM_CLASSIFIER_H */
