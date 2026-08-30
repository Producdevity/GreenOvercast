#ifndef GREENOVERCAST_CATALOG_PARSER_H
#define GREENOVERCAST_CATALOG_PARSER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    GO_CATALOG_TITLE_ID_CAPACITY = 128,
    GO_CATALOG_PRODUCT_ID_CAPACITY = 64,
    GO_CATALOG_NAME_CAPACITY = 192,
    GO_CATALOG_ARTWORK_URL_CAPACITY = 768,
};

typedef struct {
    char title_id[GO_CATALOG_TITLE_ID_CAPACITY];
    char product_id[GO_CATALOG_PRODUCT_ID_CAPACITY];
    char name[GO_CATALOG_NAME_CAPACITY];
    char artwork_url[GO_CATALOG_ARTWORK_URL_CAPACITY];
} GoCatalogTitle;

// Display name for a title, falling back to its id when no name is set.
static inline const char* title_name(const GoCatalogTitle* title) {
    return title->name[0] ? title->name : title->title_id;
}

int go_catalog_parse_titles(const char* data, size_t length, GoCatalogTitle* titles,
                            size_t capacity);
int go_catalog_apply_metadata(const char* data, size_t length, GoCatalogTitle* titles,
                              size_t count);

#ifdef __cplusplus
}
#endif

#endif
