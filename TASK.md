# Task: WebKit-Only Browser

Status: selesai dan terverifikasi.

- Askara hanya memakai Apple WebKit melalui `WKWebView`.
- Pilihan engine per profil telah dihapus.
- Profil lama yang menyimpan `browserEngineID` tetap dapat dibuka; field lama diabaikan dan tidak
  ditulis kembali.
- History, bookmark, session, permission, extension, download, Memory Saver, DevTools, screenshot,
  dan fitur browser lain tetap memakai implementasi WebKit yang sudah ada.
- `Tab` menyimpan `WKWebView` langsung; wrapper, adapter file, dan factory closure internal dihapus.
- Safari Web Extension tetap didukung agar password manager eksternal dapat dipasang oleh pengguna.
- Askara tidak memiliki vault password bawaan. Password dikelola Bitwarden (Safari Web Extension)
  bila terpasang dan diaktifkan; tanpa Bitwarden, browser tetap berjalan normal.
- Riwayat download selesai/gagal/dibatalkan disimpan lintas peluncuran, termasuk hasil scan lokal.
- Notifikasi lokal macOS tersedia untuk download selesai dan gagal setelah pengguna memberi izin.
- History, Bookmarks, dan Downloads memiliki jendela independen. Downloads memakai daftar visual
  dengan ikon file, progress, sumber, ukuran, status, tanggal, dan tindakan langsung.
- History menampilkan favicon, domain, URL, jumlah kunjungan, dan waktu terakhir. Bookmarks
  menampilkan favicon, domain, URL, folder penyimpanan, dan tanggal dibuat.
- Ketiga daftar memakai row compact: 24 pt untuk History/Bookmarks dan 30 pt untuk Downloads;
  URL lengkap tetap tersedia melalui tooltip. Popover bookmark memakai form dan footer yang sejajar.
- Search History/Bookmarks/Downloads memiliki lebar konsisten dan memfilter langsung saat mengetik;
  Bookmarks tidak menggambar strip kosong, dan Downloads memakai default window compact 620×360.
- Toolbar menampilkan tombol Downloads di sebelah Extensions selama daftar download belum kosong.
- Menutup window normal menyimpannya sebagai satu entri recently closed; ⇧⌘T memulihkan tab atau
  seluruh window terakhir dengan urutan, pinned state, mute state, dan interaction history.
- Tab strip memiliki Search Tabs untuk mencari tab terbuka lintas window profil yang sama dan tab
  recently closed. Normal dan private window tetap terisolasi.
- Folder sync menyimpan security-scoped bookmark agar akses pilihan pengguna bertahan setelah relaunch.
- Runtime, bridge, helper, script, dan vendor binary CEF telah dihapus.
- Cache CEF lama dibersihkan tanpa menghapus metadata profil.
- Bundle release tidak membawa framework browser tambahan; WebKit disediakan oleh macOS.
  Satu-satunya framework yang dibawa adalah `Sparkle.framework` untuk update dalam app.
- `swift test`: 162 test lulus.

# Task: Fitur Developer Tambahan

Status: selesai; build bersih, `swift test` 177 test lulus. Alur UI (menu, sheet, sertifikat mkcert
asli, scan QR di HP) belum dicek langsung di layar.

Semua ada di menu Develop:
- User Agent: Default, preset (Chrome/Edge/Firefox macOS, Chrome Windows, Safari iPhone/iPad,
  Chrome Android, Googlebot), dan "Other…". Per tab, ikut tab saat sleep/duplicate. User agent
  Device Mode tetap diutamakan selama aktif. Input kustom dibersihkan dari line break.
- Disable Caches: toggle per tab; cache HTTP dikosongkan sebelum setiap navigasi main frame.
  Cache WebKit dipakai bersama satu profil, jadi tab lain di profil itu ikut kehilangan cache.
- JSON viewer: response `application/json`, `text/json`, `*+json` tampil sebagai tree dengan
  Tree/Raw/Expand/Collapse/Copy. Berjalan di content world terpisah (tetap aktif saat JavaScript
  situs diblokir); nilai disisipkan lewat `textContent`. Dokumen di atas 8 MB tetap teks biasa.
- Sertifikat lokal: sertifikat tidak valid hanya bisa diterima untuk host lokal (`localhost`,
  `*.localhost`, `*.test`, `*.local`, `*.internal`, 127/8, 10/8, 172.16/12, 192.168/16) setelah
  sheet peringatan. Pengecualian berlaku sampai app ditutup. Host publik selalu divalidasi normal.
- Clear Site Data: cookie dan semua data website situs aktif (termasuk subdomain).
- Open Page With: browser terpasang dibaca saat submenu dibuka.
- Show QR Code for Page: `localhost`/127.x diganti alamat IPv4 LAN Mac agar bisa dibuka di HP.
- Copy as cURL: URL, user agent halaman, dan cookie yang cocok (domain, path, Secure). Toast
  mengingatkan bila cookie ikut tersalin.
- Device Mode > Custom Size…: 200–4096 piksel CSS per sisi, user agent tidak berubah.

# Task: Rilis Universal dan Update dalam App

Status: selesai; build dan signing terverifikasi lokal. Workflow CI dan alur update end-to-end
belum teruji (butuh setup secret dan dua rilis).

- `scripts/bundle.sh --universal` membangun binary arm64 + x86_64 (Apple Silicon dan Intel).
  Tanpa flag, build tetap native agar cepat untuk development.
- Versi bundle diambil dari `ASKARA_VERSION` (CFBundleShortVersionString) dan `ASKARA_BUILD`
  (CFBundleVersion).
- Ukuran universal: `.app` sekitar 10 MB (termasuk Sparkle), zip sekitar 3 MB lebih.
- `.github/workflows/release.yml`: dipicu tag `v*` atau manual. Menjalankan test, build universal,
  zip, tanda tangan EdDSA untuk zip dan `appcast.xml`, lalu membuat GitHub Release.
- Update dalam app memakai Sparkle 2.10.0 (versi dikunci). Menu "Check for Updates…" ada di menu
  Askara. Feed: `releases/latest/download/appcast.xml`; `SURequireSignedFeed` aktif.
- Tanpa `ASKARA_SPARKLE_PUBLIC_KEY`, updater nonaktif dan menu dinonaktifkan (build lokal).

Setup sebelum rilis pertama:
- Jalankan `.build/artifacts/sparkle/Sparkle/bin/generate_keys` sekali (kunci privat disimpan di
  Keychain).
- Simpan public key sebagai repository variable `SPARKLE_PUBLIC_KEY`.
- Ekspor kunci privat (`generate_keys -x <file>`) ke repository secret `SPARKLE_PRIVATE_KEY`, lalu
  hapus file ekspornya.

Signing (identitas tetap):
- `scripts/make-signing-cert.sh` membuat sertifikat self-signed "Askara Self-Signed" (20 tahun) di
  login keychain, plus `.p12` dan password-nya di `~/.askara-signing/` (di luar repo).
- `scripts/bundle.sh` otomatis memakai sertifikat itu bila ada; tanpa sertifikat kembali ke ad-hoc.
  Designated requirement: `identifier "dev.adityadarma.askara" and certificate leaf = H"27af…77ba"`,
  sama di setiap build, jadi izin Downloads/kamera/mikrofon/Keychain tidak diminta ulang.
- Hardened runtime tidak dipakai untuk self-signed: library validation butuh Team ID, tanpa itu
  `Sparkle.framework` gagal dimuat.
- CI mengimpor sertifikat dari secret `SELF_SIGN_P12_BASE64` dan `SELF_SIGN_P12_PASSWORD` ke
  keychain sementara, lalu gagal bila app tidak ditandatangani dengan sertifikat itu.
- Update dari rilis ad-hoc lama tetap diterima Sparkle karena EdDSA valid; izin diminta sekali lagi
  setelah update itu, lalu tetap.

Batasan:
- Gatekeeper tetap memblokir pembukaan pertama; Developer ID + notarisasi menghilangkannya.
- Kalau `~/.askara-signing` dan secret hilang, sertifikat baru berarti identitas baru dan semua izin
  diminta ulang. Simpan cadangan `.p12` dan password-nya.

# Task: Blokir Iklan YouTube

Status: selesai; teruji dengan halaman tiruan. Belum teruji di youtube.com asli.

- Blokir domain tidak bisa menangkap iklan YouTube karena iklan dikirim dari domain YouTube sendiri.
- `YouTubeAdBlocker` (user script, document start) menghapus `adPlacements`, `adSlots`,
  `playerAds`, dan `adBreakHeartbeatParams` dari respons player sebelum YouTube membacanya, jadi
  video langsung diputar tanpa iklan. Titik masuk yang ditangani: `ytInitialPlayerResponse`
  (muat pertama), `JSON.parse`, dan `Response.json()` (video berikutnya).
- Cadangan: kalau iklan tetap lolos, iklan dibisukan dan tombol "Skip" ditekan otomatis.
- Aturan kosmetik (`YouTubeAdRules`, `css-display-none`) menyembunyikan banner, iklan feed, dan
  overlay di youtube.com. Aturan ini ikut daftar blokir yang sudah ada.
- Pengecualian ad blocker per situs (Privacy Dashboard) untuk youtube.com mematikan semuanya.
  Script memeriksa elemen probe yang disembunyikan aturan, jadi hanya aktif jika aturan aktif.
- Alternatif yang lebih tahan perubahan YouTube: Safari Web Extension ad blocker yang dipasang
  pengguna, dimuat lewat `ExtensionManager`. Belum dicoba dengan ad blocker tertentu.

Batasan:
- Nama field dan selector bergantung pada YouTube dan perlu diperbarui bila YouTube berubah.
- Iklan yang disisipkan langsung ke stream video di server (server-side ad insertion) tidak bisa
  dihapus dari browser; untuk kasus itu hanya cadangan mute + skip yang berlaku.
- YouTube dapat menampilkan peringatan anti-adblock bila mendeteksi perubahan ini.

# Task: Notifikasi dan Progres Download

Status: selesai; teruji lewat unit test. Tampilan cincin dan banner belum dicek langsung di layar.

- Notifikasi "Unduhan Selesai" sebelumnya tidak terlihat saat Askara aktif, karena macOS
  menyembunyikan notifikasi app aktif tanpa delegate. `DownloadManager` sekarang menjadi
  `UNUserNotificationCenterDelegate`, jadi banner dan suara tetap muncul.
- Klik notifikasi "Unduhan Selesai" membuka file di Finder; bila file sudah tidak ada, jendela
  Downloads yang dibuka.
- `DownloadsToolbarButton`: selama download berjalan, ikon menjadi panah kecil dengan cincin progres
  berwarna aksen. Cincin berputar bila ukuran belum diketahui, lalu terisi sesuai rata-rata progres
  download yang berjalan. Setelah selesai, ikon kembali normal.
- Animasi memakai Core Animation tanpa timer. Dengan Reduce Motion, cincin tidak berputar.
- `FirstClickButton` tidak lagi `final` agar bisa diturunkan.
