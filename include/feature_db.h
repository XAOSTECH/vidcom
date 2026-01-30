/*
 * feature_db.h - Game signature database for similarity matching
 * 
 * Stores feature embeddings from known games and provides
 * fast similarity search for game identification.
 */

#ifndef VIDCOM_FEATURE_DB_H
#define VIDCOM_FEATURE_DB_H

#include <stddef.h>
#include <stdint.h>
#include "classifier.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque database handle */
typedef struct vidcom_feature_db vidcom_feature_db_t;

/* Game entry */
typedef struct {
    int id;                     /* Unique game ID */
    char name[256];             /* Game name */
    char category[64];          /* Category (FPS, RPG, etc.) */
    char tags[512];             /* Comma-separated tags */
    int num_signatures;         /* Number of reference signatures */
} vidcom_game_entry_t;

/* Match result */
typedef struct {
    vidcom_game_entry_t game;   /* Matched game info */
    float similarity;           /* Similarity score (0.0-1.0) */
    float confidence;           /* Confidence score (0.0-1.0) */
} vidcom_match_result_t;

/*
 * Create or open feature database
 * 
 * @param db_path Path to database file (will be created if doesn't exist)
 * @return Database handle, or NULL on error
 */
vidcom_feature_db_t* vidcom_feature_db_open(const char* db_path);

/*
 * Close database and free resources
 */
void vidcom_feature_db_close(vidcom_feature_db_t* db);

/*
 * Add or update game entry
 * 
 * @param db Database handle
 * @param name Game name
 * @param category Game category
 * @param tags Comma-separated tags
 * @return Game ID on success, negative on error
 */
int vidcom_feature_db_add_game(
    vidcom_feature_db_t* db,
    const char* name,
    const char* category,
    const char* tags
);

/*
 * Add reference signature for a game
 * 
 * @param db Database handle
 * @param game_id Game ID
 * @param features Feature vector from classifier
 * @return 0 on success, negative on error
 */
int vidcom_feature_db_add_signature(
    vidcom_feature_db_t* db,
    int game_id,
    const vidcom_features_t* features
);

/*
 * Find best matching game for features
 * 
 * @param db Database handle
 * @param features Query feature vector
 * @param results Output array for matches
 * @param max_results Maximum results to return
 * @return Number of results, or negative on error
 */
int vidcom_feature_db_match(
    vidcom_feature_db_t* db,
    const vidcom_features_t* features,
    vidcom_match_result_t* results,
    int max_results
);

/*
 * Get game by ID
 * 
 * @param db Database handle
 * @param game_id Game ID
 * @param game Output game entry
 * @return 0 on success, negative if not found
 */
int vidcom_feature_db_get_game(
    vidcom_feature_db_t* db,
    int game_id,
    vidcom_game_entry_t* game
);

/*
 * List all games in database
 * 
 * @param db Database handle
 * @param games Output array for game entries
 * @param max_games Maximum games to return
 * @return Number of games, or negative on error
 */
int vidcom_feature_db_list_games(
    vidcom_feature_db_t* db,
    vidcom_game_entry_t* games,
    int max_games
);

/*
 * Delete game and all its signatures
 * 
 * @param db Database handle
 * @param game_id Game ID
 * @return 0 on success, negative on error
 */
int vidcom_feature_db_delete_game(vidcom_feature_db_t* db, int game_id);

/*
 * Get database statistics
 * 
 * @param db Database handle
 * @param num_games Output: number of games
 * @param num_signatures Output: total signatures
 * @param feature_dim Output: feature vector dimension
 * @return 0 on success, negative on error
 */
int vidcom_feature_db_stats(
    vidcom_feature_db_t* db,
    int* num_games,
    int* num_signatures,
    int* feature_dim
);

/*
 * Import signatures from image directory
 * 
 * Structure expected:
 *   dir/
 *     GameName1/
 *       screenshot1.jpg
 *       screenshot2.jpg
 *     GameName2/
 *       ...
 * 
 * @param db Database handle
 * @param classifier Classifier for feature extraction
 * @param dir_path Path to image directory
 * @param category Default category for imported games
 * @return Number of signatures imported, or negative on error
 */
int vidcom_feature_db_import_dir(
    vidcom_feature_db_t* db,
    void* classifier,  /* vidcom_classifier_t* - avoid circular include */
    const char* dir_path,
    const char* category
);

/*
 * Get last error message
 */
const char* vidcom_feature_db_get_error(vidcom_feature_db_t* db);

#ifdef __cplusplus
}
#endif

#endif /* VIDCOM_FEATURE_DB_H */
