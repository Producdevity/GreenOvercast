#include "memoryAdapter.h"
#include "ve.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

enum {
    CEDAR_WAIT_VE_DE = 0x102,
    CEDAR_RESET_VE = 0x104,
    CEDAR_SET_VE_FREQ = 0x107,
    CEDAR_ENGINE_REQ = 0x206,
    CEDAR_ENGINE_REL = 0x207,
    CEDAR_GET_IOMMU_ADDR = 0x502,
    CEDAR_FREE_IOMMU_ADDR = 0x503,
};

enum {
    ION_IOC_ALLOC = 0xc0204900,
    ION_IOC_FREE = 0xc0044901,
    ION_IOC_MAP = 0xc0084902,
    ION_IOC_SUNXI_FLUSH_RANGE = 5,
};

enum {
    VE_MODE_MASK = 0x0f,
    VE_DDR_MODE_MASK = 3u << 16,
    VE_DDR_MODE_32BIT_DDR3 = 3u << 16,
    VE_REC_WR_MODE = 1u << 20,
    VE_WIDE_PICTURE_MODE = 1u << 21,
};

typedef struct {
    size_t len;
    size_t align;
    unsigned int heap_id_mask;
    unsigned int flags;
    int handle;
} IonAllocation;

typedef struct {
    int handle;
} IonHandle;

typedef struct {
    int handle;
    int fd;
} IonFd;

typedef struct {
    int64_t start;
    int64_t end;
} IonCacheRange;

typedef struct {
    int fd;
    unsigned int iommu_addr;
} CedarIommu;

typedef struct Allocation {
    void* address;
    size_t size;
    unsigned int iommu_address;
    int handle;
    int dma_fd;
    struct Allocation* next;
} Allocation;

static pthread_mutex_t g_state_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_ve_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_memory_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_cedar_fd = -1;
static int g_ion_fd = -1;
static volatile unsigned int* g_registers;
static int g_references;
static Allocation* g_allocations;
static int g_reported_cache_flush_error;

static void release_allocation(Allocation* allocation) {
    CedarIommu iommu = {.fd = allocation->dma_fd, .iommu_addr = allocation->iommu_address};
    ioctl(g_cedar_fd, CEDAR_FREE_IOMMU_ADDR, &iommu);
    munmap(allocation->address, allocation->size);
    close(allocation->dma_fd);
    IonHandle handle = {.handle = allocation->handle};
    ioctl(g_ion_fd, ION_IOC_FREE, &handle);
    free(allocation);
}

int VeInitialize(void) {
    pthread_mutex_lock(&g_state_lock);
    if (g_references > 0) {
        ++g_references;
        pthread_mutex_unlock(&g_state_lock);
        return 0;
    }

    g_cedar_fd = open("/dev/cedar_dev", O_RDWR | O_CLOEXEC);
    g_ion_fd = open("/dev/ion", O_RDWR | O_CLOEXEC);
    if (g_cedar_fd < 0 || g_ion_fd < 0)
        goto fail;
    if (ioctl(g_cedar_fd, CEDAR_ENGINE_REQ, 0) < 0)
        goto fail;
    g_registers = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, g_cedar_fd, 0);
    if (g_registers == MAP_FAILED) {
        g_registers = NULL;
        ioctl(g_cedar_fd, CEDAR_ENGINE_REL, 0);
        goto fail;
    }
    if (ioctl(g_cedar_fd, CEDAR_SET_VE_FREQ, 624) < 0 || ioctl(g_cedar_fd, CEDAR_RESET_VE, 0) < 0) {
        munmap((void*)g_registers, 0x1000);
        g_registers = NULL;
        ioctl(g_cedar_fd, CEDAR_ENGINE_REL, 0);
        goto fail;
    }
    VeSetDramType();
    g_registers[0] = (g_registers[0] & ~VE_MODE_MASK) | 7u;
    g_references = 1;
    pthread_mutex_unlock(&g_state_lock);
    return 0;

fail:
    if (g_ion_fd >= 0)
        close(g_ion_fd);
    if (g_cedar_fd >= 0)
        close(g_cedar_fd);
    g_ion_fd = -1;
    g_cedar_fd = -1;
    pthread_mutex_unlock(&g_state_lock);
    return -1;
}

void VeRelease(void) {
    pthread_mutex_lock(&g_state_lock);
    if (g_references <= 0 || --g_references > 0) {
        pthread_mutex_unlock(&g_state_lock);
        return;
    }
    while (g_allocations) {
        Allocation* allocation = g_allocations;
        g_allocations = allocation->next;
        release_allocation(allocation);
    }
    if (g_registers)
        munmap((void*)g_registers, 0x1000);
    ioctl(g_cedar_fd, CEDAR_ENGINE_REL, 0);
    close(g_ion_fd);
    close(g_cedar_fd);
    g_registers = NULL;
    g_ion_fd = -1;
    g_cedar_fd = -1;
    pthread_mutex_unlock(&g_state_lock);
}

int VeLock(void) {
    return pthread_mutex_lock(&g_ve_lock);
}
void VeUnLock(void) {
    pthread_mutex_unlock(&g_ve_lock);
}
int VeEncoderLock(void) {
    return VeLock();
}
void VeEncoderUnLock(void) {
    VeUnLock();
}
void VeSetDramType(void) {
    if (g_registers) {
        unsigned int mode = g_registers[0];
        mode &= ~VE_DDR_MODE_MASK;
        mode |= VE_DDR_MODE_32BIT_DDR3 | VE_REC_WR_MODE;
        g_registers[0] = mode;
    }
}
void VeReset(void) {
    if (ioctl(g_cedar_fd, CEDAR_RESET_VE, 0) >= 0)
        VeSetDramType();
}
void VeResetDecoder(void) {
    VeReset();
}
void VeResetEncoder(void) {
    VeReset();
}
int VeWaitInterrupt(void) {
    return ioctl(g_cedar_fd, CEDAR_WAIT_VE_DE, 1) > 0 ? 0 : -1;
}
int VeWaitEncoderInterrupt(void) {
    return VeWaitInterrupt();
}
void* VeGetRegisterBaseAddress(void) {
    return (void*)g_registers;
}
unsigned int VeGetIcVersion(void) {
    return 0x3301;
}
int VeGetDramType(void) {
    return DDRTYPE_DDR3_32BITS;
}
int VeSetSpeed(int speed_mhz) {
    return ioctl(g_cedar_fd, CEDAR_SET_VE_FREQ, speed_mhz);
}
void VeEnableEncoder(void) {
}
void VeDisableEncoder(void) {
}
void VeDisableDecoder(void) {
    if (g_registers)
        g_registers[0] = (g_registers[0] & ~VE_MODE_MASK) | 7u;
}
void VeEnableDecoder(enum VeRegionE region) {
    if (g_registers)
        g_registers[0] = (g_registers[0] & ~VE_MODE_MASK) | (region == VE_REGION_1 ? 1u : 0u);
}
void VeDecoderWidthMode(int width) {
    if (!g_registers)
        return;
    if (width >= 2048)
        g_registers[0] |= VE_WIDE_PICTURE_MODE;
    else
        g_registers[0] &= ~VE_WIDE_PICTURE_MODE;
}
void VeInitEncoderPerformance(int mode) {
    (void)mode;
}
void VeUninitEncoderPerformance(int mode) {
    (void)mode;
}

int MemAdapterOpen(void) {
    return 0;
}
void MemAdapterClose(void) {
}

void* MemAdapterPalloc(int size) {
    if (size <= 0 || g_ion_fd < 0 || g_cedar_fd < 0)
        return NULL;
    size_t aligned = ((size_t)size + 4095u) & ~4095u;
    IonAllocation ion = {
        .len = aligned,
        .align = 4096,
        .heap_id_mask = (1u << 0) | (1u << 2),
        .flags = 3,
        .handle = -1,
    };
    if (ioctl(g_ion_fd, ION_IOC_ALLOC, &ion) < 0)
        return NULL;
    IonFd exported = {.handle = ion.handle, .fd = -1};
    if (ioctl(g_ion_fd, ION_IOC_MAP, &exported) < 0)
        goto fail_handle;
    void* address = mmap(NULL, aligned, PROT_READ | PROT_WRITE, MAP_SHARED, exported.fd, 0);
    if (address == MAP_FAILED)
        goto fail_fd;
    CedarIommu iommu = {.fd = exported.fd};
    if (ioctl(g_cedar_fd, CEDAR_GET_IOMMU_ADDR, &iommu) < 0)
        goto fail_map;
    Allocation* allocation = calloc(1, sizeof(*allocation));
    if (!allocation)
        goto fail_iommu;
    allocation->address = address;
    allocation->size = aligned;
    allocation->iommu_address = iommu.iommu_addr;
    allocation->handle = ion.handle;
    allocation->dma_fd = exported.fd;
    pthread_mutex_lock(&g_memory_lock);
    allocation->next = g_allocations;
    g_allocations = allocation;
    pthread_mutex_unlock(&g_memory_lock);
    return address;

fail_iommu:
    ioctl(g_cedar_fd, CEDAR_FREE_IOMMU_ADDR, &iommu);
fail_map:
    munmap(address, aligned);
fail_fd:
    close(exported.fd);
fail_handle: {
    IonHandle handle = {.handle = ion.handle};
    ioctl(g_ion_fd, ION_IOC_FREE, &handle);
    return NULL;
}
}

int MemAdapterPfree(void* memory) {
    if (!memory)
        return 0;
    pthread_mutex_lock(&g_memory_lock);
    Allocation** link = &g_allocations;
    while (*link && (*link)->address != memory)
        link = &(*link)->next;
    Allocation* allocation = *link;
    if (allocation)
        *link = allocation->next;
    pthread_mutex_unlock(&g_memory_lock);
    if (!allocation)
        return -1;
    release_allocation(allocation);
    return 0;
}

void MemAdapterFlushCache(void* memory, int size) {
    if (!memory || size <= 0 || g_ion_fd < 0)
        return;
    IonCacheRange range = {
        .start = (int64_t)(uintptr_t)memory,
        .end = (int64_t)((uintptr_t)memory + (size_t)size),
    };
    if (ioctl(g_ion_fd, ION_IOC_SUNXI_FLUSH_RANGE, &range) < 0 && !g_reported_cache_flush_error) {
        g_reported_cache_flush_error = 1;
        fprintf(stderr, "Cedar cache flush failed: errno=%d\n", errno);
    }
}

void* MemAdapterGetPhysicAddress(void* memory) {
    uintptr_t requested = (uintptr_t)memory;
    pthread_mutex_lock(&g_memory_lock);
    for (Allocation* allocation = g_allocations; allocation; allocation = allocation->next) {
        uintptr_t start = (uintptr_t)allocation->address;
        if (requested >= start && requested < start + allocation->size) {
            uintptr_t result = allocation->iommu_address + requested - start;
            pthread_mutex_unlock(&g_memory_lock);
            return (void*)result;
        }
    }
    pthread_mutex_unlock(&g_memory_lock);
    return NULL;
}

void* MemAdapterGetVirtualAddress(void* physical) {
    uintptr_t requested = (uintptr_t)physical;
    pthread_mutex_lock(&g_memory_lock);
    for (Allocation* allocation = g_allocations; allocation; allocation = allocation->next) {
        uintptr_t start = allocation->iommu_address;
        if (requested >= start && requested < start + allocation->size) {
            void* result = (uint8_t*)allocation->address + requested - start;
            pthread_mutex_unlock(&g_memory_lock);
            return result;
        }
    }
    pthread_mutex_unlock(&g_memory_lock);
    return NULL;
}

void* MemAdapterGetPhysicAddressCpu(void* memory) {
    return MemAdapterGetPhysicAddress(memory);
}
void* MemAdapterGetVirtualAddressCpu(void* physical) {
    return MemAdapterGetVirtualAddress(physical);
}
