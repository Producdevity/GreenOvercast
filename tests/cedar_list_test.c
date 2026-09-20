#include <CdxList.h>

struct Entry {
    CdxListNodeT node;
    int value;
};

struct PaddedEntry {
    int value;
    CdxListNodeT node;
};

int main(void) {
    CdxListT list;
    CdxListInit(&list);
    struct Entry* current;
    int total = 0;
    CdxListForEachEntry(current, &list, node) {
        total += current->value;
    }
    if (total != 0 || !CdxListEmpty(&list))
        return 1;

    struct Entry entry = {.value = 7};
    CdxListAdd(&entry.node, &list);
    CdxListForEachEntry(current, &list, node) {
        total += current->value;
    }
    if (total != 7 || CdxListEntry(&entry.node, struct Entry, node) != &entry)
        return 1;
    CdxListDel(&entry.node);
    if (!CdxListEmpty(&list))
        return 1;

    struct PaddedEntry padded = {.value = 3};
    return CdxListEntry(&padded.node, struct PaddedEntry, node) != &padded;
}
