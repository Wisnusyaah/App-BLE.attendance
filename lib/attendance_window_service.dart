// lib/attendance_window_service.dart

import 'package:cloud_firestore/cloud_firestore.dart';

/// Tipe presensi yang didukung pada sesi (attendance window).
/// - one_time          : cukup check-in sekali
/// - checkin_checkout  : wajib check-in dan check-out
class AttendanceWindow {
  final String id;
  final String classId;
  final String className;
  final int major;
  final String openedBy;
  final DateTime openedAt;
  final bool isOpen;

  /// Default: 'one_time'
  final String attendanceType;

  AttendanceWindow({
    required this.id,
    required this.classId,
    required this.className,
    required this.major,
    required this.openedBy,
    required this.openedAt,
    required this.isOpen,
    this.attendanceType = 'one_time',
  });

  factory AttendanceWindow.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return AttendanceWindow(
      id: doc.id,
      classId: data['classId'] as String,
      className: data['className'] as String? ?? 'Kelas',
      major: data['major'] as int,
      openedBy: data['openedBy'] as String? ?? '',
      openedAt: (data['openedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isOpen: data['isOpen'] as bool? ?? false,
      attendanceType: data['attendanceType'] as String? ?? 'one_time',
    );
  }
}

class AttendanceWindowService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Dipakai student & auto flow:
  /// cari 1 sesi absen yang masih open untuk major tertentu.
  static Future<AttendanceWindow?> findOpenWindowForMajor({
    required int major,
  }) async {
    final snap = await _db
        .collection('attendance_windows')
        .where('major', isEqualTo: major)
        .where('isOpen', isEqualTo: true)
        .limit(1)
        .get();

    if (snap.docs.isEmpty) return null;
    return AttendanceWindow.fromDoc(snap.docs.first);
  }

  /// Dipakai dosen: buka sesi baru.
  static Future<String> openWindow({
    required String classId,
    required String className,
    required int major,
    required String openedBy,
    String attendanceType = 'one_time',
  }) async {
    final ref = await _db.collection('attendance_windows').add({
      'classId': classId,
      'className': className,
      'major': major,
      'openedBy': openedBy,
      'attendanceType': attendanceType, // one_time | checkin_checkout
      'openedAt': FieldValue.serverTimestamp(),
      'closedAt': null,
      'isOpen': true,
    });
    return ref.id;
  }

  /// Dipakai dosen: tutup sesi.
  static Future<void> closeWindow(String windowId) async {
    await _db.collection('attendance_windows').doc(windowId).update({
      'isOpen': false,
      'closedAt': FieldValue.serverTimestamp(),
    });
  }
}
