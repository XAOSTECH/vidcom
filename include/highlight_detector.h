/*
 * highlight_detector.h - YOLO-based gaming highlight detection
 * 
 * Detects kill indicators, headshots, assists, and action moments
 * in gaming footage using YOLOv8/v11 object detection.
 * 
 * Supports: Fortnite, Valorant, CSGO2, Overwatch, Apex Legends
 */

#ifndef VIDCOM_HIGHLIGHT_DETECTOR_H
#define VIDCOM_HIGHLIGHT_DETECTOR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque detector handle */
typedef struct vidcom_highlight_detector vidcom_highlight_detector_t;

/* Highlight types (classes) */
typedef enum {
    VIDCOM_HIGHLIGHT_NONE = 0,
    VIDCOM_HIGHLIGHT_KILL,          /* Elimination/kill confirmed */
    VIDCOM_HIGHLIGHT_HEADSHOT,      /* Headshot indicator */
    VIDCOM_HIGHLIGHT_ASSIST,        /* Assist notification */
    VIDCOM_HIGHLIGHT_DOWN,          /* Enemy downed (BR games) */
    VIDCOM_HIGHLIGHT_MULTI_KILL,    /* Double/triple/multi kill */
    VIDCOM_HIGHLIGHT_CLUTCH,        /* Clutch situation (1vX) */
    VIDCOM_HIGHLIGHT_ACTION,        /* General action moment */
    VIDCOM_HIGHLIGHT_COUNT          /* Number of highlight types */
} vidcom_highlight_type_t;

/* Single detection result */
typedef struct {
    vidcom_highlight_type_t type;   /* Type of highlight detected */
    float confidence;               /* Detection confidence (0.0-1.0) */
    float x, y, w, h;               /* Bounding box (normalized 0-1) */
    double timestamp;               /* Frame timestamp in seconds */
    int frame_number;               /* Frame index in video */
} vidcom_detection_t;

/* Highlight segment (merged detections) */
typedef struct {
    vidcom_highlight_type_t primary_type;  /* Dominant highlight type */
    double start_time;                      /* Segment start (seconds) */
    double end_time;                        /* Segment end (seconds) */
    int detection_count;                    /* Number of detections in segment */
    float max_confidence;                   /* Highest confidence in segment */
    float avg_confidence;                   /* Average confidence */
} vidcom_highlight_segment_t;

/* Supported games for specialized detection regions */
typedef enum {
    VIDCOM_GAME_GENERIC = 0,        /* Use full frame */
    VIDCOM_GAME_FORTNITE,           /* Fortnite kill feed region */
    VIDCOM_GAME_VALORANT,           /* Valorant kill confirmation */
    VIDCOM_GAME_CSGO2,              /* CS2 killfeed (top-right) */
    VIDCOM_GAME_OVERWATCH,          /* Overwatch elimination popup */
    VIDCOM_GAME_APEX,               /* Apex Legends kill feed */
    VIDCOM_GAME_COUNT
} vidcom_game_type_t;

/* Detection region of interest */
typedef struct {
    float x, y;         /* Top-left corner (normalized 0-1) */
    float width;        /* Width (normalized 0-1) */
    float height;       /* Height (normalized 0-1) */
} vidcom_roi_t;

/* Detector configuration */
typedef struct {
    const char* model_path;         /* Path to ONNX model */
    vidcom_game_type_t game;        /* Game type for ROI optimization */
    float confidence_threshold;     /* Min confidence (default: 0.5) */
    float nms_threshold;            /* NMS IoU threshold (default: 0.45) */
    int use_gpu;                    /* Use CUDA acceleration */
    int device_id;                  /* GPU device ID */
    
    /* Segment merging */
    float merge_threshold;          /* Max gap between detections to merge (seconds, default: 3.0) */
    float padding_before;           /* Seconds to include before highlight (default: 4.0) */
    float padding_after;            /* Seconds to include after highlight (default: 2.0) */
    
    /* Optional custom ROI (overrides game-specific) */
    vidcom_roi_t* custom_roi;       /* NULL = use game default */
} vidcom_detector_config_t;

/* Default configuration */
#define VIDCOM_DETECTOR_CONFIG_DEFAULT { \
    .model_path = "models/highlight_yolov8n.onnx", \
    .game = VIDCOM_GAME_GENERIC, \
    .confidence_threshold = 0.5f, \
    .nms_threshold = 0.45f, \
    .use_gpu = 1, \
    .device_id = 0, \
    .merge_threshold = 3.0f, \
    .padding_before = 4.0f, \
    .padding_after = 2.0f, \
    .custom_roi = NULL \
}

/*
 * Create highlight detector with YOLO model
 * 
 * @param config Configuration options
 * @return Detector handle, or NULL on error
 */
vidcom_highlight_detector_t* vidcom_detector_create(const vidcom_detector_config_t* config);

/*
 * Free detector resources
 */
void vidcom_detector_destroy(vidcom_highlight_detector_t* detector);

/*
 * Detect highlights in a single frame
 * 
 * @param detector Detector handle
 * @param rgb_data Raw RGB pixel data (HWC format, uint8)
 * @param width Image width
 * @param height Image height
 * @param timestamp Frame timestamp (seconds)
 * @param frame_number Frame index
 * @param detections Output array for detections
 * @param max_detections Maximum detections to return
 * @return Number of detections, or negative on error
 */
int vidcom_detector_detect(
    vidcom_highlight_detector_t* detector,
    const uint8_t* rgb_data,
    int width, int height,
    double timestamp,
    int frame_number,
    vidcom_detection_t* detections,
    int max_detections
);

/*
 * Process accumulated detections into highlight segments
 * 
 * @param detector Detector handle
 * @param detections Array of all detections from video
 * @param num_detections Number of detections
 * @param segments Output array for merged segments
 * @param max_segments Maximum segments to return
 * @return Number of segments, or negative on error
 */
int vidcom_detector_merge_segments(
    vidcom_highlight_detector_t* detector,
    const vidcom_detection_t* detections,
    int num_detections,
    vidcom_highlight_segment_t* segments,
    int max_segments
);

/*
 * Get game-specific detection ROI
 * 
 * @param game Game type
 * @param roi Output ROI structure
 * @return 0 on success, -1 if game not supported
 */
int vidcom_detector_get_game_roi(vidcom_game_type_t game, vidcom_roi_t* roi);

/*
 * Get highlight type name string
 * 
 * @param type Highlight type
 * @return Static string name (e.g., "KILL", "HEADSHOT")
 */
const char* vidcom_highlight_type_name(vidcom_highlight_type_t type);

/*
 * Get last error message
 * 
 * @param detector Detector handle
 * @return Error message string (static, do not free)
 */
const char* vidcom_detector_get_error(vidcom_highlight_detector_t* detector);

#ifdef __cplusplus
}
#endif

#endif /* VIDCOM_HIGHLIGHT_DETECTOR_H */
