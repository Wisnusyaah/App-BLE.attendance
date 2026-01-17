# App-BLE.attendance
# Sistem Presensi Otomatis Indoor Berbasis BLE (iBeacon)

Aplikasi presensi otomatis di ruang kelas berbasis **Bluetooth Low Energy (BLE) iBeacon**. Sistem menggunakan **2 beacon nRF52840 per kelas**, aplikasi **mobile Flutter** di smartphone mahasiswa, dan **Firebase (Auth + Firestore)** sebagai backend. Aplikasi memindai sinyal iBeacon, menghitung rata-rata **RSSI** dari dua beacon, memvalidasi jadwal serta jendela presensi yang dibuka dosen, lalu mencatat presensi secara otomatis.

## Fitur Utama
- **Mode Mahasiswa**
  - Login
  - Auto-scan iBeacon
  - Deteksi “di dalam kelas” berbasis rata-rata RSSI (threshold default ~ **-80 dBm**)
  - Presensi otomatis: **one-time** & **check-in/check-out**
- **Mode Dosen**
  - Membuka/menutup **attendance window** (jendela presensi)
  - Melihat rekap/daftar kehadiran

## Cara Kerja Singkat
1. Beacon memancarkan iBeacon secara periodik (UUID sama, **major = ID kelas**, **minor = 1/2**).
2. Aplikasi memindai BLE, menyaring iBeacon sesuai UUID, lalu mengumpulkan nilai RSSI.
3. Aplikasi menghitung **rata-rata RSSI** dari dua beacon untuk setiap kelas.
4. Jika rata-rata RSSI melewati threshold dan stabil, aplikasi menganggap pengguna berada **di dalam kelas**.
5. Aplikasi mengecek ke Firebase:
   - dosen sudah membuka **attendance window**
   - waktu sesuai jadwal kuliah
   - pengguna terdaftar pada kelas (enrollment)
6. Jika valid, aplikasi menyimpan data presensi ke Firestore (termasuk metadata beacon & RSSI).

## Teknologi
- **Mobile:** Flutter, `flutter_reactive_ble`
- **Backend:** Firebase Authentication, Cloud Firestore
- **Beacon:** nRF52840, Arduino IDE, Adafruit/Bluefruit BLE (iBeacon)

## Struktur Data (Firestore)
- `classes` : info kelas/ruang  
- `schedules` : jadwal perkuliahan  
- `enrollments` : relasi mahasiswa–kelas  
- `attendance_windows` : jendela presensi yang dibuka dosen  
- `attendances` : data presensi otomatis  

## Hasil Pengujian (Ringkas)
Pada pengujian di ruangan ±6×6 m, sistem menghasilkan **akurasi ~96,67%** (29 benar dari 30 percobaan), dengan 1 kasus false positive di area dekat pintu.

## Menjalankan Project (Ringkas)
1. Pastikan Flutter sudah terpasang.
2. Buat project Firebase, aktifkan **Authentication** & **Firestore**.
3. Tambahkan file konfigurasi Firebase:
   - Android: `google-services.json`
   - iOS: `GoogleService-Info.plist` (jika digunakan)
4. Sesuaikan parameter:
   - UUID sistem
   - mapping major/minor beacon
   - threshold RSSI (default -80 dBm)
5. Jalankan:
   - `flutter pub get`
   - `flutter run`

## Catatan
Nilai RSSI dan threshold sangat dipengaruhi oleh layout ruangan, posisi beacon, dan tipe smartphone. Disarankan melakukan kalibrasi ulang sebelum penggunaan di banyak kelas/lingkungan berbeda.

