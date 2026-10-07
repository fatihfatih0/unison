# GitHub’a yükleme ve yayımlama

Bu rehber kaynak kodu ve indirilebilir kurulum paketini yayımlama adımlarını anlatır. Tanıtım ve kullanım bilgileri README içindedir. GitHub hesabı ve depo adı henüz bu projeye bağlanmadı. Aşağıdaki `KULLANICI` alanını kendi kullanıcı adınla değiştir.

## 1. Kaynak kodu yükle

GitHub'da **New repository** ile `unison` adlı **Public** depo oluştur. Bu projede README ve MIT lisansı bulunduğu için GitHub'da ek README/lisans oluşturma. Proje klasöründe:

```sh
# Git deposu henüz yoksa:
git init -b main

git add .
git diff --cached --stat
git commit -m "Prepare Unison open-source release"
git remote add origin https://github.com/KULLANICI/unison.git
git push -u origin main
```

`build`, `build.noindex`, `.build`, sertifikalar ve yerel tanılama çıktıları `.gitignore` ile dışarıda bırakılır. İtmeden önce `git status` kontrol et. HTTPS doğrulamasında GitHub'ın desteklediği kimlik doğrulamasını kullan; parola veya token'ı kaynak dosyalara koyma.

Alternatif: [GitHub CLI](https://cli.github.com/manual/gh_repo_create) kuruluysa ve hesap bağlantısı yapılmışsa:

```sh
gh auth login
gh repo create unison --public --source=. --remote=origin --push
```

Bu alternatifi kullanırken depoyu/`origin` bağlantısını önce elle oluşturma. İlk commit bulunmalıdır. [GitHub kaynak yükleme rehberi](https://docs.github.com/en/migrations/importing-source-code/using-the-command-line-to-import-source-code/adding-locally-hosted-code-to-github).

## 2. İndirilebilir sürümü hazırla

```sh
./Scripts/build-installer.sh
package_path=$(cat build/latest-installer-path.txt)
shasum -a 256 "$package_path"
```

Paketi başka bir Apple Silicon Mac'te kurup ses, parlaklık, izinler, kaldırma ve yeniden başlatmayı dene. Yerel Mac'teki başarı tüm cihazlarda uyumluluk garantisi değildir. Mevcut paket Apple-notarized değildir; sürüm notlarına bunu açıkça yaz.

GitHub **Releases → Draft a new release** bölümünde `v0.1.0` etiketi oluştur. Başlığı `Unison v0.1.0 — Preview` yap; erken sürüm olarak işaretle. `build/latest-installer-path.txt` içindeki `Unison-Audio.pkg` dosyasını ekle. SHA-256 çıktısını ve `CHANGELOG.md` notlarını açıklamaya koy. Önce taslak kaydet; testlerden sonra yayımla. Kaynak kodu indirilebilir hale getirmek tek başına kurulum paketi oluşturmaz.

CLI ile taslak alternatif:

```sh
gh release create v0.1.0 "$package_path" --draft --prerelease \
  --title "Unison v0.1.0 — Preview" --notes-file CHANGELOG.md
```

[GitHub CLI sürüm rehberi](https://cli.github.com/manual/gh_release_create).

Daha sorunsuz genel dağıtım için ayrı **Developer ID Application** ve **Developer ID Installer** kimlikleriyle imzalama ve Apple notarization işlemi gerekir. Bu depoda bu kimlikler veya tamamlanmış notarization akışı yoktur; ad-hoc/Apple Development imzası buna eşdeğer değildir.

## 3. Son kontrol

- `./Scripts/test.sh` başarılı.
- `git ls-files` içinde derleme çıktıları, `.pkg`, `.app`, `.DS_Store`, `.p12`, `.p8` veya kişisel yollar yok.
- README görselleri ve kurulum bağlantıları açılıyor.
- Releases sayfasında kurulum paketi mevcut; README üzerinden kurulum adımları anlaşılabiliyor.
- MIT ve tüm üçüncü taraf lisansları kaynakta ve dağıtımda korunuyor.
- GitHub Actions CI, push ve pull request'lerde derleme/test çalıştırıyor. Fiziksel cihaz testi CI tarafından yapılmaz.

## 4. Projeyi bulunabilir yap

Depoyu **Public** tut. GitHub **About** açıklaması için:

> Open-source macOS menu bar app for HDMI volume, external monitor brightness and simultaneous speaker output.

İlgili konu etiketleri: `macos`, `swift`, `swiftui`, `menu-bar`, `hdmi`, `volume-control`, `brightness-control`, `ddc`, `multi-output-audio`, `open-source`.

README çözülen sorunu, gerçek çalışma şeklini, kurulum adımlarını ve bilinen sınırları anlatır. İndirilebilir bir Releases paketi ve kullanıcıların bildirdiği uyumluluk sonuçları, başkalarının projeyi değerlendirmesine yardımcı olur. GitHub Pages gerekli değildir.

ChatGPT'de önerilme veya arama sonuçlarına alınma garantisi yoktur. OpenAI'nin [tarayıcı rehberi](https://developers.openai.com/api/docs/bots), `OAI-SearchBot` erişiminin ChatGPT arama sonuçlarında bulunmak için önemli olduğunu açıklar; bu, önerilme garantisi anlamına gelmez. GitHub deposunun tarayıcı erişimini GitHub yönetir; depoya `robots.txt` eklemek GitHub'ın alan adı ayarlarını değiştirmez. Herkese açık ve açıkça belgelenmiş bir proje hazırlamak, keşfedilmeyi kolaylaştırmak için yaptığımız bir iyileştirmedir; ChatGPT'ye özel bir kayıt veya eğitim işlemi değildir.
