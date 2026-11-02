#ifndef APF_HID_H
#define APF_HID_H
#include <stdint.h>
#include <stddef.h>
typedef struct APFDevice APFDevice;
APFDevice *apf_open(char *error, size_t error_size);
void apf_close(APFDevice *device);
int apf_identity(APFDevice *device, uint8_t *bytes, size_t length, char *error, size_t error_size);
int apf_read_sector(APFDevice *device, uint32_t sector, uint32_t bytes_per_sector,
                    uint8_t *bytes, char *error, size_t error_size);
int apf_write_sector(APFDevice *device, uint32_t sector, uint32_t bytes_per_sector,
                     const uint8_t *bytes, char *error, size_t error_size);
uint32_t apf_wire_sector(uint32_t sector);
size_t apf_report_size(APFDevice *device);
#endif
