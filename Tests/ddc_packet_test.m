#include <assert.h>
#include <stdio.h>
#include "i2c.h"

int main(void) {
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
    puts("DDC: geçerli paket, bozuk checksum, boş yanıt ve sıfır değeri testleri geçti.");
}
