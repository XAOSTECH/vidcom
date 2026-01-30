/*
 * frame_extract.c - FFmpeg-based frame extraction implementation
 */

#include "frame_extract.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libswscale/swscale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Extractor structure */
struct vidcom_extractor {
    /* FFmpeg contexts */
    AVFormatContext* fmt_ctx;
    AVCodecContext* codec_ctx;
    struct SwsContext* sws_ctx;
    
    /* Stream info */
    int video_stream_idx;
    AVRational time_base;
    double fps;
    int64_t total_frames;
    double duration;
    
    /* Configuration */
    vidcom_extract_mode_t mode;
    double interval;
    double scene_threshold;
    int target_width;
    int target_height;
    
    /* State */
    double next_extract_time;
    AVFrame* frame;
    AVFrame* frame_rgb;
    AVPacket* packet;
    int64_t decoded_frame_count;  /* Track frames ourselves since frame_number deprecated */
    
    /* Scene detection state */
    uint8_t* prev_frame_data;
    int prev_frame_size;
    
    /* Error handling */
    char error_msg[512];
};

static void set_error(vidcom_extractor_t* e, const char* msg) {
    if (e && msg) {
        strncpy(e->error_msg, msg, sizeof(e->error_msg) - 1);
        e->error_msg[sizeof(e->error_msg) - 1] = '\0';
    }
}

static void set_av_error(vidcom_extractor_t* e, const char* prefix, int err) {
    char buf[256];
    av_strerror(err, buf, sizeof(buf));
    snprintf(e->error_msg, sizeof(e->error_msg), "%s: %s", prefix, buf);
}

vidcom_extractor_t* vidcom_extractor_create(const vidcom_extractor_config_t* config) {
    if (config == NULL || config->input_path == NULL) {
        return NULL;
    }
    
    vidcom_extractor_t* e = calloc(1, sizeof(vidcom_extractor_t));
    if (e == NULL) {
        return NULL;
    }
    
    /* Store configuration */
    e->mode = config->mode;
    e->interval = config->interval > 0 ? config->interval : 1.0;
    e->scene_threshold = config->scene_threshold > 0 ? config->scene_threshold : 0.4;
    e->target_width = config->target_width;
    e->target_height = config->target_height;
    
    int ret;
    
    /* Open input file */
    ret = avformat_open_input(&e->fmt_ctx, config->input_path, NULL, NULL);
    if (ret < 0) {
        set_av_error(e, "Failed to open input", ret);
        goto cleanup;
    }
    
    /* Find stream info */
    ret = avformat_find_stream_info(e->fmt_ctx, NULL);
    if (ret < 0) {
        set_av_error(e, "Failed to find stream info", ret);
        goto cleanup;
    }
    
    /* Find video stream */
    e->video_stream_idx = -1;
    for (unsigned int i = 0; i < e->fmt_ctx->nb_streams; i++) {
        if (e->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            e->video_stream_idx = i;
            break;
        }
    }
    
    if (e->video_stream_idx < 0) {
        set_error(e, "No video stream found");
        goto cleanup;
    }
    
    AVStream* stream = e->fmt_ctx->streams[e->video_stream_idx];
    e->time_base = stream->time_base;
    
    /* Calculate FPS and duration */
    if (stream->avg_frame_rate.den != 0) {
        e->fps = av_q2d(stream->avg_frame_rate);
    } else if (stream->r_frame_rate.den != 0) {
        e->fps = av_q2d(stream->r_frame_rate);
    } else {
        e->fps = 30.0;  /* Fallback */
    }
    
    if (stream->duration != AV_NOPTS_VALUE) {
        e->duration = stream->duration * av_q2d(stream->time_base);
    } else if (e->fmt_ctx->duration != AV_NOPTS_VALUE) {
        e->duration = e->fmt_ctx->duration / (double)AV_TIME_BASE;
    }
    
    e->total_frames = (int64_t)(e->duration * e->fps);
    
    /* Find decoder */
    const AVCodec* codec = NULL;
    
    /* Try hardware decoder first if enabled */
    if (config->use_hwaccel) {
        codec = avcodec_find_decoder_by_name("h264_cuvid");
        if (!codec) {
            codec = avcodec_find_decoder_by_name("hevc_cuvid");
        }
    }
    
    /* Fallback to software decoder */
    if (!codec) {
        codec = avcodec_find_decoder(stream->codecpar->codec_id);
    }
    
    if (!codec) {
        set_error(e, "Failed to find decoder");
        goto cleanup;
    }
    
    /* Create codec context */
    e->codec_ctx = avcodec_alloc_context3(codec);
    if (!e->codec_ctx) {
        set_error(e, "Failed to allocate codec context");
        goto cleanup;
    }
    
    ret = avcodec_parameters_to_context(e->codec_ctx, stream->codecpar);
    if (ret < 0) {
        set_av_error(e, "Failed to copy codec params", ret);
        goto cleanup;
    }
    
    /* Open codec */
    ret = avcodec_open2(e->codec_ctx, codec, NULL);
    if (ret < 0) {
        set_av_error(e, "Failed to open codec", ret);
        goto cleanup;
    }
    
    /* Allocate frames */
    e->frame = av_frame_alloc();
    e->frame_rgb = av_frame_alloc();
    e->packet = av_packet_alloc();
    
    if (!e->frame || !e->frame_rgb || !e->packet) {
        set_error(e, "Failed to allocate frame/packet");
        goto cleanup;
    }
    
    /* Determine output dimensions */
    int out_w = e->target_width > 0 ? e->target_width : e->codec_ctx->width;
    int out_h = e->target_height > 0 ? e->target_height : e->codec_ctx->height;
    
    /* Create scaler context */
    e->sws_ctx = sws_getContext(
        e->codec_ctx->width, e->codec_ctx->height, e->codec_ctx->pix_fmt,
        out_w, out_h, AV_PIX_FMT_RGB24,
        SWS_BILINEAR, NULL, NULL, NULL
    );
    
    if (!e->sws_ctx) {
        set_error(e, "Failed to create scaler");
        goto cleanup;
    }
    
    /* Allocate RGB frame buffer */
    int rgb_size = av_image_get_buffer_size(AV_PIX_FMT_RGB24, out_w, out_h, 1);
    uint8_t* rgb_buffer = av_malloc(rgb_size);
    if (!rgb_buffer) {
        set_error(e, "Failed to allocate RGB buffer");
        goto cleanup;
    }
    
    av_image_fill_arrays(e->frame_rgb->data, e->frame_rgb->linesize,
                         rgb_buffer, AV_PIX_FMT_RGB24, out_w, out_h, 1);
    e->frame_rgb->width = out_w;
    e->frame_rgb->height = out_h;
    
    printf("[vidcom] Opened video: %dx%d @ %.2f fps, %.2f seconds\n",
           e->codec_ctx->width, e->codec_ctx->height, e->fps, e->duration);
    
    return e;
    
cleanup:
    vidcom_extractor_destroy(e);
    return NULL;
}

void vidcom_extractor_destroy(vidcom_extractor_t* e) {
    if (e == NULL) return;
    
    if (e->frame_rgb && e->frame_rgb->data[0]) {
        av_freep(&e->frame_rgb->data[0]);
    }
    if (e->frame_rgb) av_frame_free(&e->frame_rgb);
    if (e->frame) av_frame_free(&e->frame);
    if (e->packet) av_packet_free(&e->packet);
    if (e->sws_ctx) sws_freeContext(e->sws_ctx);
    if (e->codec_ctx) avcodec_free_context(&e->codec_ctx);
    if (e->fmt_ctx) avformat_close_input(&e->fmt_ctx);
    if (e->prev_frame_data) free(e->prev_frame_data);
    
    free(e);
}

int vidcom_extractor_get_info(vidcom_extractor_t* e, vidcom_video_info_t* info) {
    if (e == NULL || info == NULL) return -1;
    
    info->width = e->codec_ctx->width;
    info->height = e->codec_ctx->height;
    info->duration = e->duration;
    info->fps = e->fps;
    info->total_frames = e->total_frames;
    info->codec = e->codec_ctx->codec->name;
    
    return 0;
}

int vidcom_extractor_seek(vidcom_extractor_t* e, double timestamp) {
    if (e == NULL) return -1;
    
    int64_t ts = (int64_t)(timestamp / av_q2d(e->time_base));
    int ret = av_seek_frame(e->fmt_ctx, e->video_stream_idx, ts, 
                            AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        set_av_error(e, "Seek failed", ret);
        return -1;
    }
    
    avcodec_flush_buffers(e->codec_ctx);
    e->next_extract_time = timestamp;
    
    return 0;
}

/*
 * Compute simple scene change score (sum of absolute differences)
 */
static double compute_scene_score(
    const uint8_t* cur, const uint8_t* prev, int size
) {
    if (!prev || size == 0) return 1.0;  /* First frame is always a scene change */
    
    int64_t diff = 0;
    for (int i = 0; i < size; i++) {
        diff += abs((int)cur[i] - (int)prev[i]);
    }
    
    /* Normalize to 0-1 range */
    return (double)diff / (size * 255.0);
}

int vidcom_extractor_next_frame(vidcom_extractor_t* e, vidcom_frame_t* out) {
    if (e == NULL || out == NULL) return -1;
    
    memset(out, 0, sizeof(vidcom_frame_t));
    
    while (1) {
        /* Read packet */
        int ret = av_read_frame(e->fmt_ctx, e->packet);
        if (ret == AVERROR_EOF) {
            return 0;  /* End of file */
        }
        if (ret < 0) {
            set_av_error(e, "Read frame failed", ret);
            return -1;
        }
        
        /* Skip non-video packets */
        if (e->packet->stream_index != e->video_stream_idx) {
            av_packet_unref(e->packet);
            continue;
        }
        
        /* Decode frame */
        ret = avcodec_send_packet(e->codec_ctx, e->packet);
        av_packet_unref(e->packet);
        
        if (ret < 0) {
            set_av_error(e, "Send packet failed", ret);
            return -1;
        }
        
        while (ret >= 0) {
            ret = avcodec_receive_frame(e->codec_ctx, e->frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
                break;
            }
            if (ret < 0) {
                set_av_error(e, "Receive frame failed", ret);
                return -1;
            }
            
            /* Calculate timestamp */
            double pts = e->frame->pts * av_q2d(e->time_base);
            
            /* Check if we should extract this frame based on mode */
            int extract = 0;
            
            switch (e->mode) {
                case VIDCOM_EXTRACT_INTERVAL:
                    if (pts >= e->next_extract_time) {
                        extract = 1;
                        e->next_extract_time = pts + e->interval;
                    }
                    break;
                    
                case VIDCOM_EXTRACT_KEYFRAME:
                    /* FFmpeg 6.0+: use flags instead of deprecated key_frame */
                    if (e->frame->flags & AV_FRAME_FLAG_KEY) {
                        extract = 1;
                    }
                    break;
                    
                case VIDCOM_EXTRACT_SCENE: {
                    /* Convert to RGB first for scene detection */
                    sws_scale(e->sws_ctx,
                              (const uint8_t* const*)e->frame->data, 
                              e->frame->linesize,
                              0, e->codec_ctx->height,
                              e->frame_rgb->data, e->frame_rgb->linesize);
                    
                    int frame_size = e->frame_rgb->width * e->frame_rgb->height * 3;
                    double score = compute_scene_score(
                        e->frame_rgb->data[0], e->prev_frame_data, frame_size);
                    
                    if (score >= e->scene_threshold) {
                        extract = 1;
                    }
                    
                    /* Store current frame for next comparison */
                    if (!e->prev_frame_data) {
                        e->prev_frame_data = malloc(frame_size);
                        e->prev_frame_size = frame_size;
                    }
                    memcpy(e->prev_frame_data, e->frame_rgb->data[0], frame_size);
                    break;
                }
            }
            
            if (extract) {
                /* Convert to RGB if not already done */
                if (e->mode != VIDCOM_EXTRACT_SCENE) {
                    sws_scale(e->sws_ctx,
                              (const uint8_t* const*)e->frame->data,
                              e->frame->linesize,
                              0, e->codec_ctx->height,
                              e->frame_rgb->data, e->frame_rgb->linesize);
                }
                
                /* Copy frame data */
                int frame_size = e->frame_rgb->width * e->frame_rgb->height * 3;
                out->data = malloc(frame_size);
                if (!out->data) {
                    set_error(e, "Failed to allocate frame buffer");
                    return -1;
                }
                
                /* Handle potential line padding */
                if (e->frame_rgb->linesize[0] == e->frame_rgb->width * 3) {
                    memcpy(out->data, e->frame_rgb->data[0], frame_size);
                } else {
                    for (int y = 0; y < e->frame_rgb->height; y++) {
                        memcpy(out->data + y * e->frame_rgb->width * 3,
                               e->frame_rgb->data[0] + y * e->frame_rgb->linesize[0],
                               e->frame_rgb->width * 3);
                    }
                }
                
                out->width = e->frame_rgb->width;
                out->height = e->frame_rgb->height;
                out->timestamp = pts;
                out->frame_number = e->decoded_frame_count++;
                
                return 1;  /* Frame extracted */
            }
        }
    }
}

int vidcom_extractor_frame_at(
    vidcom_extractor_t* e,
    double timestamp,
    vidcom_frame_t* frame
) {
    if (vidcom_extractor_seek(e, timestamp) != 0) {
        return -1;
    }
    
    /* Temporarily switch to keyframe mode to get nearest frame */
    vidcom_extract_mode_t old_mode = e->mode;
    e->mode = VIDCOM_EXTRACT_KEYFRAME;
    
    int ret = vidcom_extractor_next_frame(e, frame);
    
    e->mode = old_mode;
    return ret;
}

void vidcom_frame_free(vidcom_frame_t* frame) {
    if (frame && frame->data) {
        free(frame->data);
        frame->data = NULL;
    }
}

int vidcom_frame_save(
    const vidcom_frame_t* frame,
    const char* output_path,
    int quality
) {
    if (frame == NULL || frame->data == NULL || output_path == NULL) {
        return -1;
    }
    
    /* Determine format from extension */
    const char* ext = strrchr(output_path, '.');
    enum AVCodecID codec_id = AV_CODEC_ID_MJPEG;
    enum AVPixelFormat pix_fmt = AV_PIX_FMT_YUVJ420P;
    
    if (ext && (strcasecmp(ext, ".png") == 0)) {
        codec_id = AV_CODEC_ID_PNG;
        pix_fmt = AV_PIX_FMT_RGB24;
    }
    
    const AVCodec* codec = avcodec_find_encoder(codec_id);
    if (!codec) {
        return -1;
    }
    
    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) {
        return -1;
    }
    
    ctx->width = frame->width;
    ctx->height = frame->height;
    ctx->pix_fmt = pix_fmt;
    ctx->time_base = (AVRational){1, 25};
    
    if (codec_id == AV_CODEC_ID_MJPEG) {
        /* JPEG quality (2-31, lower is better) */
        int q = 31 - (quality * 29 / 100);
        if (q < 2) q = 2;
        ctx->global_quality = q * FF_QP2LAMBDA;
        ctx->flags |= AV_CODEC_FLAG_QSCALE;
    }
    
    if (avcodec_open2(ctx, codec, NULL) < 0) {
        avcodec_free_context(&ctx);
        return -1;
    }
    
    AVFrame* av_frame = av_frame_alloc();
    av_frame->format = pix_fmt;
    av_frame->width = frame->width;
    av_frame->height = frame->height;
    av_frame_get_buffer(av_frame, 0);
    
    /* Convert RGB to output format if needed */
    if (pix_fmt != AV_PIX_FMT_RGB24) {
        struct SwsContext* sws = sws_getContext(
            frame->width, frame->height, AV_PIX_FMT_RGB24,
            frame->width, frame->height, pix_fmt,
            SWS_BILINEAR, NULL, NULL, NULL
        );
        
        const uint8_t* src_data[1] = {frame->data};
        int src_linesize[1] = {frame->width * 3};
        
        sws_scale(sws, src_data, src_linesize, 0, frame->height,
                  av_frame->data, av_frame->linesize);
        sws_freeContext(sws);
    } else {
        memcpy(av_frame->data[0], frame->data, 
               frame->width * frame->height * 3);
    }
    
    AVPacket* pkt = av_packet_alloc();
    int ret = avcodec_send_frame(ctx, av_frame);
    if (ret >= 0) {
        ret = avcodec_receive_packet(ctx, pkt);
    }
    
    if (ret >= 0) {
        FILE* f = fopen(output_path, "wb");
        if (f) {
            fwrite(pkt->data, 1, pkt->size, f);
            fclose(f);
            ret = 0;
        } else {
            ret = -1;
        }
    }
    
    av_packet_free(&pkt);
    av_frame_free(&av_frame);
    avcodec_free_context(&ctx);
    
    return ret;
}

const char* vidcom_extractor_get_error(vidcom_extractor_t* e) {
    return (e != NULL) ? e->error_msg : "Invalid extractor";
}
