/*
 * frame_extract.h - FFmpeg-based frame extraction for video analysis
 * 
 * Extracts frames from video files for ML classification.
 * Supports hardware-accelerated decoding via NVDEC.
 */

#ifndef VIDCOM_FRAME_EXTRACT_H
#define VIDCOM_FRAME_EXTRACT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque extractor handle */
typedef struct vidcom_extractor vidcom_extractor_t;

/* Frame data */
typedef struct {
    uint8_t* data;          /* RGB24 pixel data (HWC format) */
    int width;              /* Frame width */
    int height;             /* Frame height */
    double timestamp;       /* Timestamp in seconds */
    int64_t frame_number;   /* Frame number in video */
} vidcom_frame_t;

/* Extraction mode */
typedef enum {
    VIDCOM_EXTRACT_INTERVAL,    /* Extract every N seconds */
    VIDCOM_EXTRACT_SCENE,       /* Extract on scene changes */
    VIDCOM_EXTRACT_KEYFRAME     /* Extract only keyframes */
} vidcom_extract_mode_t;

/* Configuration */
typedef struct {
    const char* input_path;     /* Path to video file */
    vidcom_extract_mode_t mode; /* Extraction mode */
    double interval;            /* Interval in seconds (for INTERVAL mode) */
    double scene_threshold;     /* Scene change threshold 0.0-1.0 (for SCENE mode) */
    int use_hwaccel;           /* Use NVDEC hardware acceleration */
    int target_width;          /* Resize to width (0 = original) */
    int target_height;         /* Resize to height (0 = original) */
} vidcom_extractor_config_t;

/* Default configuration */
#define VIDCOM_EXTRACTOR_CONFIG_DEFAULT { \
    .input_path = NULL, \
    .mode = VIDCOM_EXTRACT_INTERVAL, \
    .interval = 1.0, \
    .scene_threshold = 0.4, \
    .use_hwaccel = 1, \
    .target_width = 0, \
    .target_height = 0 \
}

/* Video metadata */
typedef struct {
    int width;                  /* Video width */
    int height;                 /* Video height */
    double duration;            /* Duration in seconds */
    double fps;                 /* Frames per second */
    int64_t total_frames;       /* Total frame count */
    const char* codec;          /* Codec name */
} vidcom_video_info_t;

/*
 * Create frame extractor for video file
 * 
 * @param config Configuration options
 * @return Extractor handle, or NULL on error
 */
vidcom_extractor_t* vidcom_extractor_create(const vidcom_extractor_config_t* config);

/*
 * Free extractor resources
 */
void vidcom_extractor_destroy(vidcom_extractor_t* extractor);

/*
 * Get video metadata
 * 
 * @param extractor Extractor handle
 * @param info Output video info
 * @return 0 on success, negative on error
 */
int vidcom_extractor_get_info(
    vidcom_extractor_t* extractor,
    vidcom_video_info_t* info
);

/*
 * Seek to timestamp
 * 
 * @param extractor Extractor handle
 * @param timestamp Target timestamp in seconds
 * @return 0 on success, negative on error
 */
int vidcom_extractor_seek(vidcom_extractor_t* extractor, double timestamp);

/*
 * Extract next frame according to configured mode
 * 
 * @param extractor Extractor handle
 * @param frame Output frame (caller must free with vidcom_frame_free)
 * @return 1 if frame extracted, 0 if end of video, negative on error
 */
int vidcom_extractor_next_frame(
    vidcom_extractor_t* extractor,
    vidcom_frame_t* frame
);

/*
 * Extract frame at specific timestamp
 * 
 * @param extractor Extractor handle
 * @param timestamp Target timestamp in seconds
 * @param frame Output frame
 * @return 0 on success, negative on error
 */
int vidcom_extractor_frame_at(
    vidcom_extractor_t* extractor,
    double timestamp,
    vidcom_frame_t* frame
);

/*
 * Free frame memory
 */
void vidcom_frame_free(vidcom_frame_t* frame);

/*
 * Save frame to image file
 * 
 * @param frame Frame to save
 * @param output_path Output file path (JPEG or PNG based on extension)
 * @param quality JPEG quality 1-100 (ignored for PNG)
 * @return 0 on success, negative on error
 */
int vidcom_frame_save(
    const vidcom_frame_t* frame,
    const char* output_path,
    int quality
);

/*
 * Get last error message
 */
const char* vidcom_extractor_get_error(vidcom_extractor_t* extractor);

#ifdef __cplusplus
}
#endif

#endif /* VIDCOM_FRAME_EXTRACT_H */
