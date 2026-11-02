#include "APFHID.h"
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_error.h>

struct APFDevice { IOHIDManagerRef manager; IOHIDDeviceRef hid; size_t report_size; };

static int failure(char *error, size_t size, const char *operation, IOReturn code) {
    snprintf(error, size, "%s: %s (0x%08x)", operation, mach_error_string(code), code);
    return 0;
}

// Recover the maximum feature length exactly as Windows HidP_GetCaps does.
// The HID report ID is included for numbered reports, even when the firmware's
// GetReport response overwrites that byte with raw card data.
static size_t descriptor_size(IOHIDDeviceRef hid) {
    CFDataRef descriptor = IOHIDDeviceGetProperty(hid, CFSTR(kIOHIDReportDescriptorKey));
    if (!descriptor || CFGetTypeID(descriptor) != CFDataGetTypeID()) return 0;
    const uint8_t *d = CFDataGetBytePtr(descriptor);
    size_t n = CFDataGetLength(descriptor), bits[256] = {0};
    struct { uint32_t size, count, id; } state = {0}, stack[16];
    unsigned depth = 0; int numbered = 0;
    for (size_t p = 0; p < n;) {
        uint8_t prefix = d[p++];
        if (prefix == 0xfe) {
            if (p + 2 > n) return 0;
            size_t len = d[p];
            if (p + 2 + len > n) return 0;
            p += 2 + len;
            continue;
        }
        unsigned len = prefix & 3; if (len == 3) len = 4;
        if (p + len > n) return 0;
        uint32_t value = 0; for (unsigned j=0;j<len;j++) value |= (uint32_t)d[p+j] << (8*j);
        p += len;
        switch (prefix & 0xfc) {
            case 0x74: state.size = value; break;
            case 0x84: if (value > 255 || value == 0) return 0; state.id = value; numbered = 1; break;
            case 0x94: state.count = value; break;
            case 0xa4: if (depth == 16) return 0; stack[depth++] = state; break;
            case 0xb4: if (!depth) return 0; state = stack[--depth]; break;
            case 0xb0:
                if (state.size > 1024 || state.count > 8192) return 0;
                bits[state.id] += state.size * state.count; break;
        }
    }
    size_t maximum = 0;
    for (unsigned i=0;i<256;i++) { size_t s = (bits[i]+7)/8 + (numbered ? 1 : 0); if (s>maximum) maximum=s; }
    return maximum;
}

APFDevice *apf_open(char *error, size_t size) {
    APFDevice *dev = calloc(1, sizeof(*dev));
    if (!dev) { snprintf(error,size,"Out of memory"); return NULL; }
    dev->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vendor=0x16c0, product=0x1771;
    CFNumberRef v=CFNumberCreate(NULL,kCFNumberIntType,&vendor), p=CFNumberCreate(NULL,kCFNumberIntType,&product);
    const void *keys[]={CFSTR(kIOHIDVendorIDKey),CFSTR(kIOHIDProductIDKey)};
    const void *values[]={v,p};
    CFDictionaryRef match=CFDictionaryCreate(NULL,keys,values,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    IOHIDManagerSetDeviceMatching(dev->manager,match);
    CFRelease(match); CFRelease(v); CFRelease(p);
    CFSetRef devices=IOHIDManagerCopyDevices(dev->manager);
    CFIndex count = devices ? CFSetGetCount(devices) : 0;
    if (count != 1) {
        snprintf(error,size,count ? "More than one APF device is connected. Connect just one card." : "No APF-01 detected. Connect the card directly to USB with a data cable, then click Connect.");
        if (devices) CFRelease(devices); apf_close(dev); return NULL;
    }
    const void *item=NULL; CFSetGetValues(devices,&item); dev->hid=(IOHIDDeviceRef)CFRetain(item); CFRelease(devices);
    IOReturn result=IOHIDDeviceOpen(dev->hid,kIOHIDOptionsTypeSeizeDevice);
    if(result!=kIOReturnSuccess) { failure(error,size,"Cannot open APF USB device",result); apf_close(dev); return NULL; }
    dev->report_size=descriptor_size(dev->hid);
    if (dev->report_size<64 || dev->report_size>1024) {
        snprintf(error,size,"Unexpected HID feature report length: %zu",dev->report_size); apf_close(dev); return NULL;
    }
    return dev;
}

void apf_close(APFDevice *dev) {
    if(!dev) return;
    if(dev->hid) { IOHIDDeviceClose(dev->hid,kIOHIDOptionsTypeSeizeDevice); CFRelease(dev->hid); }
    if(dev->manager) CFRelease(dev->manager);
    free(dev);
}
size_t apf_report_size(APFDevice *dev) { return dev->report_size; }
uint32_t apf_wire_sector(uint32_t n) {
    uint64_t wire = n < 256 ? n : (uint64_t)n + 1 + (n-256)/255;
    return wire > UINT32_MAX ? UINT32_MAX : (uint32_t)wire;
}

static int get(APFDevice *dev, uint8_t id, uint8_t *buffer, size_t minimum, char *err, size_t size) {
    memset(buffer,0,dev->report_size); buffer[0]=id;
    CFIndex length=dev->report_size;
    IOReturn result=IOHIDDeviceGetReport(dev->hid,kIOHIDReportTypeFeature,id,buffer,&length);
    if(result!=kIOReturnSuccess) return failure(err,size,"USB feature read",result);
    if(length<(CFIndex)minimum) { snprintf(err,size,"Short USB report: %ld bytes, need %zu",(long)length,minimum); return 0; }
    return 1;
}
static int set(APFDevice *dev, uint8_t *buffer, char *err, size_t size) {
    IOReturn result=IOHIDDeviceSetReport(dev->hid,kIOHIDReportTypeFeature,buffer[0],buffer,dev->report_size);
    return result==kIOReturnSuccess ? 1 : failure(err,size,"USB feature send",result);
}
int apf_identity(APFDevice *dev, uint8_t *bytes, size_t length, char *err, size_t size) {
    uint8_t report[1024];
    if(length<3 || length>63) { snprintf(err,size,"Identity buffer must contain 3 to 63 bytes"); return 0; }
    // Real APF-01 firmware returns only the three identity bytes on macOS.
    // get() zeroes the rest, matching the Windows app's pre-cleared buffer.
    if(!get(dev,0x16,report,3,err,size)) return 0;
    memcpy(bytes,report,length); return 1;
}
int apf_read_sector(APFDevice *dev, uint32_t sector, uint32_t bps, uint8_t *bytes, char *err, size_t size) {
    uint32_t wire=apf_wire_sector(sector);
    int bootstrap = bps == 0 && sector == 0;
    if(sector>65535 || wire>65535 || (!bootstrap && bps!=128 && bps!=256 && bps!=512)) { snprintf(err,size,"Invalid read sector geometry"); return 0; }
    if(bootstrap) bps=128;
    uint8_t report[1024]={0};
    report[0]=0x14; report[1]=1; report[2]=wire>>8; report[3]=wire&255;
    if(!set(dev,report,err,size)) return 0;
    for(uint32_t offset=0;offset<bps;offset+=64) {
        if(!get(dev,0x14,report,64,err,size)) return 0;
        memcpy(bytes+offset,report,64);
        if(bootstrap && offset==0) {
            bps=bytes[11] | ((uint32_t)bytes[12]<<8);
            if(bps!=128 && bps!=256 && bps!=512) { snprintf(err,size,"Unrecognized card sector size: %u",bps); return 0; }
        }
    }
    return 1;
}
int apf_write_sector(APFDevice *dev, uint32_t sector, uint32_t bps, const uint8_t *bytes, char *err, size_t size) {
    uint32_t wire=apf_wire_sector(sector);
    if(sector>65535 || wire>65535 || (bps!=128 && bps!=256 && bps!=512)) { snprintf(err,size,"Invalid write sector geometry"); return 0; }
    for(uint32_t offset=0;offset<bps;offset+=60) {
        uint8_t report[1024]={0}; size_t length=bps-offset; if(length>60) length=60;
        report[0]=0x14; report[1]=offset ? 3 : 2; report[2]=wire>>8; report[3]=wire&255;
        memcpy(report+4,bytes+offset,length);
        if(!set(dev,report,err,size)) return 0;
        // The original app requests report 0x15 after each chunk. Its firmware
        // defines no checked status byte; require the transfer itself to succeed.
        if(!get(dev,0x15,report,1,err,size)) return 0;
    }
    return 1;
}
