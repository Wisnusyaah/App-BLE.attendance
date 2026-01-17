// lib/teacher_attendance_page.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'attendance_window_service.dart';

/// UUID sistem iBeacon (samakan dengan auto_attendance_page)
const String kSystemUuid = '00112233-4455-6677-8899-aabbccddeeff';

/// Map kelas yg bisa dipilih dosen.
/// id = classId pada Firestore (kelas matkul + slot)
/// name = label tampil di UI
/// major = ruangan (iBeacon major)
class TeacherClassInfo {
  final String id;
  final String name;
  final int major;
  const TeacherClassInfo(this.id, this.name, this.major);
}

class TeacherAttendancePage extends StatefulWidget {
  const TeacherAttendancePage({super.key});

  @override
  State<TeacherAttendancePage> createState() => _TeacherAttendancePageState();
}

class _TeacherAttendancePageState extends State<TeacherAttendancePage> {
  /// ==== SESUAIKAN DAFTAR KELAS DI SINI ====
  /// Biar aman, gue masukin 3 contoh:
  /// - 2 yang sesuai flow baru (kalkulus/algo) -> major 101
  /// - 1 kelas lama ("kelasA") kalau kamu masih pakai itu
  final List<TeacherClassInfo> _classes = const [
    TeacherClassInfo('kalkulus_ku30101', 'Kalkulus · KU3.01.01 (10–12)', 101),
    TeacherClassInfo('algoritma_ku30101', 'Algoritma · KU3.01.01 (14–16)', 101),
    TeacherClassInfo('kelasA', 'Kelas A (Major 101)', 101),
  ];

  TeacherClassInfo? _selectedClass;

  /// Tipe presensi untuk sesi baru.
  /// - one_time
  /// - checkin_checkout
  String _attendanceType = 'one_time';

  AttendanceWindow? _activeWindow;
  bool _loadingWindow = false;
  bool _opening = false;
  bool _closing = false;

  // Auto-close sederhana (opsional)
  int _autoCloseMinutes = 30;
  Timer? _countdown;
  DateTime? _autoCloseAt;
  Duration? _timeLeft;

  @override
  void initState() {
    super.initState();
    _selectedClass = _classes.first;
    _refreshWindow();
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  // --------------------------
  // Helpers
  // --------------------------
  String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  void _startCountdownIfAny() {
    _countdown?.cancel();
    if (_autoCloseAt == null) return;

    void tick() {
      if (!mounted) return;
      final now = DateTime.now();
      final diff = _autoCloseAt!.difference(now);
      if (diff <= Duration.zero) {
        _countdown?.cancel();
        setState(() => _timeLeft = Duration.zero);
        if (_activeWindow != null) _stopSession(auto: true);
      } else {
        setState(() => _timeLeft = diff);
      }
    }

    tick();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _refreshWindow() async {
    final selected = _selectedClass;
    if (selected == null) return;

    setState(() => _loadingWindow = true);
    try {
      final window = await AttendanceWindowService.findOpenWindowForMajor(
        major: selected.major,
      );
      DateTime? autoCloseAt;
      if (window != null) {
        // baca field autoCloseAt (jika ada)
        final snap = await FirebaseFirestore.instance
            .collection('attendance_windows')
            .doc(window.id)
            .get();
        final data = snap.data();
        if (data != null && data['autoCloseAt'] != null) {
          autoCloseAt = (data['autoCloseAt'] as Timestamp).toDate();
        }
      }
      if (!mounted) return;
      setState(() {
        _activeWindow = window;
        _autoCloseAt = autoCloseAt;
      });
      _startCountdownIfAny();
    } catch (e) {
      debugPrint('refreshWindow error: $e');
    } finally {
      if (mounted) setState(() => _loadingWindow = false);
    }
  }

  // --------------------------
  // Start / Stop session
  // --------------------------
  Future<void> _startSession() async {
    final selected = _selectedClass;
    final user = FirebaseAuth.instance.currentUser;
    if (selected == null || user == null) return;

    setState(() => _opening = true);
    try {
      final now = DateTime.now();
      final id = await AttendanceWindowService.openWindow(
        classId: selected.id,
        className: selected.name,
        major: selected.major,
        openedBy: user.uid,
        attendanceType: _attendanceType,
      );

      DateTime? autoAt;
      if (_autoCloseMinutes > 0) {
        autoAt = now.add(Duration(minutes: _autoCloseMinutes));
        await FirebaseFirestore.instance
            .collection('attendance_windows')
            .doc(id)
            .update({
          'autoCloseMinutes': _autoCloseMinutes,
          'autoCloseAt': Timestamp.fromDate(autoAt),
        });
      }

      if (!mounted) return;
      setState(() {
        _activeWindow = AttendanceWindow(
          id: id,
          classId: selected.id,
          className: selected.name,
          major: selected.major,
          openedBy: user.uid,
          openedAt: now,
          isOpen: true,
          attendanceType: _attendanceType,
        );
        _autoCloseAt = autoAt;
      });
      _startCountdownIfAny();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sesi dibuka: ${selected.name} (major ${selected.major})')),
      );
    } catch (e) {
      debugPrint('openWindow error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gagal buka sesi: $e')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _stopSession({bool auto = false}) async {
    final w = _activeWindow;
    if (w == null) return;

    setState(() => _closing = true);
    _countdown?.cancel();

    try {
      await AttendanceWindowService.closeWindow(w.id);
      if (!mounted) return;
      setState(() {
        _activeWindow = null;
        _autoCloseAt = null;
        _timeLeft = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auto ? 'Sesi ditutup otomatis.' : 'Sesi ditutup.')),
      );
    } catch (e) {
      debugPrint('closeWindow error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Gagal tutup sesi: $e')));
      }
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  // --------------------------
  // Manual mark hadir
  // --------------------------
  Future<void> _markManual(String userId) async {
    final w = _activeWindow;
    final selected = _selectedClass;
    final teacher = FirebaseAuth.instance.currentUser;
    if (w == null || selected == null || teacher == null) return;

    final docId = '${w.id}_$userId';
    final ref = FirebaseFirestore.instance.collection('attendances').doc(docId);

    // Cegah dobel (1 user per window)
    final existing = await ref.get();
    if (existing.exists) {
      final data = existing.data() ?? {};
      if (data['checkinAt'] != null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Mahasiswa sudah tercatat hadir di sesi ini.')),
        );
        return;
      }
    }

    // Ambil info user
    final u =
        await FirebaseFirestore.instance.collection('users').doc(userId).get();
    final ud = u.data() ?? {};
    final email = ud['email'] as String? ?? '';

    final payload = <String, dynamic>{
      'windowId': w.id,
      'userId': userId,
      'email': email,
      'classId': selected.id,
      'className': selected.name,
      'uuid': kSystemUuid,
      'major': selected.major,
      'minor': -1,
      'deviceId': 'manual-teacher',
      'timestamp': FieldValue.serverTimestamp(), // kompatibilitas: waktu check-in
      'checkinAt': FieldValue.serverTimestamp(),
      'method': 'manual',
      'markedBy': teacher.uid,
    };

    // Kalau tipe checkin-checkout, manual mark dianggap lengkap (check-in & check-out)
    if (w.attendanceType == 'checkin_checkout') {
      payload['checkoutAt'] = FieldValue.serverTimestamp();
    }

    await ref.set(payload, SetOptions(merge: true));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Berhasil tandai hadir (manual).')),
    );
  }


  // --------------------------
  // UI kecil
  // --------------------------
  Widget _tileStudent({
    required String uid,
    required String status, // 'Hadir' | 'Check-in' | 'Belum hadir'
    bool manual = false,
  }) {
    Color chipColor;
    Color textColor;
    switch (status) {
      case 'Hadir':
        chipColor = Colors.green.shade50;
        textColor = Colors.green;
        break;
      case 'Check-in':
        chipColor = Colors.orange.shade50;
        textColor = Colors.orange;
        break;
      default:
        chipColor = Colors.grey.shade100;
        textColor = Colors.grey.shade700;
    }

    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
      builder: (context, snap) {
        String title = uid;
        String? sub;
        if (snap.hasData && snap.data!.data() != null) {
          final d = snap.data!.data()!;
          final name = d['name'] as String?;
          final email = d['email'] as String?;
          title = name ?? email ?? uid;
          sub = email ?? uid;
        }
        return ListTile(
          dense: true,
          title: Text(title, style: const TextStyle(fontSize: 13)),
          subtitle:
              sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (manual)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text('Manual',
                      style: TextStyle(fontSize: 10, color: Colors.orange)),
                ),
              if (manual) const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  status,
                  style: TextStyle(fontSize: 10, color: textColor),
                ),
              ),
            ],
          ),
          onTap: status == 'Belum hadir' ? () => _markManual(uid) : null,
        );
      },
    );
  }


  Widget _liveAttendance() {
    final w = _activeWindow;
    final selected = _selectedClass;
    if (w == null || selected == null) {
      return const SizedBox.shrink();
    }

    // rentang sesi: openedAt .. (autoCloseAt? now+12h)
    final start = w.openedAt;
    final end = (_autoCloseAt ?? start.add(const Duration(hours: 12)));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Live kehadiran', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('Kelas: ${selected.name} · Major ${selected.major}',
              style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),

          // 1) Ambil daftar enrolled
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('enrollments')
                .where('classId', isEqualTo: selected.id)
                .snapshots(),
            builder: (context, enrollSnap) {
              if (enrollSnap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              if (enrollSnap.hasError) {
                return Text('Gagal memuat enrollments: ${enrollSnap.error}',
                    style: const TextStyle(color: Colors.red, fontSize: 12));
              }

              final enrolled = enrollSnap.data?.docs
                      .map((d) => d.data()['userId'] as String?)
                      .whereType<String>()
                      .toList() ??
                  <String>[];

              if (enrolled.isEmpty) {
                return const Text('Belum ada mahasiswa terdaftar.',
                    style: TextStyle(fontSize: 12));
              }

              // 2) Ambil attendances dalam rentang sesi
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('attendances')
                    .where('windowId', isEqualTo: w.id)
                    .snapshots(),
                builder: (context, attSnap) {
                  if (attSnap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    );
                  }
                  if (attSnap.hasError) {
                    return Text('Gagal memuat hadir: ${attSnap.error}',
                        style: const TextStyle(color: Colors.red, fontSize: 12));
                  }

                  final checkinIds = <String>{};
                  final checkoutIds = <String>{};
                  final manualFlags = <String, bool>{};

                  for (final d in (attSnap.data?.docs ?? [])) {
                    final data = d.data();
                    final uid = data['userId'] as String?;
                    if (uid == null) continue;

                    // kompatibilitas data lama: timestamp dianggap check-in
                    final hasCheckin = data['checkinAt'] != null || data['timestamp'] != null;
                    final hasCheckout = data['checkoutAt'] != null;

                    if (hasCheckin) checkinIds.add(uid);
                    if (hasCheckout) checkoutIds.add(uid);
                    manualFlags[uid] = (data['method'] as String?) == 'manual';
                  }

                  final presentIds = (w.attendanceType == 'checkin_checkout')
                      ? checkinIds.intersection(checkoutIds)
                      : checkinIds;

                  final checkinOnlyIds = checkinIds.difference(presentIds);

                  final total = enrolled.length;
                  final hadir = presentIds.length;
                  final checkinOnly = checkinOnlyIds.length;
                  final absent = enrolled.where((id) => !checkinIds.contains(id)).toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Chip(
                          avatar: const Icon(Icons.check_circle, size: 16),
                          label: Text('Hadir: $hadir / $total'),
                        ),
                        if (w.attendanceType == 'checkin_checkout') ...[
                          const SizedBox(width: 8),
                          Chip(
                            avatar: const Icon(Icons.login, size: 16),
                            label: Text('Check-in saja: $checkinOnly'),
                          ),
                        ],
                        const SizedBox(width: 8),
                        Text('Dibuka: ${_hhmm(w.openedAt)}',
                            style: const TextStyle(fontSize: 10, color: Colors.black54)),
                        if (_timeLeft != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            'Sisa: ${_timeLeft!.inMinutes.toString().padLeft(2, '0')}:${(_timeLeft!.inSeconds % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(fontSize: 10, color: Colors.redAccent),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 8),
                      if (presentIds.isNotEmpty) ...[
                        const Text('Mahasiswa hadir:',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        ListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: presentIds
                              .map((uid) => _tileStudent(
                                    uid: uid,
                                    status: 'Hadir',
                                    manual: manualFlags[uid] ?? false,
                                  ))
                              .toList(),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (w.attendanceType == 'checkin_checkout') ...[
                        const Text('Check-in saja (belum checkout):',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        if (checkinOnlyIds.isEmpty)
                          const Text('Tidak ada.', style: TextStyle(fontSize: 12))
                        else
                          ListView(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: checkinOnlyIds
                                .map((uid) => _tileStudent(
                                      uid: uid,
                                      status: 'Check-in',
                                      manual: manualFlags[uid] ?? false,
                                    ))
                                .toList(),
                          ),
                        const SizedBox(height: 8),
                      ],
                      const Text('Belum hadir:', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      if (absent.isEmpty)
                        const Text('Semua sudah hadir 👏', style: TextStyle(fontSize: 12))
                      else
                        ListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          children: absent
                              .map((uid) =>
                                  _tileStudent(uid: uid, status: 'Belum hadir', manual: false))
                              .toList(),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ]),
      ),
    );
  }

  // --------------------------
  // BUILD
  // --------------------------
  @override
  Widget build(BuildContext context) {
    final hasActive = _activeWindow != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Absen Dosen', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;
              Navigator.of(context).maybePop();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Pilih kelas yang mau dibuka sesi absennya:',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            DropdownButtonFormField<TeacherClassInfo>(
              value: _selectedClass,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              items: _classes
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text('${c.name} · major ${c.major}',
                            overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _selectedClass = v;
                  _activeWindow = null;
                  _autoCloseAt = null;
                  _timeLeft = null;
                });
                _refreshWindow();
              },
            ),
            const SizedBox(height: 16),

            // Status card
            Card(
              color: hasActive ? Colors.green.shade50 : Colors.grey.shade200,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(hasActive ? Icons.check_circle : Icons.info_outline,
                      color: hasActive ? Colors.green : Colors.black54),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        hasActive ? 'Ada sesi absen yang AKTIF.' : 'Belum ada sesi absen yang aktif.',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: hasActive ? Colors.green : Colors.black87),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasActive
                            ? 'Mahasiswa yang dekat beacon akan otomatis diabsen untuk kelas ini.'
                            : 'Tekan "Mulai sesi absen" saat ingin mulai absensi.',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasActive && _activeWindow != null
                            ? 'Dibuka: ${_hhmm(_activeWindow!.openedAt)}'
                            : 'Dibuka: -',
                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                      if (!hasActive) ...[
                        const SizedBox(height: 6),
                        Row(children: [
                          const Text('Durasi sesi (auto tutup): ',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 8),
                          DropdownButton<int>(
                            value: _autoCloseMinutes,
                            items: const [15, 30, 45, 60]
                                .map((m) => DropdownMenuItem(value: m, child: Text('$m menit')))
                                .toList(),
                            onChanged: (v) => setState(() => _autoCloseMinutes = v ?? 30),
                          ),
                        ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          const Text('Tipe presensi: ',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(width: 8),
                          DropdownButton<String>(
                            value: _attendanceType,
                            items: const [
                              DropdownMenuItem(value: 'one_time', child: Text('One-time')),
                              DropdownMenuItem(value: 'checkin_checkout', child: Text('Check-in/Check-out')),
                            ],
                            onChanged: (v) => setState(() => _attendanceType = v ?? 'one_time'),
                          ),
                        ]),
                      ],
                      if (_loadingWindow)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),

            // Tombol
            ElevatedButton.icon(
              onPressed: hasActive || _opening ? null : _startSession,
              icon: _opening
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow),
              label: const Text('Mulai sesi absen'),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: !hasActive || _closing ? null : _stopSession,
              icon: _closing
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.stop),
              label: const Text('Tutup sesi absen'),
            ),

            const SizedBox(height: 16),
            // LIVE
            _liveAttendance(),

            const SizedBox(height: 16),
            const Text(
              'Catatan:\n'
              '• Major = ruangan; classId = kelas matkul (course + slot).\n'
              '• Auto attendance jalan jika: sesi AKTIF, jadwal cocok, dan mahasiswa sudah di-enroll.\n'
              '• Catatan Firestore:\n'
              '  - Query live sekarang pakai windowId (field tunggal), jadi biasanya tidak butuh composite index.\n'
              '  - Untuk riwayat student (kalau ada), bisa tetap pakai timestamp/checkinAt sesuai kebutuhan.',
              style: TextStyle(fontSize: 11),
            ),
          ]),
        ),
      ),
    );
  }
}
