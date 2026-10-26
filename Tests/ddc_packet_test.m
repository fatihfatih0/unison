#include <assert.h>
#include <stdio.h>
#include "i2c.h"
#include "ioregistry.h"

static void test_display_indices(void) {
    DisplayInfos displays[2] = {{0}};
    char *invalid[] = {"", "0", "-1", "3", "999999999999999999999999999999999"};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        assert(selectDisplay(displays, 2, invalid[i]) == NULL);
    }
    char first[] = "1", last[] = "2";
    assert(selectDisplay(displays, 2, first) == &displays[0]);
    assert(selectDisplay(displays, 2, last) == &displays[1]);
    assert(selectDisplay(displays, 0, first) == NULL);
}

int main(void) {
    test_display_indices();
    UInt8 valid[12] = {0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 65, 0};
    UInt8 checksum = 0x50;
    for (int i = 0; i < 10; i++) checksum ^= valid[i];
    valid[10] = checksum;
    DDCValue value = convertI2CtoDDC((char *)valid);
    assert(value.curValue == 65 && value.maxValue == 100);
    valid[10] ^= 1;
    assert(convertI2CtoDDC((char *)valid).curValue == -1);
    UInt8 nullReply[12] = {0x6e, 0x80, 0xbe, 0x6e, 0x80, 0xbe, 0x6e, 0x80, 0xbe, 0x6e, 0x80, 0xbe};
    assert(convertI2CtoDDC((char *)nullReply).curValue == -1);
    DDCPacket write = createDDCPacket(LUMINANCE);
    prepareDDCWrite(&write, 0);
    assert(write.data[3] == 0 && write.data[4] == 0);
    puts("DDC: paket doğrulama ve geçersiz ekran numarası/sınır testleri geçti.");
}
