GAMEBOOST LITE 2.0
==================

Masaüstündeki "GameBoost Lite" kısayolu uygulamayı Windows'un imzalı PowerShell'i
ile açar (Uygulama Denetimi imzasız EXE'yi engellediği için). Güvenlik ilkesi
kapatılmamıştır. Sistemde yapılan her değişiklik geri alınabilir.

Kısayol "conhost.exe --headless powershell.exe ... GameBoostLite.ps1" şeklindedir;
böylece Windows Terminal penceresi açılmaz. Eski kısayol _yedek-20261031 içindedir.

KAPATMA VE SİSTEM TEPSİSİ
-------------------------
- Pencerenin X'i uygulamayı kapatmaz; saatin yanındaki simgeye gizler. BOOST ve
  oyun takibi arka planda sürer. Simgeye tıklayınca pencere geri gelir.
- Sağ tık menüsü: GameBoost'u aç, BOOST'u başlat, Normal moda dön,
  İndirme modunu aç/kapat, Tasarruf modunu aç/kapat, Yeniden başlat, Çıkış.
- Tamamen kapatmak yalnızca Çıkış ile olur. BOOST açıksa önce sorulur; çıkınca
  güç planı ve verimlilik modu geri alınır.
- Yeniden başlat: güncellemeden sonra yeni dosyaları yükler. Çıkış gibi önce
  BOOST'u geri alır (açıksa sorar); yeni kopya eskisi kapanınca pencereyle açılır.
- Kısayola tekrar basmak, arka plandaki pencereyi öne getirir.
- BOOST bitince geri alınanlar: güç planı, verimlilik modu, oyun önceliği.
  Kalıcı olanlar: Windows Oyun Modu ve oyun için GPU tercihi (Oyun Ayarları >
  "Hepsini eski haline döndür" ile geri alınır; oyuna önceden seçilmiş bir GPU
  tercihi varsa ona dokunulmaz), "Koru" denen Hz, uygulanan Wi-Fi ayarları (Geri
  al ile dönülür). Kapatılan uygulamalar kendi kendine yeniden açılmaz.

SAYFALAR
--------
Oyun Modu        BOOST / Normal mod, akıllı durum özeti, BOOST ayarları, günlük.
Modlar           İndirme modu, Tasarruf / Süper tasarruf, akıllı bildirimler,
                 pil ve güç bilgisi.
Canlı İzleme     En çok RAM kullanan uygulamalar ve BOOST'un onlara ne yapacağı.
Kapatma Listesi  BOOST'ta ek olarak kapatılacak uygulamalar; korunanlar listesi.
Ekran / TV       Bağlı ekranlar, bağlantı (HDMI/DP), hangi GPU'ya bağlı, Hz, HDR,
                 desteklenen modlar. Çoğalt modu, düşük Hz ve Intel üzerinden
                 bağlanma uyarıları. "En yüksek Hz'e geç" 15 sn onaylıdır.
Ses              Tüm çıkış/giriş aygıtları, biçim (kHz/bit), varsayılanlar,
                 sessiz/düşük ses, Bluetooth Hands-Free ve gecikme uyarıları.
Ağ / Wi-Fi       Bağlantı, bant, Wi-Fi standardı, gecikme testi (modem ve
                 internet ayrı), internet hız testi, oyun için Wi-Fi sürücü ayarları.
Bluetooth ve     Bluetooth sürümü, eşleşmiş cihazlar ve pil, kumandalar
Kumanda          (kablolu/kablosuz, pil), kumanda ve fare rapor hızı testleri.
Sistem Bilgisi   Tam donanım raporu ve "Kullanabileceğin özellikler".
                 Tümünü kopyala / Masaüstüne kaydet. Arka planda hazırlanır;
                 bu sırada pencere kullanılabilir.
PC Puanı         Oyun gücü puanı, parça puanları, kurulum puanı, oyuna göre
                 tahmin, yükseltme etkisi.
Bakım ve         Uyarılar, Güvenlik, Haftalık özet ve Çözümler sekmeleri,
Güvenlik         depolama analizi, güvenli temizlik.
FPS / HUD        Oyun içi gösterge (F10 / Ctrl+F10).

OTOMATİK (Oyun Modu > Otomatik; üçü de başlangıçta kapalı)
--------------------------------------------------------
- Windows açılınca başlat: yalnızca bu kullanıcının başlangıç listesine
  penceresiz bir komut yazar (yönetici gerekmez). Kapatınca silinir.
- Başlangıçta tepside bekle: Windows ile açıldığında pencere görünmez.
- Oyun algılanınca otomatik BOOST: Steam, Epic, EA, Ubisoft, Rockstar, Xbox
  klasöründeki oyun 5 sn arayla iki kez görülünce başlar. Launcher, yükleyici,
  crash handler ve Steam araçları (Wallpaper Engine, SteamVR, Lossless Scaling,
  Soundpad) başlatmaz; BOOST sırasında da oyun sayılmazlar. Soru sormaz, hiçbir uygulamayı kapatmaz; yalnızca
  güç planı (pilde değiştirmez), Oyun Modu, verimlilik modu ve (ayarı açıksa)
  Game Bar. NORMAL MOD'a basılırsa o oyun kapanana kadar tekrar başlamaz.
  İzleme 5 sn'de bir tek süreç taraması yapar ve yalnızca bu ayar açıkken çalışır.

OYUN SIRASINDA AKILLI UYARILAR VE OYUN ÖZETİ (yalnızca BOOST açıkken)
---------------------------------------------------------------------
- Ekran kartı ısı / donanım yavaşlaması: NVIDIA'nın kendi bildirdiği neden,
  5 sn'de bir tek bir nvidia-smi sürecinden. İki okuma (~10 sn) sürerse bir kez
  uyarır. Yük altında güç sınırında çalışmak dizüstüde normaldir; yalnızca
  özette geçer.
- Oyun yanlış ekran kartında: oyun algılandıktan 20 sn sonra bir kez, Windows
  GPU sayaçlarıyla. Oyun Intel'de çizim yapıyorsa uyarır; oyunun kendi VRAM'ini
  de ölçer. Oyun o an GPU kullanmıyorsa 1 dk sonra bir kez daha bakar.
- Şarj aleti yetersiz: prize takılıyken pil 2 dk içinde %3 düşerse.
- Oyun özeti (BOOST bitince, pencere açmadan Etkinlik kutusuna ve Akıllı
  durum listesine): süre, en yüksek GPU sıcaklığı ve GPU belleği (tüm
  uygulamalar), oyunun ekran kartı, en düşük boş RAM ve oyunun kendi RAM'i,
  modem gecikmesi ve sıçramaları (5 sn'de bir ping), arka plan indirme,
  Windows Update ve Defender'ın çalıştığı süre, güç durumu.
- Takılma analizi (FPS ölçümüyle aynı koşul: NVIDIA FrameView ve FPS yetkisi):
  BOOST boyunca oyunun kare süreleri PresentMon ile izlenir. Özette ortalama
  FPS, %1 düşük FPS ve takılma sayısı yer alır. Takılma, oyun öndeyken hemen
  önceki karelerin 2,5 katından (ve en az 20 ms) uzun süren karedir; yükleme
  ekranları, menüler ve alt-tab sayılmaz. Her takılma o an olanlarla
  karşılaştırılır: Defender, Windows Update, RAM'in 1 GB altına inmesi, arka
  plan indirme, ekran kartı ısı yavaşlaması, Wi-Fi gecikme sıçraması ve arka
  planda işlemciyi kullanan uygulamalar. Bir şey yalnızca o çalışırken
  takılmalar oyunun geri kalanına göre en az iki kat sıksa neden diye
  gösterilir; tesadüfi çakışmalar neden sayılmaz. Hiçbir olayla çakışmayan
  takılmalar "oyunun kendisi olabilir (shader derleme, yükleme)" diye yazılır.
- Okunamayan değerler "okunamadı / ölçülmedi" olarak yazılır. Hiçbir uyarı bir
  uygulamayı kapatmaz veya ayar değiştirmez.

OYUN AYARLARI SAYFASI
---------------------
- Önerilen Windows ayarları (yalnızca bu kullanıcıya ait, aç/kapat):
  Oyun Modu, arka plan oyun kaydını kapat, sesli sohbette oyun sesi kısılmasın,
  fare hızlandırmasını kapat, Shift×5 Yapışkan Tuşlar penceresini kapat,
  pencereli oyunlar için iyileştirmeler. İlk değişiklikten önce özgün değer
  windows-settings-backup.json dosyasına yazılır; anahtarı kapatmak veya
  "Hepsini eski haline döndür" o değeri aynen geri koyar.
- Mikrofon gürültü engelleme: NVIDIA Broadcast (RTX gerekir), SteelSeries Sonar
  ClearCast, Discord Krisp; kurulu olanı açar, olmayanı indirme sayfasına götürür.
- Güvenli bir anahtarı olmayan özellikler (HAGS, VRR, oyun sırasında bildirimler,
  güç modu, Depolama Sensörü) için ilgili Windows ayar sayfası açılır.

ARKA PLAN DENETİMİ (Akıllı Bakım)
---------------------------------
Düğmeye basınca 10 sn izler (ayrı iş parçacığında, pencere donmaz) ve listeler:
internet paylaşım ajanları ve kripto madenciler (süreç + başlangıç görevi),
penceresi olmadan ekran kartı veya işlemci kullanan uygulamalar, çok RAM tutan
arka plan uygulamaları, Temp/İndirilenler/Public/Roaming'den çalışan imzasız
dosyalar ve bu klasörlerden imzasız dosya çalıştıran başlangıç kayıtları.
Hiçbir şeyi kapatmaz veya değiştirmez.

YÜKSELTME ÖNERİLERİ (Sistem Bilgisi raporu)
------------------------------------------
Bu bilgisayarın verisine göre: RAM (yuvalar, tür, hız), mikrofonlu kulaklık,
Ethernet kablosu, adaptör, soğutucu stand, depolama; gerekçesiyle ve önem
sırasıyla. Değiştirilemeyen parçalar da belirtilir.

MİKROFON (Ses sayfası)
----------------------
- 5 sn mikrofon testi: konuşurken seviyeyi ölçer (konuşma, tepe, gürültü);
  "çok düşük / düşük / iyi / çok yüksek" der. Kayıt saklanmaz.
- Seviyeyi %100 yap / Önceki seviyeye dön (Windows mikrofon seviyesi; önceki
  seviye uygulama kapansa da saklanır).
- Uyarılar: mikrofon sessizde, seviye düşük, kulaklık mikrofonu takılı ama
  sohbet varsayılanı dahili mikrofon, masaüstü uygulamalarının mikrofon izni kapalı.

USB-C EKRAN TEŞHİSİ (Ekran / TV sayfası)
----------------------------------------
Windows, USB-C portun görüntü desteğini bir şey takılana kadar bildirmez.
GameBoost, portun varlığını ve başarısız görüntü denemelerini ("Billboard"
aygıtı) gösterir; Intel üzerinden bağlanan USB-C ekranlar için uyarır.

PC PUANI
--------
- PC gücü (0-100): ekran kartı %50, işlemci %25, RAM %15, depolama %10.
  En zayıf ana parça toplamı sınırlar (genel puan en zayıfın 20 fazlasını
  geçmez). Ölçek: 100 = RTX 5090 masaüstü; ekran kartları yaklaşık yayımlanmış
  test sonuçlarından, işlemciler nesil, çekirdek ve dizüstü/masaüstü sınıfından.
  Bu bilgisayarda yük testi yapılmaz; FPS tahmini verilmez.
- Ekran ve Ağ ayrıca puanlanır ama genel puana katılmaz.
- Kurulum puanı: donanım değiştirmeden düzeltilebilenler (akıllı uyarılardan;
  önemli -20, uyarı -10). Şarj, ekran modu, Wi-Fi modu gibi değişiklikler
  sayfa her açıldığında yeniden okunur.
- Yükseltirsen: RAM/SSD gibi değiştirilebilen parçaların puana etkisi.
- Model tabloda yoksa puan "tahmini" diye işaretlenir.
- Sağ sütun iki sekme: "Oyuna göre tahmin" ve "Kurulum puanı".
- Oyuna göre tahmin: ~110 oyunun (2025'e kadar güncel ve popüler oyunlar)
  yayıncı gereksinimleri (1080p en düşük / önerilen, yaklaşık) bu PC'nin ekran
  kartı, video belleği, RAM ve diskiyle karşılaştırılır: Çalışmaz / Zorlanır /
  Düşük / Orta / Yüksek / Çok yüksek. Steam, Epic ve Riot'ta yüklü veya daha
  önce BOOST'la oynanan oyunlar ✓ ile başta, sonra en yeniler gelir; o oyunun
  son oturum ölçümleri de gösterilir. FPS ölçümü değildir.
- Önerilen grafik ayarları: ön ayar, doku (video belleğine göre), DLSS / FSR
  modu, gölge, ışın izleme, FPS sınırı, Reflex ve oyuna özel ipuçları.

MODLAR
------
Her değişiklik yapılmadan önce modes-state.json'a yazılır; mod kapanınca,
uygulama kapanınca veya (çökmede) sonraki açılışta birebir geri alınır.
- İndirme modu: bilgisayar uyumaz (ekran kapanabilir; kapak kapanırsa uyur),
  Wi-Fi güç tasarrufu kapanır, Wi-Fi koparsa aynı ağa 3 kez yeniden bağlanmayı
  dener. Anlık ↓/↑ hız Mbps ve MB/sn olarak, paket kullanımı (%).
  - Paket hızı: hat boştayken haftada en fazla bir kez kısa hız testiyle
    ölçülür (~10 sn, ölçülü bağlantıda yapılmaz).
  - Darboğaz kararı (son 30 sn): internet paketinin sınırında / Wi-Fi sınırlıyor
    (gerekirse "Wi-Fi ayarlarını uygula") / yükleme hattı dolu / kaynak yavaş.
    Paket hızını hiçbir uygulama artıramaz; mod yerel engelleri gösterir.
  - Bitişi algılama: Steam (steamapps\downloading + appmanifest ilerlemesi),
    Epic (yarım kurulum işareti), tarayıcı / torrent (.crdownload, .part...).
    İlerleme, kalan süre; bitince adıyla bildirir ve (ayar açıksa) modu kapatır.
    Takip edilemeyenlerde trafik 2 dk durgun kalınca. Steam hâlâ listeliyorsa
    "ilerlemiyor" der, modu kapatmaz.
  - "İndirme / yükleme başlayınca otomatik aç" (başlangıçta kapalı): Steam /
    Epic, 50 MB üstü tarayıcı indirmesi veya 2 dk yoğun trafik görülünce açar ve
    bildirir. Elle kapatırsan 30 dk tekrar açmaz.
  - Kartta: ölçülü bağlantı, pil, kapak, Steam hız sınırı, TCP otomatik ayarı,
    VPN, Infatica ve Wi-Fi uyarıları; en çok bağlantısı olan uygulamalar (ipucu).
  - Sayfa öndeyken saniyede bir, arkadayken 5 sn'de bir güncellenir.
- Tasarruf ve Süper tasarruf iki sekmedir; her adım ayrı açılıp kapanır ve
  "şu an → modda" değeriyle yazar. "Önerilene dön" sekmeyi sıfırlar. Mod açıkken
  bir adımı değiştirirsen hemen yeniden uygulanır.
  - Tasarruf (önerilen): arka plan verimlilik modu, dahili ekran 60 Hz,
    parlaklık en fazla %50. İsteğe bağlı: pilde turbo kapalı, Enerji tasarrufu.
  - Süper (önerilen): hepsi; parlaklık en fazla %30.
  - Güç planı değerleri yazılmadan önce kaydedilir ve birebir geri yazılır.
- Mod sırasında parlaklığı kendin değiştirirsen kapanınca senin ayarın kalır.
- BOOST (elle veya otomatik) başlarsa tasarruf modu önce kapanır.
- Pil ve güç: çekiş (W) ve kalan süre, kapasite değişiminden ölçülür (Windows
  bu laptopta bildirmiyor). "NVIDIA kartını kim uyandırıyor?" ayrı ekran kartında
  bellek tutan uygulamaları listeler.

AKILLI BİLDİRİMLER (Modlar > Akıllı bildirimler)
------------------------------------------------
Pil %20 / %10, RAM doldu, arka planda 3 dk işlemciyi yoran uygulama, disk
dolmak üzere, güncelleme yeniden başlatma bekliyor, Infatica, uzun süredir
yeniden başlatılmadı, güvenlik bulguları (önerisiyle), indirme modu açıldı /
indirme tamamlandı / ilerlemiyor, Wi-Fi koptu / geri geldi. Saatin yanında
çıkar; tıklayınca ilgili sayfa açılır. Oyunda, tam ekranda, Odak / Rahatsız
etmeyin açıkken ve BOOST sırasında gösterilmez. Her konunun tekrar sınırı var,
günde en fazla 8 sıradan bildirim. Hiçbir uygulamayı kapatmaz.

HIZ TESTİ (Ağ / Wi-Fi)
----------------------
Cloudflare'in açık hız testi sunucusuyla (speed.cloudflare.com): gecikme,
4 bağlantıyla ~8 sn indirme ve ~6 sn yükleme; sonuç Mbps ve MB/sn. En fazla
~300 MB indirme, ~60 MB yükleme. Cloudflare 10 MB üstü tek indirmeleri
sınırladığı için 4 MB parçalarla ister; yine sınırlarsa parçayı küçültür ve
bunu sonuçta söyler. Ölçülü bağlantıda, BOOST veya İndirme modu açıkken önce
sorar. Sonuç: Wi-Fi mı yoksa internet paketi mi sınırlıyor, 50 GB oyun kaç
dakikada iner. Son geçerli sonuç İndirme modunun paket hızı olarak saklanır.

GÜVENLİK (Bakım ve Güvenlik > Güvenlik)
---------------------------------------
"Güvenlik taraması (15 sn)" arka plan denetimiyle birlikte çalışır ve bulur:
- İzlenme: uzaktan erişim araçları (AnyDesk, TeamViewer, RustDesk, VNC...),
  bilinen truva atı adları, kamerayı / mikrofonu şu an veya son 24 saatte
  kullanan uygulamalar (Windows'un gizlilik kaydından), proxy ayarı, Uzak
  Masaüstü.
- Madencilik: madenci adları, penceresiz ekran kartı kullanımı, madencilik
  havuzlarının tipik portlarına bağlantılar.
- Virüs şüphesi: antivirüs / gerçek zamanlı koruma / güvenlik duvarı kapalı,
  Defender'ın bulduğu tehditler, güvenlik sitelerini engelleyen veya
  yönlendiren hosts dosyası, gizli PowerShell / mshta komutu çalıştıran
  başlangıç görevleri, tuhaf klasörden çalışan imzasız uygulamalar.
Her bulgu ne yapılacağını söyler. 10 dakikada bir hafif kontrol (~50 ms) önemli
bulgular için bildirim gönderir. Hiçbir şeyi kapatmaz, silmez veya değiştirmez.

HAFTALIK ÖZET, PİL, SÜRÜCÜ VE ÇÖZÜMLER (Bakım ve Güvenlik)
---------------------------------------------------------
Günde bir hafif okuma (disk boş alanı, pilin tam kapasitesi, ekran kartı sürücü
tarihi) ve şarjda %100'de geçen dakikaların sayımı (health-history.json, 60 gün).
- Haftalık: oyun süresi, ekran kartı sıcaklığı ve geçen haftaya göre farkı
  (+5°C ve üstü → fan / hava girişi temizliği), ısı yavaşlaması, takılmalar ve en
  sık nedeni, pil sağlığı (tasarım kapasitesine göre, aylık değişim), %100'de
  prizde geçen günler, disk, sürücü yaşı, güvenlik. Haftada bir sessiz bildirim.
- Çözümler (her biri yalnızca tıklayınca):
  - Takılma nedeni Defender → oyunun kendi klasörünü taramadan hariç tut
    (yalnızca Steam / Epic / Xbox / EA / Ubisoft / Rockstar kütüphanesindeki
    klasörler; İndirilenler, Temp gibi klasörler asla önerilmez). Yönetici izni
    ister, ne eklendiği kaydedilir ve aynı listeden "Geri al" ile kaldırılır.
  - Windows Update → Etkin saatler; RAM → Kapatma listesi; indirme → Steam
    indirmeleri; ısı → OMEN Gaming Hub; Wi-Fi → Ağ / Wi-Fi; arka planda yoran
    uygulama → BOOST kapatma listesine ekle (korunan uygulamalar eklenmez).
  - Sürücü 120 günden eskiyse → NVIDIA App (yoksa sürücü sayfası).
  - Pil bir haftada 3+ gün 8 saatten uzun %100'de prizde → HP pil koruması
    (BIOS > Adaptive Battery Optimizer veya OMEN Gaming Hub).
- İndirme modu: "Bitince bilgisayarı uyut" (başlangıçta kapalı). İndirme bitince
  60 sn geri sayım ve bildirim; fare / klavye kullanılırsa, oyun / tam ekran
  açılırsa veya yeni indirme başlarsa iptal. Tepsiden "Uykuyu iptal et".

OYUNA HAZIRLIK VE OYUN GEÇMİŞİ
------------------------------
- Ana sayfada "Akıllı durum" başlığı: "Oyuna hazır ✓" veya uyarı sayısı.
- Son 20 oyunun küçük özeti %LOCALAPPDATA%\GameBoostLite\sessions.json
  dosyasında tutulur (önce geçici dosyaya yazılıp sonra yerine konur).
- Son 5 oyundan eğilim önerileri: RAM sık doluyor, ekran kartı sık ısınıyor,
  Wi-Fi düzenli dalgalanıyor, şarj aleti yetmiyor, oyunlar çoğunlukla pilde,
  takılmalar aynı nedenle tekrarlıyor. Tek bir kötü oyun öneri üretmez.

BOOST NE YAPAR
--------------
1. Yüksek Performans güç planına geçer; bitince önceki plana döner.
2. Windows Oyun Modu'nu açar.
3. Seçili uygulamaları kapatır. Çalışma uygulamaları ve özel liste nazikçe
   kapatılır (kaydetme fırsatı verilir, kapanmayan açık bırakılır). Game Bar,
   Discord ve Docker gerekirse sonlandırılır. Onay penceresinde yalnızca
   çalışanlar ve tahmini boşalacak RAM gösterilir.
4. Boş RAM 4 GB altındaysa en çok RAM kullanan pencereleri kapatmayı önerir.
5. Arka plan uygulamalarını verimlilik moduna alır (Windows EcoQoS + düşük
   öncelik). Öne getirdiğin uygulama hemen normale döner. Oyun sırasında
   arka planda sürekli işlemci kullanan bir uygulama da verimlilik moduna
   alınır. Ses, sohbet, kayıt, çevre birimi yazılımları, anti-cheat,
   launcher'lar ve Windows bileşenleri hiçbir zaman yavaşlatılmaz.
6. Oyunu algılar (Steam, Epic, EA, Ubisoft, Rockstar, Xbox kütüphaneleri;
   diğerleri tam ekran algılamayla) ve "Normalin üstü" öncelik verir.
7. Oyun kapanınca hepsini geri alır. Beklenmeyen kapanmada sonraki açılışta
   güç planı ve verimlilik modu geri yüklenir.

RAM zorla boşaltılmaz: RAM "temizleyiciler" veriyi diske itip takılma yaratır.

YÜK YARATMAMA
-------------
- Pencere yalnızca öndeyken 6 sn'de bir yenilenir; küçükken veya oyun
  sırasında arayüz hiçbir şey okumaz.
- BOOST'ta oyun bulunduktan sonra tam tarama 15 sn'de bir yapılır (~20 ms).
- Takılma analizi için BOOST boyunca tek bir PresentMon süreci çalışır (ETW,
  oyuna müdahale etmez); kareler saklanmaz, yalnızca özet ve takılmalar tutulur.
- Sistem raporu, Bluetooth ve Wi-Fi sürücü bilgileri yalnızca sayfası
  açılınca okunur. Sistem raporu ayrı iş parçacığında hazırlanır.
- PC Puanı parçaları bir kez okur (~0,2 sn); Yenile ile tekrar okunur.
- Modlar ve bildirimler: 5 sn'de bir hafif kontrol, dakikada bir süreç listesi
  (~20 ms) ve pildeyken pil kapasitesi. BOOST sırasında bildirim kontrolü yapılmaz.

YÖNETİCİ GEREKTİRENLER (her biri UAC sorar)
-------------------------------------------
- Ağ / Wi-Fi > Önerilenleri uygula: önceki değerler
  %LOCALAPPDATA%\GameBoostLite\wifi-backup.json dosyasına yedeklenir;
  "Geri al" ile dönülür. Wi-Fi birkaç saniye kopar.
- FPS ölçümü için bir kez (yönetici PowerShell):
    Add-LocalGroupMember -SID S-1-5-32-559 -Member <kullanıcı SID'in>
  sonra oturumu kapatıp aç. FPS / HUD sayfasındaki düğme komutu senin SID'inle
  kopyalar. Geri almak için aynı komutu Remove-LocalGroupMember ile çalıştır.

GÜVENLİ TEMİZLE
---------------
Yalnızca 24 saatten eski Temp dosyaları, 7 günden eski çökme dökümleri ve
hata raporları, bir haftadır boş Temp klasörleri. Silmeden önce ne kadar
silineceği gösterilir. Shader önbelleği, tarayıcı ve kişisel dosyalara
dokunulmaz.

FPS / HUD
---------
F10 göstergeyi 10 sn açar, Ctrl+F10 kalıcı açar/kapatır. Tuşlar yalnızca
gösterge etkinken ve BOOST açıkken kaydedilir; diğer zamanlarda F10 öteki
uygulamalara (ör. VS Code'da Step Over) serbesttir. FPS / HUD sayfasındaki
düğmeler her zaman çalışır. Gösterge ayrı, tıklamaları engellemeyen bir
penceredir; oyuna DLL enjekte edilmez. Oyunun açık olduğu ekranda belirir.

BAŞLANGIÇ VE OYUN AYARLARI BETİKLERİ
------------------------------------
Optimize-Startup.ps1 / Restore-Startup.ps1: launcher, Docker, Teams, Discord,
Edge ve DAEMON Tools'un Windows açılışında başlamasını kapatır / geri getirir.
Oyun Modu ve arka plan Game DVR kaydı artık yalnızca Oyun Ayarları sayfasından
yönetilir (tek yedek). Restore-Gaming.ps1 yalnızca eski Optimize-Gaming.ps1
yedeğini geri yüklemek için duruyor.

DOSYALAR
--------
GameBoostLite.ps1        Giriş noktası (pencere)
lib\GameBoostNative.cs   Süreç, ekran, ses, kumanda ve arayüz bileşenleri (C#)
lib\Ui.ps1               Tema ve ortak arayüz parçaları
lib\Boost.ps1            BOOST motoru, verimlilik modu, temizlik
lib\Insights.ps1         Bilgi toplama ve akıllı uyarılar
lib\Pages.ps1            Sayfalar
GameBoostOverlay.ps1     FPS / HUD göstergesi
legacy\                  Eski C# sürümü (kullanılmıyor)
_yedek-20261031\         2.0 öncesi dosyaların yedeği
Ayarlar: %LOCALAPPDATA%\GameBoostLite\settings.json
