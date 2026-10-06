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
- `swift test`: 121 test lulus.
- `scripts/bundle.sh`: bundle release 3.8 MB, tanpa direktori `Contents/Frameworks`.
