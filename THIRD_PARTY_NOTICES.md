# Üçüncü taraf kaynakları

## m1ddc

- Kaynak: https://github.com/waydabber/m1ddc
- Alınan revizyon: `04d949794102eb8df01ad3681afff6464a3eede2`
- Lisans: MIT; tam metin `Vendor/m1ddc/LICENSE` içinde korunur ve uygulamaya eklenir.
- Kaynak dosyalar: `Vendor/m1ddc/headers`, `Vendor/m1ddc/sources`, `Vendor/m1ddc/Makefile`.

Yerel değişiklikler:

1. `sizeof(2)` ile iki baytlık değişkene dört bayt kopyalanması yerine doğrudan big-endian bayt çözümlemesi.
2. DDC yanıt başlığı, özellik kodu, sonuç kodu ve checksum doğrulaması. Boş ve bozuk yanıtlar artık ses/parlaklık değeri değildir.
3. Sıfır baytlarını kesmeden DDC paket uzunluğunu protokol alanından hesaplama.
4. Varsayılan DDC bekleme süresini 50 ms yapma.

DDC erişimi m1ddc'nin kullandığı Apple özel IOAVService/CoreDisplay arayüzlerine dayanır. Bu, gelecekteki macOS sürümlerinde uyumluluk riski taşır; Mac App Store dağıtımı bu sürümün hedefi değildir.

Tutti'den kaynak kodu, görsel veya marka varlığı alınmadı.

## libASPL

- Kaynak: https://github.com/gavv/libASPL
- Alınan revizyon: `633e0f70203edd87d320fc5a3cae901e1363aac5`
- Lisans: MIT; `Vendor/libASPL/LICENSE` korunur ve `UnisonAudio.driver/Contents/Resources/libASPL-LICENSE.txt` olarak dağıtılır.
- Çalışma zamanı başlıkları, kaynakları ve üretilmiş C++ dosyaları değiştirilmeden kullanılır; derlemede gerekmeyen upstream örnekleri, testleri, belgeleri, araçları ve Git geçmişi dağıtılmaz. Apple kaynaklı bölümlerin `LICENSE.apple2012` ve `LICENSE.apple2020` bildirimleri de kaynakta ve sürücü paketinde korunur. Ses sürücüsü `Driver/UnisonAudio.cpp` içindedir.
