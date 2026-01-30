/*
 * feature_db.c - Game signature database implementation
 * 
 * Uses SQLite for persistence and efficient similarity search.
 * Feature vectors are stored as BLOBs with game metadata.
 */

#include "feature_db.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dirent.h>
#include <sys/stat.h>

/* Simple file-based database implementation
 * Format: binary file with header + entries
 * 
 * For production, this should use SQLite or a vector database.
 * This simplified version demonstrates the API.
 */

#define DB_MAGIC 0x56494447  /* "VIDG" */
#define DB_VERSION 1
#define MAX_GAMES 1000
#define MAX_SIGNATURES_PER_GAME 100
#define MAX_FEATURE_DIM 4096

/* Database header */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t num_games;
    uint32_t feature_dim;
    uint32_t reserved[4];
} db_header_t;

/* Signature entry (stored in file) */
typedef struct {
    int32_t game_id;
    float features[MAX_FEATURE_DIM];
} signature_entry_t;

/* In-memory game entry */
typedef struct {
    vidcom_game_entry_t info;
    signature_entry_t* signatures;
    int num_signatures;
    int signatures_capacity;
} game_data_t;

/* Database structure */
struct vidcom_feature_db {
    char* path;
    db_header_t header;
    game_data_t* games;
    int games_capacity;
    char error_msg[512];
    int dirty;  /* Needs save */
};

static void set_error(vidcom_feature_db_t* db, const char* msg) {
    if (db && msg) {
        strncpy(db->error_msg, msg, sizeof(db->error_msg) - 1);
        db->error_msg[sizeof(db->error_msg) - 1] = '\0';
    }
}

static int save_database(vidcom_feature_db_t* db);
static int load_database(vidcom_feature_db_t* db);

vidcom_feature_db_t* vidcom_feature_db_open(const char* db_path) {
    if (db_path == NULL) return NULL;
    
    vidcom_feature_db_t* db = calloc(1, sizeof(vidcom_feature_db_t));
    if (db == NULL) return NULL;
    
    db->path = strdup(db_path);
    if (db->path == NULL) {
        free(db);
        return NULL;
    }
    
    /* Initialize header with defaults */
    db->header.magic = DB_MAGIC;
    db->header.version = DB_VERSION;
    db->header.num_games = 0;
    db->header.feature_dim = 2048;  /* ResNet-50 default */
    
    /* Allocate game array */
    db->games_capacity = 64;
    db->games = calloc(db->games_capacity, sizeof(game_data_t));
    if (db->games == NULL) {
        free(db->path);
        free(db);
        return NULL;
    }
    
    /* Try to load existing database */
    FILE* f = fopen(db_path, "rb");
    if (f != NULL) {
        fclose(f);
        if (load_database(db) != 0) {
            fprintf(stderr, "[vidcom] Warning: Could not load database, starting fresh\n");
        }
    }
    
    printf("[vidcom] Database opened: %s (%d games)\n", 
           db_path, db->header.num_games);
    
    return db;
}

void vidcom_feature_db_close(vidcom_feature_db_t* db) {
    if (db == NULL) return;
    
    /* Save if dirty */
    if (db->dirty) {
        save_database(db);
    }
    
    /* Free game data */
    for (uint32_t i = 0; i < db->header.num_games; i++) {
        if (db->games[i].signatures) {
            free(db->games[i].signatures);
        }
    }
    
    free(db->games);
    free(db->path);
    free(db);
}

int vidcom_feature_db_add_game(
    vidcom_feature_db_t* db,
    const char* name,
    const char* category,
    const char* tags
) {
    if (db == NULL || name == NULL) return -1;
    
    /* Check capacity */
    if (db->header.num_games >= (uint32_t)db->games_capacity) {
        int new_cap = db->games_capacity * 2;
        game_data_t* new_games = realloc(db->games, new_cap * sizeof(game_data_t));
        if (new_games == NULL) {
            set_error(db, "Failed to expand game array");
            return -1;
        }
        memset(new_games + db->games_capacity, 0, 
               (new_cap - db->games_capacity) * sizeof(game_data_t));
        db->games = new_games;
        db->games_capacity = new_cap;
    }
    
    /* Create new game entry */
    int id = db->header.num_games;
    game_data_t* game = &db->games[id];
    
    game->info.id = id;
    strncpy(game->info.name, name, sizeof(game->info.name) - 1);
    if (category) {
        strncpy(game->info.category, category, sizeof(game->info.category) - 1);
    }
    if (tags) {
        strncpy(game->info.tags, tags, sizeof(game->info.tags) - 1);
    }
    game->info.num_signatures = 0;
    
    /* Allocate signature array */
    game->signatures_capacity = 16;
    game->signatures = calloc(game->signatures_capacity, sizeof(signature_entry_t));
    if (game->signatures == NULL) {
        set_error(db, "Failed to allocate signatures");
        return -1;
    }
    
    db->header.num_games++;
    db->dirty = 1;
    
    printf("[vidcom] Added game: %s (ID: %d)\n", name, id);
    
    return id;
}

int vidcom_feature_db_add_signature(
    vidcom_feature_db_t* db,
    int game_id,
    const vidcom_features_t* features
) {
    if (db == NULL || features == NULL || features->data == NULL) return -1;
    
    if (game_id < 0 || game_id >= (int)db->header.num_games) {
        set_error(db, "Invalid game ID");
        return -1;
    }
    
    game_data_t* game = &db->games[game_id];
    
    /* Check capacity */
    if (game->num_signatures >= game->signatures_capacity) {
        int new_cap = game->signatures_capacity * 2;
        signature_entry_t* new_sigs = realloc(game->signatures, 
                                               new_cap * sizeof(signature_entry_t));
        if (new_sigs == NULL) {
            set_error(db, "Failed to expand signatures");
            return -1;
        }
        game->signatures = new_sigs;
        game->signatures_capacity = new_cap;
    }
    
    /* Update feature dimension if needed */
    if (features->length > 0 && features->length <= MAX_FEATURE_DIM) {
        if (db->header.feature_dim == 0) {
            db->header.feature_dim = features->length;
        } else if (db->header.feature_dim != features->length) {
            set_error(db, "Feature dimension mismatch");
            return -1;
        }
    }
    
    /* Store signature */
    signature_entry_t* sig = &game->signatures[game->num_signatures];
    sig->game_id = game_id;
    
    size_t copy_len = features->length;
    if (copy_len > MAX_FEATURE_DIM) copy_len = MAX_FEATURE_DIM;
    memcpy(sig->features, features->data, copy_len * sizeof(float));
    
    game->num_signatures++;
    game->info.num_signatures++;
    db->dirty = 1;
    
    return 0;
}

/*
 * Compute cosine similarity between query and stored signature
 */
static float compute_similarity(
    const float* query,
    const float* stored,
    size_t dim
) {
    double dot = 0, norm_q = 0, norm_s = 0;
    
    for (size_t i = 0; i < dim; i++) {
        dot += query[i] * stored[i];
        norm_q += query[i] * query[i];
        norm_s += stored[i] * stored[i];
    }
    
    if (norm_q == 0 || norm_s == 0) return 0;
    
    return (float)(dot / (sqrt(norm_q) * sqrt(norm_s)));
}

int vidcom_feature_db_match(
    vidcom_feature_db_t* db,
    const vidcom_features_t* features,
    vidcom_match_result_t* results,
    int max_results
) {
    if (db == NULL || features == NULL || results == NULL || max_results <= 0) {
        return -1;
    }
    
    if (features->length != db->header.feature_dim) {
        set_error(db, "Feature dimension mismatch");
        return -1;
    }
    
    /* Find best match for each game */
    typedef struct {
        int game_id;
        float best_sim;
        float avg_sim;
        int match_count;
    } game_score_t;
    
    game_score_t* scores = calloc(db->header.num_games, sizeof(game_score_t));
    if (scores == NULL) return -1;
    
    for (uint32_t g = 0; g < db->header.num_games; g++) {
        scores[g].game_id = g;
        scores[g].best_sim = -1;
        
        game_data_t* game = &db->games[g];
        float sum_sim = 0;
        
        for (int s = 0; s < game->num_signatures; s++) {
            float sim = compute_similarity(
                features->data,
                game->signatures[s].features,
                db->header.feature_dim
            );
            
            if (sim > scores[g].best_sim) {
                scores[g].best_sim = sim;
            }
            sum_sim += sim;
            scores[g].match_count++;
        }
        
        if (scores[g].match_count > 0) {
            scores[g].avg_sim = sum_sim / scores[g].match_count;
        }
    }
    
    /* Sort by best similarity (simple insertion sort for small N) */
    for (uint32_t i = 1; i < db->header.num_games; i++) {
        game_score_t tmp = scores[i];
        int j = i - 1;
        while (j >= 0 && scores[j].best_sim < tmp.best_sim) {
            scores[j + 1] = scores[j];
            j--;
        }
        scores[j + 1] = tmp;
    }
    
    /* Build results */
    int num_results = 0;
    for (int i = 0; i < max_results && i < (int)db->header.num_games; i++) {
        if (scores[i].best_sim < 0) break;
        
        results[num_results].game = db->games[scores[i].game_id].info;
        results[num_results].similarity = scores[i].best_sim;
        results[num_results].confidence = scores[i].avg_sim;
        num_results++;
    }
    
    free(scores);
    return num_results;
}

int vidcom_feature_db_get_game(
    vidcom_feature_db_t* db,
    int game_id,
    vidcom_game_entry_t* game
) {
    if (db == NULL || game == NULL) return -1;
    
    if (game_id < 0 || game_id >= (int)db->header.num_games) {
        return -1;
    }
    
    *game = db->games[game_id].info;
    return 0;
}

int vidcom_feature_db_list_games(
    vidcom_feature_db_t* db,
    vidcom_game_entry_t* games,
    int max_games
) {
    if (db == NULL || games == NULL) return -1;
    
    int count = (int)db->header.num_games;
    if (count > max_games) count = max_games;
    
    for (int i = 0; i < count; i++) {
        games[i] = db->games[i].info;
    }
    
    return count;
}

int vidcom_feature_db_delete_game(vidcom_feature_db_t* db, int game_id) {
    if (db == NULL) return -1;
    
    if (game_id < 0 || game_id >= (int)db->header.num_games) {
        return -1;
    }
    
    /* Free signatures */
    if (db->games[game_id].signatures) {
        free(db->games[game_id].signatures);
    }
    
    /* Shift remaining games */
    for (uint32_t i = game_id; i < db->header.num_games - 1; i++) {
        db->games[i] = db->games[i + 1];
        db->games[i].info.id = i;  /* Update IDs */
    }
    
    db->header.num_games--;
    db->dirty = 1;
    
    return 0;
}

int vidcom_feature_db_stats(
    vidcom_feature_db_t* db,
    int* num_games,
    int* num_signatures,
    int* feature_dim
) {
    if (db == NULL) return -1;
    
    if (num_games) *num_games = db->header.num_games;
    if (feature_dim) *feature_dim = db->header.feature_dim;
    
    if (num_signatures) {
        int total = 0;
        for (uint32_t i = 0; i < db->header.num_games; i++) {
            total += db->games[i].num_signatures;
        }
        *num_signatures = total;
    }
    
    return 0;
}

int vidcom_feature_db_import_dir(
    vidcom_feature_db_t* db,
    void* classifier,
    const char* dir_path,
    const char* category
) {
    /* TODO: Implement directory import */
    (void)db;
    (void)classifier;
    (void)dir_path;
    (void)category;
    set_error(db, "Directory import not yet implemented");
    return -1;
}

const char* vidcom_feature_db_get_error(vidcom_feature_db_t* db) {
    return (db != NULL) ? db->error_msg : "Invalid database";
}

/*
 * Save database to file
 */
static int save_database(vidcom_feature_db_t* db) {
    FILE* f = fopen(db->path, "wb");
    if (f == NULL) {
        set_error(db, "Failed to open database for writing");
        return -1;
    }
    
    /* Write header */
    fwrite(&db->header, sizeof(db_header_t), 1, f);
    
    /* Write games */
    for (uint32_t i = 0; i < db->header.num_games; i++) {
        /* Write game info */
        fwrite(&db->games[i].info, sizeof(vidcom_game_entry_t), 1, f);
        
        /* Write signature count and data */
        int32_t num_sigs = db->games[i].num_signatures;
        fwrite(&num_sigs, sizeof(int32_t), 1, f);
        
        for (int s = 0; s < num_sigs; s++) {
            fwrite(db->games[i].signatures[s].features, 
                   sizeof(float), db->header.feature_dim, f);
        }
    }
    
    fclose(f);
    db->dirty = 0;
    
    printf("[vidcom] Database saved: %s\n", db->path);
    return 0;
}

/*
 * Load database from file
 */
static int load_database(vidcom_feature_db_t* db) {
    FILE* f = fopen(db->path, "rb");
    if (f == NULL) {
        return -1;
    }
    
    /* Read header */
    db_header_t header;
    if (fread(&header, sizeof(db_header_t), 1, f) != 1) {
        fclose(f);
        return -1;
    }
    
    /* Verify magic */
    if (header.magic != DB_MAGIC) {
        set_error(db, "Invalid database file");
        fclose(f);
        return -1;
    }
    
    db->header = header;
    
    /* Expand games array if needed */
    if (header.num_games > (uint32_t)db->games_capacity) {
        db->games_capacity = header.num_games + 16;
        db->games = realloc(db->games, db->games_capacity * sizeof(game_data_t));
        if (db->games == NULL) {
            fclose(f);
            return -1;
        }
    }
    
    /* Read games */
    for (uint32_t i = 0; i < header.num_games; i++) {
        /* Read game info */
        if (fread(&db->games[i].info, sizeof(vidcom_game_entry_t), 1, f) != 1) {
            fclose(f);
            return -1;
        }
        
        /* Read signature count */
        int32_t num_sigs;
        if (fread(&num_sigs, sizeof(int32_t), 1, f) != 1) {
            fclose(f);
            return -1;
        }
        
        db->games[i].num_signatures = num_sigs;
        db->games[i].signatures_capacity = num_sigs + 16;
        db->games[i].signatures = calloc(db->games[i].signatures_capacity, 
                                          sizeof(signature_entry_t));
        
        /* Read signatures */
        for (int s = 0; s < num_sigs; s++) {
            db->games[i].signatures[s].game_id = i;
            if (fread(db->games[i].signatures[s].features,
                     sizeof(float), header.feature_dim, f) != header.feature_dim) {
                fclose(f);
                return -1;
            }
        }
    }
    
    fclose(f);
    db->dirty = 0;
    
    return 0;
}
