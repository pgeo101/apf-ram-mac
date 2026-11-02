// Hardware-free protocol regression tests. The three substituted IOKit calls
// below use in-memory fixtures; this program never opens a USB device.
#include <IOKit/hid/IOHIDManager.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static CFTypeRef mock_property(IOHIDDeviceRef, CFStringRef);
static IOReturn mock_get(IOHIDDeviceRef, IOHIDReportType, CFIndex, uint8_t *, CFIndex *);
static IOReturn mock_set(IOHIDDeviceRef, IOHIDReportType, CFIndex, const uint8_t *, CFIndex);

#define IOHIDDeviceGetProperty mock_property
#define IOHIDDeviceGetReport mock_get
#define IOHIDDeviceSetReport mock_set
#include "../Sources/APFHID.c"
#undef IOHIDDeviceGetProperty
#undef IOHIDDeviceGetReport
#undef IOHIDDeviceSetReport

typedef struct {
    uint8_t id, bytes[1024];
    size_t length;
    IOReturn result;
} Packet;

static Packet reads[32], writes[32];
static size_t read_count, read_index, write_count, expected_size;
static IOReturn set_result;
static CFDataRef descriptor_fixture;

static void reset(size_t report_size) {
    memset(reads, 0, sizeof(reads));
    memset(writes, 0, sizeof(writes));
    read_count = read_index = write_count = 0;
    expected_size = report_size;
    set_result = kIOReturnSuccess;
}

static Packet *enqueue(uint8_t id, size_t length) {
    assert(read_count < 32);
    Packet *p = &reads[read_count++];
    p->id = id;
    p->length = length;
    p->result = kIOReturnSuccess;
    return p;
}

static CFTypeRef mock_property(IOHIDDeviceRef hid, CFStringRef key) {
    (void)hid;
    assert(CFEqual(key, CFSTR(kIOHIDReportDescriptorKey)));
    return descriptor_fixture;
}

static IOReturn mock_get(IOHIDDeviceRef hid, IOHIDReportType type, CFIndex id,
                         uint8_t *bytes, CFIndex *length) {
    (void)hid;
    assert(type == kIOHIDReportTypeFeature);
    assert((size_t)*length == expected_size);
    assert(read_index < read_count);
    Packet *p = &reads[read_index++];
    assert(id == p->id && bytes[0] == p->id);
    for (size_t i = 1; i < expected_size; ++i) assert(bytes[i] == 0);
    if (p->result != kIOReturnSuccess) return p->result;
    assert(p->length <= (size_t)*length);
    memcpy(bytes, p->bytes, p->length);
    *length = (CFIndex)p->length;
    return kIOReturnSuccess;
}

static IOReturn mock_set(IOHIDDeviceRef hid, IOHIDReportType type, CFIndex id,
                         const uint8_t *bytes, CFIndex length) {
    (void)hid;
    assert(type == kIOHIDReportTypeFeature);
    assert((size_t)length == expected_size);
    assert(write_count < 32);
    Packet *p = &writes[write_count++];
    p->id = (uint8_t)id;
    p->length = (size_t)length;
    memcpy(p->bytes, bytes, p->length);
    assert(p->bytes[0] == id);
    return set_result;
}

static size_t parse_descriptor(const uint8_t *bytes, size_t size) {
    descriptor_fixture = CFDataCreate(NULL, bytes, (CFIndex)size);
    size_t result = descriptor_size(NULL);
    CFRelease(descriptor_fixture);
    descriptor_fixture = NULL;
    return result;
}

static void test_descriptor(void) {
    // A numbered report with 63 payload bytes occupies 64 bytes on Windows.
    const uint8_t numbered[] = {0x85,0x14,0x75,8,0x95,63,0xb1,2};
    assert(parse_descriptor(numbered, sizeof(numbered)) == 64);
    const uint8_t payload64[] = {0x85,0x14,0x75,8,0x95,64,0xb1,2};
    assert(parse_descriptor(payload64, sizeof(payload64)) == 65);
    const uint8_t split[] = {0x85,0x14,0x75,8,0x95,32,0xb1,2,0x95,31,0xb1,2};
    assert(parse_descriptor(split, sizeof(split)) == 64);
    const uint8_t push_pop[] = {
        0x85,0x14,0x75,8,0x95,31,0xb1,2,
        0xa4,0x85,0x15,0x95,1,0xb1,2,0xb4,0x95,32,0xb1,2
    };
    assert(parse_descriptor(push_pop, sizeof(push_pop)) == 64);
    const uint8_t bit_fields[] = {0x85,0x14,0x75,1,0x96,0xf8,1,0xb1,2};
    assert(parse_descriptor(bit_fields, sizeof(bit_fields)) == 64);
    const uint8_t long_item[] = {0xfe,2,0x80,1,2,0x85,0x14,0x75,8,0x95,63,0xb1,2};
    assert(parse_descriptor(long_item, sizeof(long_item)) == 64);
    const uint8_t bad_id[] = {0x85,0,0x75,8,0x95,64,0xb1,2};
    assert(parse_descriptor(bad_id, sizeof(bad_id)) == 0);
    const uint8_t bad_pop[] = {0xb4};
    assert(parse_descriptor(bad_pop, sizeof(bad_pop)) == 0);
    const uint8_t truncated_long[] = {0x85,0x14,0x75,8,0x95,63,0xb1,2,0xfe,2,0x80,1};
    assert(parse_descriptor(truncated_long, sizeof(truncated_long)) == 0);
    assert(parse_descriptor(numbered, sizeof(numbered)-1) == 0);
    assert(descriptor_size(NULL) == 0);
}

static void test_mapping(void) {
    assert(apf_wire_sector(0) == 0);
    assert(apf_wire_sector(255) == 255);
    assert(apf_wire_sector(256) == 257);
    assert(apf_wire_sector(510) == 511);
    assert(apf_wire_sector(511) == 513);
    assert(apf_wire_sector(766) == 769);
    assert(apf_wire_sector(0xff000001) == UINT32_MAX);
    assert(apf_wire_sector(UINT32_MAX) == UINT32_MAX);
    // Independent incremental formulation: after the first 256 sectors,
    // omit every physical sector whose low byte is zero.
    uint32_t wire = 0;
    for (uint32_t logical = 0; logical < 16384; ++logical) {
        if (wire != 0 && (wire & 255) == 0) ++wire;
        assert(apf_wire_sector(logical) == wire++);
    }
}

static void test_identity(size_t size) {
    reset(size);
    APFDevice dev = {.report_size=size};
    char error[256] = {0};
    uint8_t identity[63] = {0};
    Packet *p = enqueue(0x16, 3);
    p->bytes[0] = 1; p->bytes[1] = 2; p->bytes[2] = 0x20;
    assert(apf_identity(&dev, identity, sizeof(identity), error, sizeof(error)));
    assert(identity[0] == 1 && identity[1] == 2 && identity[2] == 0x20);
    for (size_t i = 3; i < sizeof(identity); ++i) assert(identity[i] == 0);
    assert(read_index == 1 && write_count == 0);
    assert(!apf_identity(&dev, identity, 64, error, sizeof(error)));
    assert(read_index == 1);
}

static void test_reads(size_t size, uint32_t bps) {
    reset(size);
    APFDevice dev = {.report_size=size};
    char error[256] = {0};
    uint8_t bytes[512] = {0};
    for (uint32_t offset = 0; offset < bps; offset += 64) {
        Packet *p = enqueue(0x14, size);
        for (unsigned j = 0; j < 64; ++j) p->bytes[j] = (uint8_t)(offset / 64 * 17 + j);
        if (size > 64) p->bytes[64] = 0xff; // ignored, never prepended or copied
    }
    assert(apf_read_sector(&dev, 511, bps, bytes, error, sizeof(error)));
    assert(write_count == 1 && read_index == bps / 64);
    Packet *command = &writes[0];
    assert(command->id == 0x14 && command->bytes[1] == 1);
    assert(command->bytes[2] == 2 && command->bytes[3] == 1);
    for (size_t i = 4; i < size; ++i) assert(command->bytes[i] == 0);
    for (uint32_t i = 0; i < bps; ++i) assert(bytes[i] == (uint8_t)(i / 64 * 17 + i % 64));
}

static void test_writes(size_t size, uint32_t bps) {
    reset(size);
    APFDevice dev = {.report_size=size};
    char error[256] = {0};
    uint8_t bytes[512];
    for (uint32_t i = 0; i < bps; ++i) bytes[i] = (uint8_t)(i * 37 + 11);
    size_t chunks = (bps + 59) / 60;
    for (size_t i = 0; i < chunks; ++i) enqueue(0x15, size);
    assert(apf_write_sector(&dev, 256, bps, bytes, error, sizeof(error)));
    assert(write_count == chunks && read_index == chunks);
    for (size_t i = 0; i < chunks; ++i) {
        Packet *p = &writes[i];
        assert(p->id == 0x14 && p->bytes[1] == (i ? 3 : 2));
        assert(p->bytes[2] == 1 && p->bytes[3] == 1);
        for (size_t j = 0; j < 60; ++j) {
            size_t index = i * 60 + j;
            assert(p->bytes[4+j] == (index < bps ? bytes[index] : 0));
        }
        for (size_t j = 64; j < size; ++j) assert(p->bytes[j] == 0);
    }
}

static void test_bootstrap(size_t size, uint32_t bps) {
    reset(size);
    APFDevice dev = {.report_size=size};
    char error[256] = {0};
    uint8_t bytes[512] = {0};
    for (uint32_t offset = 0; offset < bps; offset += 64) {
        Packet *p = enqueue(0x14, size);
        memset(p->bytes, (int)(offset / 64 + 1), 64);
        if (offset == 0) { p->bytes[11] = bps & 255; p->bytes[12] = bps >> 8; }
    }
    assert(apf_read_sector(&dev, 0, 0, bytes, error, sizeof(error)));
    assert(write_count == 1 && read_index == bps / 64);
    assert(writes[0].bytes[2] == 0 && writes[0].bytes[3] == 0);
    assert(bytes[11] == (bps & 255) && bytes[12] == bps >> 8);
    assert(bytes[bps-1] == bps / 64);
}

static void test_failures(void) {
    APFDevice dev = {.report_size=65};
    char error[256] = {0};
    uint8_t bytes[512] = {0};
    reset(65);
    assert(!apf_read_sector(&dev, 0, 129, bytes, error, sizeof(error)));
    assert(!apf_read_sector(&dev, 0, 64, bytes, error, sizeof(error)));
    assert(!apf_read_sector(&dev, 65535, 512, bytes, error, sizeof(error)));
    assert(!apf_read_sector(&dev, 0xff000001, 512, bytes, error, sizeof(error)));
    assert(!apf_write_sector(&dev, 0xff000001, 512, bytes, error, sizeof(error)));
    assert(!apf_write_sector(&dev, 0, 64, bytes, error, sizeof(error)));
    assert(write_count == 0 && read_index == 0);
    enqueue(0x14, 63);
    assert(!apf_read_sector(&dev, 0, 128, bytes, error, sizeof(error)));
    assert(strstr(error, "Short USB report") != NULL);
    reset(65);
    enqueue(0x16, 2);
    assert(!apf_identity(&dev, bytes, 63, error, sizeof(error)));
    assert(strstr(error, "Short USB report") != NULL);
    reset(65);
    set_result = kIOReturnError;
    assert(!apf_read_sector(&dev, 0, 128, bytes, error, sizeof(error)));
    assert(write_count == 1 && read_index == 0);
    reset(65);
    enqueue(0x16, 65)->result = kIOReturnError;
    assert(!apf_identity(&dev, bytes, 3, error, sizeof(error)));
    reset(65);
    enqueue(0x15, 65)->result = kIOReturnError;
    assert(!apf_write_sector(&dev, 0, 128, bytes, error, sizeof(error)));
    assert(write_count == 1 && read_index == 1);
}

int main(void) {
    test_descriptor();
    test_mapping();
    for (size_t size = 64; size <= 65; ++size) {
        test_identity(size);
        for (uint32_t bps = 128; bps <= 512; bps *= 2) {
            test_bootstrap(size, bps);
            test_reads(size, bps);
            test_writes(size, bps);
        }
    }
    test_failures();
    puts("Protocol tests passed (mock USB only; no hardware access).");
    return 0;
}
