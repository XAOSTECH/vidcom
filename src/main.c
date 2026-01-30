/*
 * main.c - VIDCOM pipeline orchestrator
 * 
 * Usage: vidcom <command> [options]
 * 
 * Commands:
 *   analyze <video>       Analyze video and identify game
 *   extract <video>       Extract highlight candidates
 *   encode <video> <out>  Encode segment for Shorts
 *   db <subcommand>       Database management
 *   help                  Show help
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <getopt.h>

#include "classifier.h"
#include "frame_extract.h"
#include "feature_db.h"

#define VERSION "0.1.0"

/* Global options */
static struct {
    int verbose;
    int use_gpu;
    int device_id;
    const char* model_path;
    const char* db_path;
} g_opts = {
    .verbose = 0,
    .use_gpu = 1,
    .device_id = 0,
    .model_path = "models/resnet50.onnx",
    .db_path = "models/game_signatures.db"
};

static void print_usage(const char* prog) {
    printf("VIDCOM - Video Compilation Pipeline for Gaming Streams\n");
    printf("Version %s\n\n", VERSION);
    printf("Usage: %s <command> [options]\n\n", prog);
    printf("Commands:\n");
    printf("  analyze <video>           Analyze video and identify game\n");
    printf("  extract <video>           Extract frames and find highlights\n");
    printf("  encode <in> <out> [opts]  Encode segment for YouTube Shorts\n");
    printf("  db add <name>             Add game to database\n");
    printf("  db import <game_id> <dir> Import signatures from images\n");
    printf("  db list                   List all games in database\n");
    printf("  db stats                  Show database statistics\n");
    printf("  help                      Show this help message\n\n");
    printf("Global Options:\n");
    printf("  -v, --verbose             Verbose output\n");
    printf("  --cpu                     Use CPU instead of GPU\n");
    printf("  --device <id>             GPU device ID (default: 0)\n");
    printf("  --model <path>            Path to ONNX model\n");
    printf("  --db <path>               Path to game database\n");
    printf("\n");
}

/*
 * Analyze video and identify game
 */
static int cmd_analyze(int argc, char** argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: vidcom analyze <video>\n");
        return 1;
    }
    
    const char* video_path = argv[0];
    
    printf("[vidcom] Analyzing: %s\n", video_path);
    
    /* Initialize classifier */
    vidcom_classifier_config_t cls_cfg = VIDCOM_CLASSIFIER_CONFIG_DEFAULT;
    cls_cfg.model_path = g_opts.model_path;
    cls_cfg.provider = g_opts.use_gpu ? VIDCOM_EP_CUDA : VIDCOM_EP_CPU;
    cls_cfg.device_id = g_opts.device_id;
    
    vidcom_classifier_t* classifier = vidcom_classifier_create(&cls_cfg);
    if (classifier == NULL) {
        fprintf(stderr, "Failed to load classifier model: %s\n", g_opts.model_path);
        return 1;
    }
    
    /* Initialize frame extractor */
    vidcom_extractor_config_t ext_cfg = VIDCOM_EXTRACTOR_CONFIG_DEFAULT;
    ext_cfg.input_path = video_path;
    ext_cfg.mode = VIDCOM_EXTRACT_INTERVAL;
    ext_cfg.interval = 5.0;  /* Sample every 5 seconds */
    ext_cfg.use_hwaccel = g_opts.use_gpu;
    ext_cfg.target_width = 224;   /* ResNet input size */
    ext_cfg.target_height = 224;
    
    vidcom_extractor_t* extractor = vidcom_extractor_create(&ext_cfg);
    if (extractor == NULL) {
        fprintf(stderr, "Failed to open video: %s\n", video_path);
        vidcom_classifier_destroy(classifier);
        return 1;
    }
    
    /* Get video info */
    vidcom_video_info_t info;
    vidcom_extractor_get_info(extractor, &info);
    printf("[vidcom] Video: %dx%d, %.2f fps, %.2f seconds\n",
           info.width, info.height, info.fps, info.duration);
    
    /* Sample frames and classify */
    printf("[vidcom] Sampling frames...\n");
    
    vidcom_frame_t frame;
    vidcom_class_result_t results[5];
    int frame_count = 0;
    int class_votes[1000] = {0};  /* ImageNet classes */
    
    while (vidcom_extractor_next_frame(extractor, &frame) == 1) {
        int n = vidcom_classifier_predict(classifier, frame.data,
                                          frame.width, frame.height,
                                          results, 5);
        
        if (n > 0) {
            /* Vote for top class */
            class_votes[results[0].class_id]++;
            
            if (g_opts.verbose) {
                printf("  Frame %.1fs: class=%d confidence=%.3f\n",
                       frame.timestamp, results[0].class_id, results[0].confidence);
            }
        }
        
        vidcom_frame_free(&frame);
        frame_count++;
    }
    
    printf("[vidcom] Analyzed %d frames\n", frame_count);
    
    /* Find most common class */
    int best_class = 0;
    int best_votes = 0;
    for (int i = 0; i < 1000; i++) {
        if (class_votes[i] > best_votes) {
            best_votes = class_votes[i];
            best_class = i;
        }
    }
    
    printf("[vidcom] Most common class: %d (votes: %d/%d)\n",
           best_class, best_votes, frame_count);
    
    /* TODO: Match against game database */
    
    vidcom_extractor_destroy(extractor);
    vidcom_classifier_destroy(classifier);
    
    return 0;
}

/*
 * Extract frames and find highlight candidates
 */
static int cmd_extract(int argc, char** argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: vidcom extract <video>\n");
        return 1;
    }
    
    const char* video_path = argv[0];
    
    printf("[vidcom] Extracting highlights from: %s\n", video_path);
    
    /* Initialize frame extractor with scene detection */
    vidcom_extractor_config_t cfg = VIDCOM_EXTRACTOR_CONFIG_DEFAULT;
    cfg.input_path = video_path;
    cfg.mode = VIDCOM_EXTRACT_SCENE;
    cfg.scene_threshold = 0.3;
    cfg.use_hwaccel = g_opts.use_gpu;
    
    vidcom_extractor_t* extractor = vidcom_extractor_create(&cfg);
    if (extractor == NULL) {
        fprintf(stderr, "Failed to open video: %s\n", video_path);
        return 1;
    }
    
    /* Extract scene changes */
    vidcom_frame_t frame;
    int scene_count = 0;
    
    printf("[vidcom] Detecting scene changes...\n");
    printf("Timestamp,FrameNumber\n");
    
    while (vidcom_extractor_next_frame(extractor, &frame) == 1) {
        printf("%.3f,%ld\n", frame.timestamp, frame.frame_number);
        
        /* Optionally save thumbnail */
        if (g_opts.verbose) {
            char thumb_path[256];
            snprintf(thumb_path, sizeof(thumb_path), 
                     "output/scene_%03d.jpg", scene_count);
            vidcom_frame_save(&frame, thumb_path, 85);
        }
        
        vidcom_frame_free(&frame);
        scene_count++;
    }
    
    printf("[vidcom] Found %d scene changes\n", scene_count);
    
    vidcom_extractor_destroy(extractor);
    return 0;
}

/*
 * Database management commands
 */
static int cmd_db(int argc, char** argv) {
    if (argc < 1) {
        fprintf(stderr, "Usage: vidcom db <subcommand>\n");
        fprintf(stderr, "  add <name> [category] [tags]\n");
        fprintf(stderr, "  list\n");
        fprintf(stderr, "  stats\n");
        return 1;
    }
    
    const char* subcmd = argv[0];
    
    vidcom_feature_db_t* db = vidcom_feature_db_open(g_opts.db_path);
    if (db == NULL) {
        fprintf(stderr, "Failed to open database: %s\n", g_opts.db_path);
        return 1;
    }
    
    int ret = 0;
    
    if (strcmp(subcmd, "add") == 0) {
        if (argc < 2) {
            fprintf(stderr, "Usage: vidcom db add <name> [category] [tags]\n");
            ret = 1;
        } else {
            const char* name = argv[1];
            const char* category = argc > 2 ? argv[2] : "Unknown";
            const char* tags = argc > 3 ? argv[3] : "";
            
            int id = vidcom_feature_db_add_game(db, name, category, tags);
            if (id >= 0) {
                printf("Added game: %s (ID: %d)\n", name, id);
            } else {
                fprintf(stderr, "Failed to add game\n");
                ret = 1;
            }
        }
    }
    else if (strcmp(subcmd, "list") == 0) {
        vidcom_game_entry_t games[100];
        int count = vidcom_feature_db_list_games(db, games, 100);
        
        printf("Games in database:\n");
        printf("ID  Name                           Category    Signatures\n");
        printf("--- ------------------------------ ----------- ----------\n");
        
        for (int i = 0; i < count; i++) {
            printf("%-3d %-30s %-11s %d\n",
                   games[i].id, games[i].name, 
                   games[i].category, games[i].num_signatures);
        }
        
        printf("\nTotal: %d games\n", count);
    }
    else if (strcmp(subcmd, "stats") == 0) {
        int num_games, num_sigs, feat_dim;
        vidcom_feature_db_stats(db, &num_games, &num_sigs, &feat_dim);
        
        printf("Database Statistics:\n");
        printf("  Path:              %s\n", g_opts.db_path);
        printf("  Games:             %d\n", num_games);
        printf("  Total signatures:  %d\n", num_sigs);
        printf("  Feature dimension: %d\n", feat_dim);
    }
    else {
        fprintf(stderr, "Unknown db subcommand: %s\n", subcmd);
        ret = 1;
    }
    
    vidcom_feature_db_close(db);
    return ret;
}

int main(int argc, char** argv) {
    /* Parse global options */
    static struct option long_opts[] = {
        {"verbose", no_argument, NULL, 'v'},
        {"cpu", no_argument, NULL, 'c'},
        {"device", required_argument, NULL, 'd'},
        {"model", required_argument, NULL, 'm'},
        {"db", required_argument, NULL, 'b'},
        {"help", no_argument, NULL, 'h'},
        {NULL, 0, NULL, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "vcd:m:b:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'v':
                g_opts.verbose = 1;
                break;
            case 'c':
                g_opts.use_gpu = 0;
                break;
            case 'd':
                g_opts.device_id = atoi(optarg);
                break;
            case 'm':
                g_opts.model_path = optarg;
                break;
            case 'b':
                g_opts.db_path = optarg;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    /* Get command */
    if (optind >= argc) {
        print_usage(argv[0]);
        return 1;
    }
    
    const char* cmd = argv[optind];
    int cmd_argc = argc - optind - 1;
    char** cmd_argv = argv + optind + 1;
    
    /* Dispatch command */
    if (strcmp(cmd, "analyze") == 0) {
        return cmd_analyze(cmd_argc, cmd_argv);
    }
    else if (strcmp(cmd, "extract") == 0) {
        return cmd_extract(cmd_argc, cmd_argv);
    }
    else if (strcmp(cmd, "db") == 0) {
        return cmd_db(cmd_argc, cmd_argv);
    }
    else if (strcmp(cmd, "help") == 0) {
        print_usage(argv[0]);
        return 0;
    }
    else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        print_usage(argv[0]);
        return 1;
    }
}
