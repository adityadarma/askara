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
- Askara memiliki vault password lokal per profil di macOS Keychain, dengan Save, Fill, dan Manage
  eksplisit untuk origin HTTPS yang sama. Vault tidak aktif di jendela privat dan tidak disinkronkan.
- Riwayat download selesai/gagal/dibatalkan disimpan lintas peluncuran, termasuk hasil scan lokal.
- Notifikasi lokal macOS tersedia untuk download selesai dan gagal setelah pengguna memberi izin.
- Folder sync menyimpan security-scoped bookmark agar akses pilihan pengguna bertahan setelah relaunch.
- Runtime, bridge, helper, script, dan vendor binary CEF telah dihapus.
- Cache CEF lama dibersihkan tanpa menghapus metadata profil.
- Bundle release tidak membawa framework browser tambahan; WebKit disediakan oleh macOS.
- `swift test`: 121 test lulus.
- `scripts/bundle.sh`: bundle release 3.8 MB, tanpa direktori `Contents/Frameworks`.
